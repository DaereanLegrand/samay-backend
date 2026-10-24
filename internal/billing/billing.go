// Package billing implements the `samay-billing-worker`: it retries the
// RevenueCat webhook failures queued by the Edge Function (E2/Q28).
//
// Retry schedule (decision 14-wave2-decisions §5): 5 attempts with
// 1m / 5m / 30m / 2h / 12h backoff. A row that reaches 5 attempts is left
// unresolved (next_attempt_at NULL) for alerting; it is never silently dropped.
package billing

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/samay-app/samay/internal/db"
)

// Tier is the subscription tier granted by an entitlement.
type Tier string

const (
	Free Tier = "free"
	Pro  Tier = "pro"
	VIP  Tier = "vip"
)

// Backoff is the fixed retry schedule (1m/5m/30m/2h/12h).
var Backoff = []time.Duration{
	time.Minute,
	5 * time.Minute,
	30 * time.Minute,
	2 * time.Hour,
	12 * time.Hour,
}

// NextAttempt returns the delay after the given attempt number (1-based).
func NextAttempt(attempts int) (time.Duration, bool) {
	if attempts < 1 || attempts > len(Backoff) {
		return 0, false
	}
	return Backoff[attempts-1], true
}

// EntitlementMap is the explicit entitlement-id -> tier map. Exact match only;
// an unmapped active entitlement is an error (fail closed).
type EntitlementMap map[string]Tier

// ParseEntitlementMap parses `REVENUECAT_ENTITLEMENT_MAP` JSON.
func ParseEntitlementMap(raw string) (EntitlementMap, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, errors.New("REVENUECAT_ENTITLEMENT_MAP is not configured")
	}
	var parsed map[string]string
	if err := json.Unmarshal([]byte(raw), &parsed); err != nil {
		return nil, fmt.Errorf("REVENUECAT_ENTITLEMENT_MAP: %w", err)
	}
	out := make(EntitlementMap, len(parsed))
	for id, tier := range parsed {
		switch Tier(tier) {
		case Pro, VIP:
			out[id] = Tier(tier)
		default:
			return nil, fmt.Errorf("REVENUECAT_ENTITLEMENT_MAP: %q has invalid tier %q", id, tier)
		}
	}
	if len(out) == 0 {
		return nil, errors.New("REVENUECAT_ENTITLEMENT_MAP is empty")
	}
	return out, nil
}

// Entitlement is one RevenueCat active entitlement.
type Entitlement struct {
	ID        string `json:"entitlement_id"`
	ExpiresAt int64  `json:"expires_at"` // ms epoch
}

// ResolveTier maps the active entitlements to the highest paid tier. Any
// unmapped entitlement is an error (no substring matching, no guessing).
func (m EntitlementMap) ResolveTier(items []Entitlement) (Tier, *time.Time, error) {
	tier := Free
	var expires time.Time
	for _, it := range items {
		mapped, ok := m[it.ID]
		if !ok {
			return Free, nil, fmt.Errorf("unknown_entitlement:%s", it.ID)
		}
		if mapped == VIP || (mapped == Pro && tier != VIP) {
			tier = mapped
		}
		if it.ExpiresAt > 0 {
			t := time.UnixMilli(it.ExpiresAt).UTC()
			if t.After(expires) {
				expires = t
			}
		}
	}
	if tier == Free || expires.IsZero() {
		return tier, nil, nil
	}
	return tier, &expires, nil
}

// RCClient reads the customer's active entitlements from RevenueCat v2.
type RCClient struct {
	APIKey    string
	ProjectID string
	BaseURL   string
	HTTP      *http.Client
}

// entitlements fetches the customer's active entitlements. Strict on failure.
func (c *RCClient) entitlements(ctx context.Context, userID string) ([]Entitlement, error) {
	if c.APIKey == "" || c.ProjectID == "" {
		return nil, errors.New("RevenueCat v2 not configured")
	}
	base := c.BaseURL
	if base == "" {
		base = "https://api.revenuecat.com/v2"
	}
	httpc := c.HTTP
	if httpc == nil {
		httpc = &http.Client{Timeout: 15 * time.Second}
	}
	u := fmt.Sprintf("%s/projects/%s/customers/%s",
		strings.TrimRight(base, "/"),
		url.PathEscape(c.ProjectID),
		url.PathEscape(userID))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.APIKey)
	res, err := httpc.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("rc v2 customer %d", res.StatusCode)
	}
	var body struct {
		ActiveEntitlements struct {
			Items []Entitlement `json:"items"`
		} `json:"active_entitlements"`
	}
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		return nil, fmt.Errorf("decode rc customer: %w", err)
	}
	return body.ActiveEntitlements.Items, nil
}

