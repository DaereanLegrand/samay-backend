package ops

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/samay-app/samay/internal/db"
)

type ListEventsParams struct {
	Status   string
	Type     string
	Promotor string
}

type EventDetail struct {
	Event              db.Event           `json:"event"`
	Promotores         []db.EventPromotor `json:"promotores"`
	ConfirmedAttendees int                `json:"confirmed_attendees"`
	PreshardPoolStatus string             `json:"preshard_pool_status"`
}

func ListEvents(ctx context.Context, client *db.DBClient, params ListEventsParams) ([]db.Event, error) {
	qb := db.NewQueryBuilder().
		Select("id", "name", "type", "status", "starts_at", "ends_at", "created_by_user_id", "preshards_pool", "featured").
		Limit(100)
	if params.Status != "" {
		qb.Eq("status", params.Status)
	}
	if params.Type != "" {
		qb.Eq("type", params.Type)
	}
	if params.Promotor != "" {
		qb.Eq("created_by_user_id", params.Promotor)
	}
	return db.List[db.Event](ctx, client, "events", qb)
}

// GetEvent returns the event plus its promotores enrichment. The promotores
// query is best-effort: on failure the detail is returned with a joined
// error (errors.Join) so the caller can render the primary result while the
// failure stays explicit.
func GetEvent(ctx context.Context, client *db.DBClient, eventID string) (*EventDetail, error) {
	body, err := client.Select(ctx, "events", "*,event_promotores(*),event_attendances(id)&id=eq."+eventID, 1, 0)
	if err != nil {
		return nil, fmt.Errorf("get event: %w", err)
	}
	var events []db.Event
	if err := json.Unmarshal(body, &events); err != nil {
		return nil, fmt.Errorf("unmarshal event: %w", err)
	}
	if len(events) == 0 {
		return nil, fmt.Errorf("event not found: %s: %w", eventID, ErrNotFound)
	}

	var promotores []db.EventPromotor
	var detailErrs []error

	promoBody, err := client.Select(ctx, "event_promotores", "id,event_id,user_id,role,preshards_contributed,added_at&event_id=eq."+eventID, 50, 0)
	if err != nil {
		detailErrs = append(detailErrs, fmt.Errorf("get event: fetch promotores: %w", err))
	} else if err := json.Unmarshal(promoBody, &promotores); err != nil {
		detailErrs = append(detailErrs, fmt.Errorf("get event: unmarshal promotores: %w", err))
	}

	return &EventDetail{
		Event:      events[0],
		Promotores: promotores,
	}, errors.Join(detailErrs...)
}

func FeatureEvent(ctx context.Context, client *db.DBClient, eventID string, expiresAt time.Time, adminUserID string) error {
	_, err := client.Update(ctx, "events", "id=eq."+eventID, map[string]any{
		"featured":       true,
		"featured_until": expiresAt.Format(time.RFC3339),
	})
	if err != nil {
		return fmt.Errorf("feature event: %w", err)
	}
	if _, err := client.Update(ctx, "feature_requests", "event_id=eq."+eventID+"&status=eq.pending", map[string]any{
		"status":         "approved",
		"featured_until": expiresAt.Format(time.RFC3339),
	}); err != nil {
		return fmt.Errorf("feature event: approve request: %w", err)
	}
	details, err := json.Marshal(map[string]string{"expires_at": expiresAt.Format(time.RFC3339)})
	if err != nil {
		return fmt.Errorf("feature event: marshal audit details: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "feature_event",
		TargetType:  "event",
		TargetID:    eventID,
		Details:     details,
	})
}

func UnfeatureEvent(ctx context.Context, client *db.DBClient, eventID, adminUserID string) error {
	_, err := client.Update(ctx, "events", "id=eq."+eventID, map[string]any{
		"featured":       false,
		"featured_until": nil,
	})
	if err != nil {
		return fmt.Errorf("unfeature event: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "unfeature_event",
		TargetType:  "event",
		TargetID:    eventID,
	})
}

