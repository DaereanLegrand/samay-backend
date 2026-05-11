package ops

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/vive-app/vive/internal/db"
)

type ListEventsParams struct {
	Status  string
	Type    string
	Promotor string
}

type EventDetail struct {
	Event              db.Event          `json:"event"`
	Promotores         []db.EventPromotor `json:"promotores"`
	ConfirmedAttendees int               `json:"confirmed_attendees"`
	PreshardPoolStatus string            `json:"preshard_pool_status"`
}

func ListEvents(client *db.DBClient, params ListEventsParams) ([]db.Event, error) {
	q := "id,name,type,status,starts_at,ends_at,created_by_user_id,preshards_pool,featured"
	if params.Status != "" {
		q += "&status=eq." + params.Status
	}
	if params.Type != "" {
		q += "&type=eq." + params.Type
	}
	if params.Promotor != "" {
		q += "&created_by_user_id=eq." + params.Promotor
	}
	body, err := client.Select("events", q, 100, 0)
	if err != nil {
		return nil, fmt.Errorf("list events: %w", err)
	}
	var events []db.Event
	if err := json.Unmarshal(body, &events); err != nil {
		return nil, fmt.Errorf("unmarshal events: %w", err)
	}
	return events, nil
}

func GetEvent(client *db.DBClient, eventID string) (*EventDetail, error) {
	body, err := client.Select("events", "*,event_promotores(*),event_attendances(id)&id=eq."+eventID, 1, 0)
	if err != nil {
		return nil, fmt.Errorf("get event: %w", err)
	}
	var events []db.Event
	if err := json.Unmarshal(body, &events); err != nil {
		return nil, fmt.Errorf("unmarshal event: %w", err)
	}
	if len(events) == 0 {
		return nil, fmt.Errorf("event not found: %s", eventID)
	}

	promoBody, _ := client.Select("event_promotores", "id,event_id,user_id,role,preshards_contributed,added_at&event_id=eq."+eventID, 50, 0)
	var promotores []db.EventPromotor
	json.Unmarshal(promoBody, &promotores)

	return &EventDetail{
		Event:     events[0],
		Promotores: promotores,
	}, nil
}

func FeatureEvent(client *db.DBClient, eventID string, expiresAt time.Time, adminUserID string) error {
	_, err := client.Update("events", "id=eq."+eventID, map[string]interface{}{
		"featured":      true,
		"featured_until": expiresAt.Format(time.RFC3339),
	})
	if err != nil {
		return fmt.Errorf("feature event: %w", err)
	}
	if _, err := client.Update("feature_requests", "event_id=eq."+eventID+"&status=eq.pending", map[string]interface{}{
		"status":         "approved",
		"featured_until": expiresAt.Format(time.RFC3339),
	}); err != nil {
		return fmt.Errorf("feature event: approve request: %w", err)
	}
	details, _ := json.Marshal(map[string]string{"expires_at": expiresAt.Format(time.RFC3339)})
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "feature_event",
		TargetType:  "event",
		TargetID:    eventID,
		Details:     details,
	})
}

func UnfeatureEvent(client *db.DBClient, eventID, adminUserID string) error {
	_, err := client.Update("events", "id=eq."+eventID, map[string]interface{}{
		"featured":      false,
		"featured_until": nil,
	})
	if err != nil {
		return fmt.Errorf("unfeature event: %w", err)
	}
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "unfeature_event",
		TargetType:  "event",
		TargetID:    eventID,
	})
}

func RejectFeatureEvent(client *db.DBClient, eventID, adminUserID string) error {
	_, err := client.Update("feature_requests", "event_id=eq."+eventID+"&status=eq.pending", map[string]interface{}{
		"status": "rejected",
	})
	if err != nil {
		return fmt.Errorf("reject feature request: %w", err)
	}
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "reject_feature",
		TargetType:  "event",
		TargetID:    eventID,
	})
}

func CancelEvent(client *db.DBClient, eventID, reason, adminUserID string) error {
	eventBody, err := client.Select("events",
		"id,status,preshards_pool&id=eq."+eventID, 1, 0)
	if err != nil {
		return fmt.Errorf("cancel event: get event: %w", err)
	}
	var events []db.Event
	if err := json.Unmarshal(eventBody, &events); err != nil {
		return fmt.Errorf("cancel event: unmarshal: %w", err)
	}
	if len(events) == 0 {
		return fmt.Errorf("cancel event: not found: %s", eventID)
	}

	if events[0].Status == "cancelled" {
		return nil
	}

	pool, _ := client.Select("event_promotores",
		"id,user_id,preshards_contributed&event_id=eq."+eventID, 100, 0)
	var promotores []db.EventPromotor
	json.Unmarshal(pool, &promotores)

	for _, p := range promotores {
		if p.PreshardsContributed > 0 {
			client.Insert("preshard_ledger", map[string]interface{}{
				"user_id":      p.UserID,
				"delta":        p.PreshardsContributed,
				"reason":       "event_pool_returned",
				"reference_id": eventID,
			})
		}
	}

	_, err = client.Update("events", "id=eq."+eventID, map[string]interface{}{
		"status":             "cancelled",
		"preshards_pool":     0,
		"preshards_distributed": true,
	})
	if err != nil {
		return fmt.Errorf("cancel event: update: %w", err)
	}

	details, _ := json.Marshal(map[string]interface{}{
		"reason":       reason,
		"preshard_returned": true,
	})
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "cancel_event",
		TargetType:  "event",
		TargetID:    eventID,
		Details:     details,
	})
}

func DistributeShards(client *db.DBClient, eventID, adminUserID string) error {
	body, err := client.RPC("distribute_shards", map[string]interface{}{
		"p_event_id": eventID,
	})
	if err != nil {
		return fmt.Errorf("distribute shards: %w", err)
	}
	var result map[string]interface{}
	json.Unmarshal(body, &result)
	details, _ := json.Marshal(result)
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "distribute_shards",
		TargetType:  "event",
		TargetID:    eventID,
		Details:     details,
	})
}