// failureRow mirrors public.webhook_failures.
type failureRow struct {
	ID            string          `json:"id"`
	EventID       string          `json:"event_id"`
	EventType     string          `json:"event_type"`
	Payload       json.RawMessage `json:"payload"`
	Attempts      int             `json:"attempts"`
	NextAttemptAt *time.Time      `json:"next_attempt_at"`
}

type webhookEvent struct {
	ID               string   `json:"id"`
	Type             string   `json:"type"`
	AppUserID        string   `json:"app_user_id"`
	EventTimestampMs int64    `json:"event_timestamp_ms"`
	TransferredFrom  []string `json:"transferred_from"`
	TransferredTo    []string `json:"transferred_to"`
}

// Worker drains the retry queue.
type Worker struct {
	DB    *db.DBClient
	RC    *RCClient
	Map   EntitlementMap
	Logf  func(format string, args ...any)
	Now   func() time.Time
	Every time.Duration
	Batch int
}

// DrainOnce processes due failures and returns how many were resolved.
func (w *Worker) DrainOnce(ctx context.Context) (int, error) {
	now := w.now()
	filter := "id,event_id,event_type,payload,attempts,next_attempt_at" +
		"&resolved=eq.false&attempts=lt.6&next_attempt_at=not.is.null" +
		"&next_attempt_at=lte." + url.QueryEscape(now.UTC().Format(time.RFC3339)) +
		"&order=next_attempt_at.asc"
	raw, err := w.DB.Select(ctx, "webhook_failures", filter, w.batch(), 0)
	if err != nil {
		return 0, fmt.Errorf("select webhook_failures: %w", err)
	}
	var rows []failureRow
	if err := json.Unmarshal(raw, &rows); err != nil {
		return 0, fmt.Errorf("decode webhook_failures: %w", err)
	}
	resolved := 0
	for _, row := range rows {
		if err := w.process(ctx, row); err != nil {
			w.markFailed(ctx, row, err)
			continue
		}
		if err := w.markResolved(ctx, row.ID); err != nil {
			w.logf("billing: mark resolved %s failed: %v", row.ID, err)
			continue
		}
		resolved++
	}
	return resolved, nil
}

func (w *Worker) process(ctx context.Context, row failureRow) error {
	var payload struct {
		Event webhookEvent `json:"event"`
	}
	if err := json.Unmarshal(row.Payload, &payload); err != nil {
		return fmt.Errorf("decode payload: %w", err)
	}
	evt := payload.Event
	if evt.ID == "" {
		evt.ID = row.EventID
	}
	if evt.Type == "" {
		evt.Type = row.EventType
	}
	typ := strings.ToUpper(evt.Type)

	if typ == "TRANSFER" {
		ids := transferIDs(evt)
		if len(ids) == 0 {
			return nil // nothing to sync; resolve
		}
		for _, id := range ids {
			if err := w.resync(ctx, id, typ); err != nil {
				return err
			}
		}
		return nil
	}

	if !isUUID(evt.AppUserID) {
		return nil // non-user alias: nothing to sync
	}

	switch {
	case typ == "REFUND" || typ == "CHARGEBACK":
		return w.apply(ctx, evt.AppUserID, Free, nil, typ, eventAt(evt, w.now()))
	case typ == "BILLING_ISSUE" || typ == "SUBSCRIPTION_PAUSED":
		return w.grace(ctx, evt.AppUserID, typ, eventAt(evt, w.now()))
	case isTierEvent(typ):
		return w.resync(ctx, evt.AppUserID, typ)
	default:
		return nil // ignored event: resolve
	}
}

