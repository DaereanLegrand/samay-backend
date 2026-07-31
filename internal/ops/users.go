package ops

import (
	"encoding/json"
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

func ListUsers(client *db.DBClient, params ListUsersParams) ([]db.User, error) {
	q := "id,username,subscription_tier,personal_shards,preshards,created_at,banned_at"
	if params.Banned {
		q += "&banned_at=not.is.null"
	}
	if params.Tier != "" {
		q += "&subscription_tier=eq." + params.Tier
	}
	if params.Search != "" {
		q += "&username.ilike.*" + params.Search + "*"
	}
	body, err := client.Select("users", q, 100, 0)
	if err != nil {
		return nil, fmt.Errorf("list users: %w", err)
	}
	var users []db.User
	if err := json.Unmarshal(body, &users); err != nil {
		return nil, fmt.Errorf("unmarshal users: %w", err)
	}
	return users, nil
}

func GetUser(client *db.DBClient, userID string) (*UserDetail, error) {
	body, err := client.Select("users", "id,username,avatar_url,date_of_birth,bio,banned_at,ban_reason,personal_shards,preshards,subscription_tier,subscription_expires_at,created_at,updated_at&id=eq."+userID, 1, 0)
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

	ledgerBody, _ := client.Select("shard_ledger", "id,delta,reason,reference_id,created_at&user_id=eq."+userID+"&order=created_at.desc&limit=10", 10, 0)
	var ledger []db.ShardLedgerEntry
	json.Unmarshal(ledgerBody, &ledger)

	membersBody, _ := client.Select("group_members", "id,group_id,user_id,role,joined_at&user_id=eq."+userID, 50, 0)
	var memberships []db.GroupMember
	json.Unmarshal(membersBody, &memberships)

	return &UserDetail{
		User:             users[0],
		ShardLedger:      ledger,
		GroupMemberships: memberships,
	}, nil
}

func BanUser(client *db.DBClient, userID, reason, adminUserID string) error {
	_, err := client.Update("users", "id=eq."+userID, map[string]interface{}{
		"banned_at":  "now()",
		"ban_reason": reason,
	})
	if err != nil {
		return fmt.Errorf("ban user: %w", err)
	}
	details, _ := json.Marshal(map[string]string{"reason": reason})
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "ban_user",
		TargetType:  "user",
		TargetID:    userID,
		Details:     details,
	})
}

func UnbanUser(client *db.DBClient, userID, adminUserID string) error {
	_, err := client.Update("users", "id=eq."+userID, map[string]interface{}{
		"banned_at":  nil,
		"ban_reason": nil,
	})
	if err != nil {
		return fmt.Errorf("unban user: %w", err)
	}
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "unban_user",
		TargetType:  "user",
		TargetID:    userID,
	})
}

func GrantShards(client *db.DBClient, userID string, amount int, reason, adminUserID string) error {
	_, err := client.RPC("grant_shards", map[string]interface{}{
		"p_user_id": userID,
		"p_amount":  amount,
		"p_reason":  reason,
	})
	if err != nil {
		return fmt.Errorf("grant shards: %w", err)
	}
	details, _ := json.Marshal(map[string]interface{}{"amount": amount, "reason": reason})
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "grant_shards",
		TargetType:  "user",
		TargetID:    userID,
		Details:     details,
	})
}

func GrantPreshards(client *db.DBClient, userID string, amount int, reason, adminUserID string) error {
	_, err := client.RPC("grant_preshards", map[string]interface{}{
		"p_user_id": userID,
		"p_amount":  amount,
		"p_reason":  reason,
	})
	if err != nil {
		return fmt.Errorf("grant preshards: %w", err)
	}
	details, _ := json.Marshal(map[string]interface{}{"amount": amount, "reason": reason})
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "grant_preshards",
		TargetType:  "user",
		TargetID:    userID,
		Details:     details,
	})
}

func SoftDeleteUser(client *db.DBClient, userID, adminUserID string) error {
	if len(userID) < 8 {
		return fmt.Errorf("soft delete user: invalid user id %q", userID)
	}
	_, err := client.Update("users", "id=eq."+userID, map[string]interface{}{
		"deleted_at": "now()",
		"username":   "deleted_user_" + userID[:8],
		"avatar_url": nil,
		"bio":        nil,
	})
	if err != nil {
		return fmt.Errorf("soft delete user: %w", err)
	}
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "delete_user",
		TargetType:  "user",
		TargetID:    userID,
	})
}
