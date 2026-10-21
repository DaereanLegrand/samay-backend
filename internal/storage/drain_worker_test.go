package storage

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

type updateCall struct {
	table  string
	filter string
	patch  any
}

type fakeStore struct {
	rows      []OutboxRow
	selectErr error
	updateErr error
	selects   int
	updates   []updateCall
}

func (f *fakeStore) Select(ctx context.Context, table, filter string, limit, offset int) ([]byte, error) {
	f.selects++
	if f.selectErr != nil {
		return nil, f.selectErr
	}
	if table != outboxTable {
		return nil, errors.New("unexpected table " + table)
	}
	if !strings.Contains(filter, "processed_at=is.null") || !strings.Contains(filter, "order=id.asc") {
		return nil, errors.New("unexpected filter " + filter)
	}
	return json.Marshal(f.rows)
}

func (f *fakeStore) Update(ctx context.Context, table, filter string, patch any) ([]byte, error) {
	f.updates = append(f.updates, updateCall{table: table, filter: filter, patch: patch})
	if f.updateErr != nil {
		return nil, f.updateErr
	}
	return []byte(`[]`), nil
}

type fakeObjects struct {
	errs  map[string]error
	calls []string
}

func (f *fakeObjects) DeleteObject(ctx context.Context, bucket, object string) error {
	key := bucket + "/" + object
	f.calls = append(f.calls, key)
	return f.errs[key]
}

func TestDrainOnceMarksRowsConditionally(t *testing.T) {
	store := &fakeStore{rows: []OutboxRow{
		{ID: 1, Bucket: "events", ObjectName: "e1/a.jpg"},
		{ID: 2, Bucket: "events", ObjectName: "e1/b.jpg"},
	}}
	objects := &fakeObjects{}
	w := NewWorker(store, objects, nil)

	clock := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	w.now = func() time.Time { return clock }

	deleted, failed, err := w.DrainOnce(context.Background())
	if err != nil {
		t.Fatalf("DrainOnce: %v", err)
	}
	if deleted != 2 || failed != 0 {
		t.Fatalf("deleted=%d failed=%d", deleted, failed)
	}
	if len(objects.calls) != 2 || objects.calls[0] != "events/e1/a.jpg" {
		t.Fatalf("delete calls = %v", objects.calls)
	}
	if len(store.updates) != 2 {
		t.Fatalf("updates = %d", len(store.updates))
	}
	if store.updates[0].filter != "id=eq.1&processed_at=is.null" {
		t.Fatalf("filter = %q", store.updates[0].filter)
	}
	patch := store.updates[0].patch.(map[string]any)
	if patch["processed_at"] != clock.Format(time.RFC3339Nano) {
		t.Fatalf("patch = %v", patch)
	}
}

func TestDrainOnceRetriesWithBackoff(t *testing.T) {
	store := &fakeStore{rows: []OutboxRow{{ID: 7, Bucket: "events", ObjectName: "e1/a.jpg"}}}
	objects := &fakeObjects{errs: map[string]error{"events/e1/a.jpg": errors.New("boom")}}
	w := NewWorker(store, objects, nil)
	w.MaxAttempts = 5
	w.BaseBackoff = time.Second

	clock := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	w.now = func() time.Time { return clock }

	if deleted, failed, err := w.DrainOnce(context.Background()); err != nil || deleted != 0 || failed != 1 {
		t.Fatalf("first drain: deleted=%d failed=%d err=%v", deleted, failed, err)
	}
	if len(store.updates) != 0 {
		t.Fatalf("failed row was marked")
	}

	if _, _, err := w.DrainOnce(context.Background()); err != nil {
		t.Fatalf("second drain: %v", err)
	}
	if len(objects.calls) != 1 {
		t.Fatalf("row retried during backoff: calls=%d", len(objects.calls))
	}

	clock = clock.Add(time.Second)
	objects.errs = nil
	if deleted, failed, err := w.DrainOnce(context.Background()); err != nil || deleted != 1 || failed != 0 {
		t.Fatalf("retry drain: deleted=%d failed=%d err=%v", deleted, failed, err)
	}
	if len(store.updates) != 1 {
		t.Fatalf("updates = %d", len(store.updates))
	}
}

func TestDrainOnceParksPoisonRowAfterMaxAttempts(t *testing.T) {
	store := &fakeStore{rows: []OutboxRow{{ID: 9, Bucket: "events", ObjectName: "e1/a.jpg"}}}
	objects := &fakeObjects{errs: map[string]error{"events/e1/a.jpg": errors.New("NoSuchBucket")}}
	w := NewWorker(store, objects, nil)
	w.MaxAttempts = 2
	w.BaseBackoff = time.Second

	clock := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	w.now = func() time.Time { return clock }

	if _, failed, _ := w.DrainOnce(context.Background()); failed != 1 {
		t.Fatalf("first attempt failed=%d", failed)
	}
	clock = clock.Add(time.Second)
	if _, failed, _ := w.DrainOnce(context.Background()); failed != 1 {
		t.Fatalf("second attempt failed=%d", failed)
	}
	clock = clock.Add(24 * time.Hour)
	if _, failed, _ := w.DrainOnce(context.Background()); failed != 0 {
		t.Fatalf("parked row retried, failed=%d", failed)
	}
	if len(objects.calls) != 2 {
		t.Fatalf("delete calls = %d, want 2", len(objects.calls))
	}
	if len(store.updates) != 0 {
		t.Fatalf("poison row was marked processed")
	}
}

func TestDrainOnceKeepsRowWhenMarkFails(t *testing.T) {
	store := &fakeStore{
		rows:      []OutboxRow{{ID: 3, Bucket: "events", ObjectName: "e1/a.jpg"}},
		updateErr: errors.New("db down"),
	}
	objects := &fakeObjects{}
	w := NewWorker(store, objects, nil)
	w.BaseBackoff = time.Second
	clock := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	w.now = func() time.Time { return clock }

	deleted, failed, err := w.DrainOnce(context.Background())
	if err != nil {
		t.Fatalf("DrainOnce: %v", err)
	}
	if deleted != 0 || failed != 1 {
		t.Fatalf("deleted=%d failed=%d", deleted, failed)
	}

	clock = clock.Add(time.Second)
	store.updateErr = nil
	deleted, failed, err = w.DrainOnce(context.Background())
	if err != nil || deleted != 1 || failed != 0 {
		t.Fatalf("retry: deleted=%d failed=%d err=%v", deleted, failed, err)
	}
}

func TestDrainOnceSelectError(t *testing.T) {
	store := &fakeStore{selectErr: errors.New("unreachable")}
	w := NewWorker(store, &fakeObjects{}, nil)
	if _, _, err := w.DrainOnce(context.Background()); err == nil {
		t.Fatal("expected select error")
	}
}

func TestDrainOnceContinuesPastFailedRow(t *testing.T) {
	store := &fakeStore{rows: []OutboxRow{
		{ID: 1, Bucket: "events", ObjectName: "e1/a.jpg"},
		{ID: 2, Bucket: "events", ObjectName: "e1/b.jpg"},
	}}
	objects := &fakeObjects{errs: map[string]error{"events/e1/a.jpg": errors.New("boom")}}
	w := NewWorker(store, objects, nil)

	deleted, failed, err := w.DrainOnce(context.Background())
	if err != nil || deleted != 1 || failed != 1 {
		t.Fatalf("deleted=%d failed=%d err=%v", deleted, failed, err)
	}
	if len(store.updates) != 1 || store.updates[0].filter != "id=eq.2&processed_at=is.null" {
		t.Fatalf("updates = %+v", store.updates)
	}
}
