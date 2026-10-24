package ops

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

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
		return nil, fmt.Errorf("user not found: %s: %w", userID, ErrNotFound)
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

func setGoTrueBan(ctx context.Context, client *db.DBClient, userID string, banned bool) error {
	duration := "876000h"
	if !banned {
		duration = "none"
	}
	body, err := json.Marshal(map[string]any{"ban_duration": duration})
	if err != nil {
		return fmt.Errorf("auth ban: marshal: %w", err)
	}
	req, err := http.NewRequestWithContext(
		ctx,
		http.MethodPut,
		strings.TrimRight(client.BaseURL, "/")+"/auth/v1/admin/users/"+userID,
		bytes.NewReader(body),
	)
	if err != nil {
		return fmt.Errorf("auth ban: request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+client.ServiceKey)
	req.Header.Set("apikey", client.ServiceKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("auth ban: %w", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode >= 400 {
		return fmt.Errorf("auth ban: %d: %s", resp.StatusCode, string(respBody))
	}
	return nil
}

// userAuditSnapshot is a best-effort before-image for the admin audit details.
// A failed read must not block the action; the audit then records before=nil.
func userAuditSnapshot(ctx context.Context, client *db.DBClient, userID string) map[string]any {
	body, err := client.Select(ctx, "users",
		"id,banned_at,ban_reason,deleted_at,subscription_tier,subscription_expires_at,subscription_source,subscription_grace_until&id=eq."+userID, 1, 0)
	if err != nil {
		return nil
	}
	var rows []map[string]any
	if err := json.Unmarshal(body, &rows); err != nil || len(rows) == 0 {
		return nil
	}
	return rows[0]
}

func BanUser(ctx context.Context, client *db.DBClient, userID, reason, adminUserID string) error {
	before := userAuditSnapshot(ctx, client, userID)
	now := time.Now().UTC()
	_, err := client.Update(ctx, "users", "id=eq."+userID, map[string]any{
		"banned_at":  now,
		"ban_reason": reason,
	})
	if err != nil {
		return fmt.Errorf("ban user: %w", err)
	}
	authErr := setGoTrueBan(ctx, client, userID, true)
	details, err := json.Marshal(map[string]any{
		"reason": reason,
		"before": before,
		"after": map[string]any{
			"banned_at":  now,
			"ban_reason": reason,
		},
		"source": "admin",
	})
	if err != nil {
		return fmt.Errorf("ban user: marshal audit details: %w", err)
	}
	auditErr := LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "ban_user",
		TargetType:  "user",
		TargetID:    userID,
		Details:     details,
	})
	return errors.Join(authErr, auditErr)
}

func UnbanUser(ctx context.Context, client *db.DBClient, userID, adminUserID string) error {
	before := userAuditSnapshot(ctx, client, userID)
	_, err := client.Update(ctx, "users", "id=eq."+userID, map[string]any{
		"banned_at":  nil,
		"ban_reason": nil,
	})
	if err != nil {
		return fmt.Errorf("unban user: %w", err)
	}
	authErr := setGoTrueBan(ctx, client, userID, false)
	details, err := json.Marshal(map[string]any{
		"reason": "unban",
		"before": before,
		"after": map[string]any{
			"banned_at":  nil,
			"ban_reason": nil,
		},
		"source": "admin",
	})
	if err != nil {
		return fmt.Errorf("unban user: marshal audit details: %w", err)
	}
	auditErr := LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "unban_user",
		TargetType:  "user",
		TargetID:    userID,
		Details:     details,
	})
	return errors.Join(authErr, auditErr)
}

func GrantShards(ctx context.Context, client *db.DBClient, userID string, amount int, reason, adminUserID string) error {
	_, err := client.RPC(ctx, "grant_shards", map[string]any{
		"p_user_id": userID,
		"p_amount":  amount,
		"p_reason":  reason,
	})
	if err != nil {
		return fmt.Errorf("grant shards: %w", err)
	}
	details, err := json.Marshal(map[string]any{"amount": amount, "reason": reason})
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
	_, err := client.RPC(ctx, "grant_preshards", map[string]any{
		"p_user_id": userID,
		"p_amount":  amount,
		"p_reason":  reason,
	})
	if err != nil {
		return fmt.Errorf("grant preshards: %w", err)
	}
	details, err := json.Marshal(map[string]any{"amount": amount, "reason": reason})
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

// DeleteUser performs the Q1 hard delete through the same purge_user() RPC the
// app uses: public rows, retained-fact pseudonymization, auth rows, and the
// storage outbox in one transaction. It then verifies the GoTrue row is gone
// via the admin API (404 is success) so a privilege gap in SQL does not leave
// a live credential behind.
func DeleteUser(ctx context.Context, client *db.DBClient, userID, adminUserID string) error {
	if len(userID) < 8 {
		return fmt.Errorf("delete user: invalid user id %q: %w", userID, ErrInvalid)
	}
	before := userAuditSnapshot(ctx, client, userID)
	if _, err := client.RPC(ctx, "purge_user", map[string]any{"p_uid": userID}); err != nil {
		return fmt.Errorf("delete user: purge_user: %w", err)
	}
	if err := deleteGoTrueUser(ctx, client, userID); err != nil {
		return fmt.Errorf("delete user: verify auth row: %w", err)
	}
	details, err := json.Marshal(map[string]any{
		"reason": "account_deletion",
		"before": before,
		"after":  nil,
		"source": "admin",
	})
	if err != nil {
		return fmt.Errorf("delete user: marshal audit details: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "delete_user",
		TargetType:  "user",
		TargetID:    userID,
		Details:     details,
	})
}

// deleteGoTrueUser deletes the auth identity through the admin API. purge_user()
// normally removes it in SQL; a 404 here confirms that. Any other non-2xx is
// returned so the admin surface can retry (auth_cleanup_queue also records it).
func deleteGoTrueUser(ctx context.Context, client *db.DBClient, userID string) error {
	req, err := http.NewRequestWithContext(
		ctx,
		http.MethodDelete,
		strings.TrimRight(client.BaseURL, "/")+"/auth/v1/admin/users/"+userID,
		nil,
	)
	if err != nil {
		return fmt.Errorf("auth delete: request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+client.ServiceKey)
	req.Header.Set("apikey", client.ServiceKey)
	resp, err := client.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("auth delete: %w", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode == http.StatusNotFound {
		return nil
	}
	if resp.StatusCode >= 400 {
		return fmt.Errorf("auth delete: %d: %s", resp.StatusCode, string(respBody))
	}
	return nil
}
