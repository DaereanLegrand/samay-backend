package storage

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"sync"
	"time"
)

const outboxTable = "pending_object_deletions"

type RowStore interface {
	Select(ctx context.Context, table, filter string, limit, offset int) ([]byte, error)
	Update(ctx context.Context, table, filter string, patch any) ([]byte, error)
}

type ObjectDeleter interface {
	DeleteObject(ctx context.Context, bucket, object string) error
}

type Logf func(format string, args ...any)

type OutboxRow struct {
	ID         int64  `json:"id"`
	Bucket     string `json:"bucket"`
	ObjectName string `json:"object_name"`
}

type failureState struct {
	attempts int
	nextAt   time.Time
	parked   bool
}

type Worker struct {
	DB          RowStore
	Storage     ObjectDeleter
	Logf        Logf
	Batch       int
	MaxAttempts int
	BaseBackoff time.Duration

	now      func() time.Time
	mu       sync.Mutex
	failures map[int64]*failureState
}

func NewWorker(database RowStore, objects ObjectDeleter, logf Logf) *Worker {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	return &Worker{
		DB:          database,
		Storage:     objects,
		Logf:        logf,
		Batch:       50,
		MaxAttempts: 5,
		BaseBackoff: 2 * time.Second,
		now:         time.Now,
		failures:    make(map[int64]*failureState),
	}
}

func (w *Worker) DrainOnce(ctx context.Context) (deleted, failed int, err error) {
	batch := w.Batch
	if batch <= 0 {
		batch = 50
	}
	raw, err := w.DB.Select(ctx, outboxTable,
		"id,bucket,object_name&processed_at=is.null&order=id.asc", batch, 0)
	if err != nil {
		return 0, 0, fmt.Errorf("select pending object deletions: %w", err)
	}
	var rows []OutboxRow
	if err := json.Unmarshal(raw, &rows); err != nil {
		return 0, 0, fmt.Errorf("decode pending object deletions: %w", err)
	}

	now := w.now()
	for _, row := range rows {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return deleted, failed, ctxErr
		}
		if w.skip(row.ID, now) {
			continue
		}
		if err := w.Storage.DeleteObject(ctx, row.Bucket, row.ObjectName); err != nil {
			w.recordFailure(row.ID, now)
			w.Logf("object drain failed for %d (%s/%s): %v", row.ID, row.Bucket, row.ObjectName, err)
			failed++
			continue
		}
		if err := w.markProcessed(ctx, row.ID, now); err != nil {
			w.recordFailure(row.ID, now)
			w.Logf("object drain mark-processed failed for %d: %v", row.ID, err)
			failed++
			continue
		}
		w.clearFailure(row.ID)
		deleted++
	}
	if deleted > 0 || failed > 0 {
		w.Logf("object drain: %d deleted, %d failed", deleted, failed)
	}
	return deleted, failed, nil
}

func (w *Worker) markProcessed(ctx context.Context, id int64, now time.Time) error {
	filter := "id=eq." + strconv.FormatInt(id, 10) + "&processed_at=is.null"
	patch := map[string]any{"processed_at": now.UTC().Format(time.RFC3339Nano)}
	_, err := w.DB.Update(ctx, outboxTable, filter, patch)
	return err
}

func (w *Worker) skip(id int64, now time.Time) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	st := w.failures[id]
	if st == nil {
		return false
	}
	if st.parked {
		return true
	}
	return now.Before(st.nextAt)
}

func (w *Worker) recordFailure(id int64, now time.Time) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.failures == nil {
		w.failures = make(map[int64]*failureState)
	}
	st := w.failures[id]
	if st == nil {
		st = &failureState{}
		w.failures[id] = st
	}
	st.attempts++
	if w.MaxAttempts > 0 && st.attempts >= w.MaxAttempts {
		st.parked = true
		w.Logf("object drain parked row %d after %d attempt(s)", id, st.attempts)
		return
	}
	st.nextAt = now.Add(w.backoff(st.attempts))
}

func (w *Worker) clearFailure(id int64) {
	w.mu.Lock()
	defer w.mu.Unlock()
	delete(w.failures, id)
}

func (w *Worker) backoff(attempts int) time.Duration {
	base := w.BaseBackoff
	if base <= 0 {
		base = time.Second
	}
	if attempts < 1 {
		attempts = 1
	}
	if attempts > 20 {
		attempts = 20
	}
	d := base * time.Duration(1<<(attempts-1))
	if d > time.Hour {
		d = time.Hour
	}
	return d
}
