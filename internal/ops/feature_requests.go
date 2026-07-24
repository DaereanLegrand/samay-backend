package ops

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/samay-app/samay/internal/db"
)

type ListFeatureRequestsParams struct {
	Status string
}

func ListFeatureRequests(client *db.DBClient, params ListFeatureRequestsParams) ([]db.FeatureRequest, error) {
	q := "id,event_id,requested_by_user_id,contact_info,desired_duration_days,status,created_at"
	if params.Status != "" {
		q += "&status=eq." + params.Status
	}
	body, err := client.Select("feature_requests", q, 100, 0)
	if err != nil {
		return nil, fmt.Errorf("list feature requests: %w", err)
	}
	var requests []db.FeatureRequest
	if err := json.Unmarshal(body, &requests); err != nil {
		return nil, fmt.Errorf("unmarshal feature requests: %w", err)
	}
	return requests, nil
}

func ApproveFeatureRequest(client *db.DBClient, requestID string, featuredUntil time.Time, adminUserID string) error {
	_, err := client.Update("feature_requests", "id=eq."+requestID, map[string]interface{}{
		"status":        "approved",
		"featured_until": featuredUntil.Format(time.RFC3339),
	})
	if err != nil {
		return fmt.Errorf("approve feature request: %w", err)
	}
	details, _ := json.Marshal(map[string]string{
		"featured_until": featuredUntil.Format(time.RFC3339),
	})
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "approve_feature_request",
		TargetType:  "feature_request",
		TargetID:    requestID,
		Details:     details,
	})
}

func RejectFeatureRequest(client *db.DBClient, requestID, adminUserID string) error {
	_, err := client.Update("feature_requests", "id=eq."+requestID, map[string]interface{}{
		"status": "rejected",
	})
	if err != nil {
		return fmt.Errorf("reject feature request: %w", err)
	}
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "reject_feature_request",
		TargetType:  "feature_request",
		TargetID:    requestID,
	})
}