func (w *Worker) resync(ctx context.Context, userID, eventType string) error {
	items, err := w.customerEntitlements(ctx, userID)
	if err != nil {
		return err
	}
	tier, expires, err := w.Map.ResolveTier(items)
	if err != nil {
		return err
	}
	return w.apply(ctx, userID, tier, expires, eventType, w.now())
}

func (w *Worker) customerEntitlements(ctx context.Context, userID string) ([]Entitlement, error) {
	// RCClient.CustomerTier delegates decoding; keep one HTTP path.
	return w.RC.entitlements(ctx, userID)
}

func (w *Worker) apply(ctx context.Context, userID string, tier Tier, expires *time.Time, eventType string, at time.Time) error {
	params := map[string]any{
		"p_user":       userID,
		"p_tier":       string(tier),
		"p_expires":    nil,
		"p_event_type": eventType,
		"p_event_at":   at.UTC().Format(time.RFC3339),
		"p_source":     "revenuecat",
	}
	if expires != nil {
		params["p_expires"] = expires.UTC().Format(time.RFC3339)
	}
	if _, err := w.DB.RPC(ctx, "apply_subscription_state", params); err != nil {
		return fmt.Errorf("apply_subscription_state: %w", err)
	}
	return nil
}

func (w *Worker) grace(ctx context.Context, userID, eventType string, at time.Time) error {
	_, err := w.DB.RPC(ctx, "apply_subscription_grace", map[string]any{
		"p_user":       userID,
		"p_event_type": eventType,
		"p_event_at":   at.UTC().Format(time.RFC3339),
	})
	if err != nil {
		return fmt.Errorf("apply_subscription_grace: %w", err)
	}
	return nil
}

func (w *Worker) markResolved(ctx context.Context, id string) error {
	_, err := w.DB.Update(ctx, "webhook_failures", "id=eq."+url.QueryEscape(id), map[string]any{
		"resolved":        true,
		"resolved_at":     w.now().UTC().Format(time.RFC3339),
		"next_attempt_at": nil,
		"last_error":      nil,
	})
	return err
}

func (w *Worker) markFailed(ctx context.Context, row failureRow, cause error) {
	attempts := row.Attempts + 1
	patch := map[string]any{
		"attempts":   attempts,
		"last_error": truncate(cause.Error(), 2000),
	}
	if d, ok := NextAttempt(attempts); ok {
		patch["next_attempt_at"] = w.now().Add(d).UTC().Format(time.RFC3339)
	} else {
		patch["next_attempt_at"] = nil
	}
	if _, err := w.DB.Update(ctx, "webhook_failures", "id=eq."+url.QueryEscape(row.ID), patch); err != nil {
		w.logf("billing: mark failed %s: %v", row.ID, err)
	}
}

func (w *Worker) Run(ctx context.Context) error {
	every := w.Every
	if every <= 0 {
		every = time.Minute
	}
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		if _, err := w.DrainOnce(ctx); err != nil {
			w.logf("billing drain error: %v", err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func (w *Worker) now() time.Time {
	if w.Now != nil {
		return w.Now()
	}
	return time.Now()
}

func (w *Worker) batch() int {
	if w.Batch > 0 {
		return w.Batch
	}
	return 20
}

func (w *Worker) logf(format string, args ...any) {
	if w.Logf != nil {
		w.Logf(format, args...)
	}
}

func isTierEvent(typ string) bool {
	switch typ {
	case "INITIAL_PURCHASE", "RENEWAL", "PRODUCT_CHANGE", "UNCANCELLATION",
		"SUBSCRIPTION_EXTENDED", "NON_RENEWING_PURCHASE", "EXPIRATION":
		return true
	}
	return false
}

func transferIDs(evt webhookEvent) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, id := range append(append([]string{}, evt.TransferredFrom...), evt.TransferredTo...) {
		if isUUID(id) && !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}

func eventAt(evt webhookEvent, fallback time.Time) time.Time {
	if evt.EventTimestampMs > 0 {
		return time.UnixMilli(evt.EventTimestampMs).UTC()
	}
	return fallback
}

func isUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, r := range s {
		switch i {
		case 8, 13, 18, 23:
			if r != '-' {
				return false
			}
		default:
			if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')) {
				return false
			}
		}
	}
	return true
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
