package ops

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/vive-app/vive/internal/db"
)

type ListSubsParams struct {
	Tier           string
	ExpiringWithin int
}

func ListSubs(client *db.DBClient, params ListSubsParams) ([]db.User, error) {
	q := "id,username,display_name,subscription_tier,subscription_expires_at,created_at"
	if params.Tier != "" {
		q += "&subscription_tier=eq." + params.Tier
	}
	body, err := client.Select("users", q, 100, 0)
	if err != nil {
		return nil, fmt.Errorf("list subs: %w", err)
	}
	var users []db.User
	if err := json.Unmarshal(body, &users); err != nil {
		return nil, fmt.Errorf("unmarshal users: %w", err)
	}
	return users, nil
}

func GetSub(client *db.DBClient, userID string) (*db.User, error) {
	body, err := client.Select("users", "id,username,display_name,subscription_tier,subscription_expires_at,created_at,updated_at&id=eq."+userID, 1, 0)
	if err != nil {
		return nil, fmt.Errorf("get sub: %w", err)
	}
	var users []db.User
	if err := json.Unmarshal(body, &users); err != nil {
		return nil, fmt.Errorf("unmarshal user: %w", err)
	}
	if len(users) == 0 {
		return nil, fmt.Errorf("user not found: %s", userID)
	}
	return &users[0], nil
}

func OverrideSub(client *db.DBClient, userID, tier, adminUserID string, expiresAt time.Time, reason string) error {
	_, err := client.Insert("subscription_overrides", map[string]interface{}{
		"user_id":      userID,
		"admin_user_id": adminUserID,
		"tier":         tier,
		"expires_at":   expiresAt.Format(time.RFC3339),
		"reason":       reason,
	})
	if err != nil {
		return fmt.Errorf("override sub: %w", err)
	}
	details, _ := json.Marshal(map[string]interface{}{
		"tier":     tier,
		"expires":  expiresAt.Format(time.RFC3339),
	})
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "subscription_override",
		TargetType:  "subscription",
		TargetID:    userID,
		Details:     details,
	})
}

func RevokeOverride(client *db.DBClient, userID, adminUserID string) error {
	_, err := client.Update("subscription_overrides", "user_id=eq."+userID+"&revoked=eq.false", map[string]interface{}{
		"revoked": true,
	})
	if err != nil {
		return fmt.Errorf("revoke override: %w", err)
	}
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "revoke_subscription_override",
		TargetType:  "subscription",
		TargetID:    userID,
	})
}