func RejectFeatureEvent(ctx context.Context, client *db.DBClient, eventID, adminUserID string) error {
	_, err := client.Update(ctx, "feature_requests", "event_id=eq."+eventID+"&status=eq.pending", map[string]any{
		"status": "rejected",
	})
	if err != nil {
		return fmt.Errorf("reject feature request: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "reject_feature",
		TargetType:  "event",
		TargetID:    eventID,
	})
}

func CancelEvent(ctx context.Context, client *db.DBClient, eventID, reason, adminUserID string) error {
	eventBody, err := client.Select(ctx, "events",
		"id,status,preshards_pool&id=eq."+eventID, 1, 0)
	if err != nil {
		return fmt.Errorf("cancel event: get event: %w", err)
	}
	var events []db.Event
	if err := json.Unmarshal(eventBody, &events); err != nil {
		return fmt.Errorf("cancel event: unmarshal: %w", err)
	}
	if len(events) == 0 {
		return fmt.Errorf("cancel event: not found: %s: %w", eventID, ErrNotFound)
	}

	if events[0].Status == "cancelled" {
		return nil
	}

	// The promotores pool decides who gets refunded — a failed read means we
	// cannot know the refunds, so this is a hard error, not best-effort.
	pool, err := client.Select(ctx, "event_promotores",
		"id,user_id,preshards_contributed&event_id=eq."+eventID, 100, 0)
	if err != nil {
		return fmt.Errorf("cancel event: fetch promotores: %w", err)
	}
	var promotores []db.EventPromotor
	if err := json.Unmarshal(pool, &promotores); err != nil {
		return fmt.Errorf("cancel event: unmarshal promotores: %w", err)
	}

	// Every promotore still gets its refund attempt; failed inserts are
	// joined and surfaced so the operator sees exactly who was not refunded.
	var refundErr error
	for _, p := range promotores {
		if p.PreshardsContributed <= 0 {
			continue
		}
		if _, err := client.Insert(ctx, "preshard_ledger", map[string]any{
			"user_id":      p.UserID,
			"delta":        p.PreshardsContributed,
			"reason":       "event_pool_returned",
			"reference_id": eventID,
		}); err != nil {
			refundErr = errors.Join(refundErr, fmt.Errorf("cancel event: refund user %s (%d preshards): %w", p.UserID, p.PreshardsContributed, err))
		}
	}

	_, err = client.Update(ctx, "events", "id=eq."+eventID, map[string]any{
		"status":                "cancelled",
		"preshards_pool":        0,
		"preshards_distributed": true,
	})
	if err != nil {
		return errors.Join(fmt.Errorf("cancel event: update: %w", err), refundErr)
	}

	details, err := json.Marshal(map[string]any{
		"reason":            reason,
		"preshard_returned": true,
	})
	if err != nil {
		return errors.Join(fmt.Errorf("cancel event: marshal audit details: %w", err), refundErr)
	}
	return errors.Join(LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "cancel_event",
		TargetType:  "event",
		TargetID:    eventID,
		Details:     details,
	}), refundErr)
}

func DistributeShards(ctx context.Context, client *db.DBClient, eventID, adminUserID string) error {
	body, err := client.RPC(ctx, "distribute_shards", map[string]any{
		"p_event_id": eventID,
	})
	if err != nil {
		return fmt.Errorf("distribute shards: %w", err)
	}
	var result any
	if err := json.Unmarshal(body, &result); err != nil {
		// The RPC succeeded; the body only feeds the audit trail. Record the
		// raw body so the response is not lost, and surface the parse
		// failure instead of swallowing it.
		auditErr := LogAction(ctx, client, AuditParams{
			AdminUserID: adminUserID,
			Action:      "distribute_shards",
			TargetType:  "event",
			TargetID:    eventID,
			Details:     json.RawMessage(body),
		})
		return errors.Join(fmt.Errorf("distribute shards: unmarshal response: %w", err), auditErr)
	}
	details, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("distribute shards: marshal audit details: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "distribute_shards",
		TargetType:  "event",
		TargetID:    eventID,
		Details:     details,
	})
}
