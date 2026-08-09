package ops

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/samay-app/samay/internal/db"
)

type ListSubsParams struct {
	Tier           string
	ExpiringWithin int
}

func ListSubs(ctx context.Context, client *db.DBClient, params ListSubsParams) ([]db.User, error) {
	qb := db.NewQueryBuilder().
		Select("id", "username", "subscription_tier", "subscription_expires_at", "created_at").
		Limit(100)
	if params.Tier != "" {
		qb.Eq("subscription_tier", params.Tier)
	}
	return db.List[db.User](ctx, client, "users", qb)
}

func GetSub(ctx context.Context, client *db.DBClient, userID string) (*db.User, error) {
	qb := db.NewQueryBuilder().
		Select("id", "username", "subscription_tier", "subscription_expires_at", "created_at", "updated_at")
	return db.GetByID[db.User](ctx, client, "users", userID, qb)
}

func OverrideSub(ctx context.Context, client *db.DBClient, userID, tier, adminUserID string, expiresAt time.Time, reason string) error {
	_, err := client.Insert(ctx, "subscription_overrides", map[string]interface{}{
		"user_id":       userID,
		"admin_user_id": adminUserID,
		"tier":          tier,
		"expires_at":    expiresAt.Format(time.RFC3339),
		"reason":        reason,
	})
	if err != nil {
		return fmt.Errorf("override sub: %w", err)
	}
	details, err := json.Marshal(map[string]interface{}{
		"tier":    tier,
		"expires": expiresAt.Format(time.RFC3339),
	})
	if err != nil {
		return fmt.Errorf("override sub: marshal audit details: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "subscription_override",
		TargetType:  "subscription",
		TargetID:    userID,
		Details:     details,
	})
}

func RevokeOverride(ctx context.Context, client *db.DBClient, userID, adminUserID string) error {
	_, err := client.Update(ctx, "subscription_overrides", "user_id=eq."+userID+"&revoked=eq.false", map[string]interface{}{
		"revoked": true,
	})
	if err != nil {
		return fmt.Errorf("revoke override: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "revoke_subscription_override",
		TargetType:  "subscription",
		TargetID:    userID,
	})
}
