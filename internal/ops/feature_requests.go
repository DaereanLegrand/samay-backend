package ops

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/samay-app/samay/internal/db"
)

type ListFeatureRequestsParams struct {
	Status string
}

func ListFeatureRequests(ctx context.Context, client *db.DBClient, params ListFeatureRequestsParams) ([]db.FeatureRequest, error) {
	qb := db.NewQueryBuilder().
		Select("id", "event_id", "requested_by_user_id", "contact_info", "desired_duration_days", "status", "created_at").
		Limit(100)
	if params.Status != "" {
		qb.Eq("status", params.Status)
	}
	return db.List[db.FeatureRequest](ctx, client, "feature_requests", qb)
}

func ApproveFeatureRequest(ctx context.Context, client *db.DBClient, requestID string, featuredUntil time.Time, adminUserID string) error {
	_, err := client.Update(ctx, "feature_requests", "id=eq."+requestID, map[string]any{
		"status":         "approved",
		"featured_until": featuredUntil.Format(time.RFC3339),
	})
	if err != nil {
		return fmt.Errorf("approve feature request: %w", err)
	}
	details, err := json.Marshal(map[string]string{
		"featured_until": featuredUntil.Format(time.RFC3339),
	})
	if err != nil {
		return fmt.Errorf("approve feature request: marshal audit details: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "approve_feature_request",
		TargetType:  "feature_request",
		TargetID:    requestID,
		Details:     details,
	})
}

func RejectFeatureRequest(ctx context.Context, client *db.DBClient, requestID, adminUserID string) error {
	_, err := client.Update(ctx, "feature_requests", "id=eq."+requestID, map[string]any{
		"status": "rejected",
	})
	if err != nil {
		return fmt.Errorf("reject feature request: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "reject_feature_request",
		TargetType:  "feature_request",
		TargetID:    requestID,
	})
}
