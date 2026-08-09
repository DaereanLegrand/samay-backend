package ops

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/samay-app/samay/internal/db"
)

type ListUsersParams struct {
	Search string
	Tier   string
	Banned bool
}

type UserDetail struct {
	User             db.User               `json:"user"`
	ShardLedger      []db.ShardLedgerEntry `json:"shard_ledger"`
	GroupMemberships []db.GroupMember      `json:"group_memberships"`
	RecentEvents     []db.Event            `json:"recent_events"`
}

func ListUsers(ctx context.Context, client *db.DBClient, params ListUsersParams) ([]db.User, error) {
	qb := db.NewQueryBuilder().
		Select("id", "username", "subscription_tier", "personal_shards", "preshards", "created_at", "banned_at").
		Limit(100)
	if params.Banned {
		qb.NotIsNull("banned_at")
	}
	if params.Tier != "" {
		qb.Eq("subscription_tier", params.Tier)
	}
	if params.Search != "" {
		qb.ILike("username", "*"+params.Search+"*")
	}
	return db.List[db.User](ctx, client, "users", qb)
}

// GetUser returns the user profile plus its secondary enrichments (shard
// ledger, group memberships). The secondary queries are best-effort: on
// failure the detail is returned with a joined error (errors.Join) so the
// caller can render the primary result while the failure stays explicit.
func GetUser(ctx context.Context, client *db.DBClient, userID string) (*UserDetail, error) {
	body, err := client.Select(ctx, "users", "id,username,avatar_url,date_of_birth,bio,banned_at,ban_reason,personal_shards,preshards,subscription_tier,subscription_expires_at,created_at,updated_at&id=eq."+userID, 1, 0)
	if err != nil {
		return nil, fmt.Errorf("get user: %w", err)
	}
	var users []db.User
	if err := json.Unmarshal(body, &users); err != nil {
		return nil, fmt.Errorf("unmarshal user: %w", err)
	}
	if len(users) == 0 {
		return nil, fmt.Errorf("user not found: %s", userID)
	}

	var ledger []db.ShardLedgerEntry
	var memberships []db.GroupMember
	var detailErrs []error

	ledgerBody, err := client.Select(ctx, "shard_ledger", "id,delta,reason,reference_id,created_at&user_id=eq."+userID+"&order=created_at.desc&limit=10", 10, 0)
	if err != nil {
		detailErrs = append(detailErrs, fmt.Errorf("get user: fetch shard ledger: %w", err))
	} else if err := json.Unmarshal(ledgerBody, &ledger); err != nil {
		detailErrs = append(detailErrs, fmt.Errorf("get user: unmarshal shard ledger: %w", err))
	}

	membersBody, err := client.Select(ctx, "group_members", "id,group_id,user_id,role,joined_at&user_id=eq."+userID, 50, 0)
	if err != nil {
		detailErrs = append(detailErrs, fmt.Errorf("get user: fetch group memberships: %w", err))
	} else if err := json.Unmarshal(membersBody, &memberships); err != nil {
		detailErrs = append(detailErrs, fmt.Errorf("get user: unmarshal group memberships: %w", err))
	}

	return &UserDetail{
		User:             users[0],
		ShardLedger:      ledger,
		GroupMemberships: memberships,
	}, errors.Join(detailErrs...)
}

func BanUser(ctx context.Context, client *db.DBClient, userID, reason, adminUserID string) error {
	_, err := client.Update(ctx, "users", "id=eq."+userID, map[string]interface{}{
		"banned_at":  "now()",
		"ban_reason": reason,
	})
	if err != nil {
		return fmt.Errorf("ban user: %w", err)
	}
	details, err := json.Marshal(map[string]string{"reason": reason})
	if err != nil {
		return fmt.Errorf("ban user: marshal audit details: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "ban_user",
		TargetType:  "user",
		TargetID:    userID,
		Details:     details,
	})
}

func UnbanUser(ctx context.Context, client *db.DBClient, userID, adminUserID string) error {
	_, err := client.Update(ctx, "users", "id=eq."+userID, map[string]interface{}{
		"banned_at":  nil,
		"ban_reason": nil,
	})
	if err != nil {
		return fmt.Errorf("unban user: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "unban_user",
		TargetType:  "user",
		TargetID:    userID,
	})
}

func GrantShards(ctx context.Context, client *db.DBClient, userID string, amount int, reason, adminUserID string) error {
	_, err := client.RPC(ctx, "grant_shards", map[string]interface{}{
		"p_user_id": userID,
		"p_amount":  amount,
		"p_reason":  reason,
	})
	if err != nil {
		return fmt.Errorf("grant shards: %w", err)
	}
	details, err := json.Marshal(map[string]interface{}{"amount": amount, "reason": reason})
	if err != nil {
		return fmt.Errorf("grant shards: marshal audit details: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "grant_shards",
		TargetType:  "user",
		TargetID:    userID,
		Details:     details,
	})
}

func GrantPreshards(ctx context.Context, client *db.DBClient, userID string, amount int, reason, adminUserID string) error {
	_, err := client.RPC(ctx, "grant_preshards", map[string]interface{}{
		"p_user_id": userID,
		"p_amount":  amount,
		"p_reason":  reason,
	})
	if err != nil {
		return fmt.Errorf("grant preshards: %w", err)
	}
	details, err := json.Marshal(map[string]interface{}{"amount": amount, "reason": reason})
	if err != nil {
		return fmt.Errorf("grant preshards: marshal audit details: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "grant_preshards",
		TargetType:  "user",
		TargetID:    userID,
		Details:     details,
	})
}

func SoftDeleteUser(ctx context.Context, client *db.DBClient, userID, adminUserID string) error {
	if len(userID) < 8 {
		return fmt.Errorf("soft delete user: invalid user id %q", userID)
	}
	_, err := client.Update(ctx, "users", "id=eq."+userID, map[string]interface{}{
		"deleted_at": "now()",
		"username":   "deleted_user_" + userID[:8],
		"avatar_url": nil,
		"bio":        nil,
	})
	if err != nil {
		return fmt.Errorf("soft delete user: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "delete_user",
		TargetType:  "user",
		TargetID:    userID,
	})
}
