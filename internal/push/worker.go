package push

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/samay-app/samay/internal/db"
)

// PushTypes is the allow-list of notification types the worker dispatches.
//
// The in-app center carries every type; only these are worth a device push.
// Start minimal (Track-2 PUSH): an invite and the generic "it's your turn"
// that abstracts truth-or-dare / bottle / two-lies / charades.
var PushTypes = []string{"minigame_invite", "minigame_turn"}

// Logf matches log.Printf-style logging.
type Logf func(format string, args ...any)

type notificationRow struct {
	ID     string          `json:"id"`
	UserID string          `json:"user_id"`
	Type   string          `json:"type"`
	Title  string          `json:"title"`
	Body   string          `json:"body"`
	Data   json.RawMessage `json:"data"`
}

type deviceTokenRow struct {
	Token string `json:"token"`
}

// Worker polls the notifications table for unsent push-eligible rows, resolves
// each recipient's device tokens and dispatches via FCM, then marks the row
// sent. Runs single-instance (the testing VM); duplicate delivery on restart is
// possible but bounded.
type Worker struct {
	DB    *db.DBClient
	FCM   *FCMClient
	Logf  Logf
	Batch int
	Every time.Duration
}

// NewWorker wires a worker with the testing defaults.
func NewWorker(database *db.DBClient, fcm *FCMClient, logf Logf) *Worker {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	return &Worker{DB: database, FCM: fcm, Logf: logf, Batch: 100, Every: 15 * time.Second}
}

// Run drains immediately, then on a ticker until the context is cancelled.
func (w *Worker) Run(ctx context.Context) error {
	if w.Batch <= 0 {
		w.Batch = 100
	}
	if w.Every <= 0 {
		w.Every = 15 * time.Second
	}
	ticker := time.NewTicker(w.Every)
	defer ticker.Stop()

	for {
		if _, err := w.DrainOnce(ctx); err != nil {
			w.Logf("push drain error: %v", err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

// DrainOnce processes one batch and returns the number of notifications marked
// sent.
func (w *Worker) DrainOnce(ctx context.Context) (int, error) {
	rows, err := w.unsent(ctx)
	if err != nil {
		return 0, err
	}
	sent := 0
	for _, n := range rows {
		if err := w.dispatch(ctx, n); err != nil {
			// One bad recipient must not abort the batch.
			w.Logf("push dispatch failed for %s: %v", n.ID, err)
			continue
		}
		if err := w.markSent(ctx, n.ID); err != nil {
			w.Logf("push mark-sent failed for %s: %v", n.ID, err)
			continue
		}
		sent++
	}
	if sent > 0 {
		w.Logf("push worker dispatched %d notification(s)", sent)
	}
	return sent, nil
}

func (w *Worker) unsent(ctx context.Context) ([]notificationRow, error) {
	filter := "id,user_id,type,title,body,data" +
		"&push_sent_at=is.null" +
		"&type=in.(" + strings.Join(PushTypes, ",") + ")" +
		"&order=created_at.asc"
	raw, err := w.DB.Select(ctx, "notifications", filter, w.Batch, 0)
	if err != nil {
		return nil, fmt.Errorf("select unsent notifications: %w", err)
	}
	var rows []notificationRow
	if err := json.Unmarshal(raw, &rows); err != nil {
		return nil, fmt.Errorf("decode notifications: %w", err)
	}
	return rows, nil
}

func (w *Worker) dispatch(ctx context.Context, n notificationRow) error {
	tokens, err := w.tokensForUser(ctx, n.UserID)
	if err != nil {
		return err
	}
	if len(tokens) == 0 {
		return nil
	}

	msg := Message{Title: n.Title, Body: n.Body, Data: dataWithType(n)}
	for _, token := range tokens {
		err := w.FCM.Send(ctx, token, msg)
		switch {
		case err == nil:
		case errors.Is(err, ErrUnregistered):
			w.Logf("pruning unregistered device token for user %s", n.UserID)
			if delErr := w.deleteToken(ctx, token); delErr != nil {
				w.Logf("prune token failed: %v", delErr)
			}
		default:
			w.Logf("fcm send to user %s failed: %v", n.UserID, err)
		}
	}
	return nil
}

func (w *Worker) tokensForUser(ctx context.Context, userID string) ([]string, error) {
	raw, err := w.DB.Select(ctx, "device_tokens",
		"token&user_id=eq."+url.QueryEscape(userID), 0, 0)
	if err != nil {
		return nil, fmt.Errorf("select device tokens: %w", err)
	}
	var rows []deviceTokenRow
	if err := json.Unmarshal(raw, &rows); err != nil {
		return nil, fmt.Errorf("decode device tokens: %w", err)
	}
	tokens := make([]string, 0, len(rows))
	for _, r := range rows {
		if r.Token != "" {
			tokens = append(tokens, r.Token)
		}
	}
	return tokens, nil
}

func (w *Worker) markSent(ctx context.Context, id string) error {
	patch := map[string]any{"push_sent_at": time.Now().UTC().Format(time.RFC3339Nano)}
	_, err := w.DB.Update(ctx, "notifications", "id=eq."+url.QueryEscape(id), patch)
	return err
}

func (w *Worker) deleteToken(ctx context.Context, token string) error {
	_, err := w.DB.Delete(ctx, "device_tokens", "token=eq."+url.QueryEscape(token))
	return err
}

// dataWithType flattens the notification's JSON data into the string map FCM
// requires, and injects `type` so the client tap handler can route.
func dataWithType(n notificationRow) map[string]string {
	out := map[string]string{"type": n.Type}
	if len(n.Data) == 0 {
		return out
	}
	var m map[string]any
	if err := json.Unmarshal(n.Data, &m); err != nil {
		return out
	}
	for k, v := range m {
		switch val := v.(type) {
		case string:
			out[k] = val
		case nil:
			// skip
		default:
			b, err := json.Marshal(val)
			if err == nil {
				out[k] = string(b)
			}
		}
	}
	return out
}
