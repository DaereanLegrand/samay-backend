package ops

import (
	"encoding/json"
	"fmt"

	"github.com/vive-app/vive/internal/db"
)

type ShardLedgerParams struct {
	UserID string
	Limit  int
}

func GetShardLedger(client *db.DBClient, userID string, limit int) ([]db.ShardLedgerEntry, error) {
	if limit <= 0 {
		limit = 50
	}
	body, err := client.Select("shard_ledger", "id,delta,reason,reference_id,created_at&user_id=eq."+userID+"&order=created_at.desc", limit, 0)
	if err != nil {
		return nil, fmt.Errorf("get shard ledger: %w", err)
	}
	var entries []db.ShardLedgerEntry
	if err := json.Unmarshal(body, &entries); err != nil {
		return nil, fmt.Errorf("unmarshal shard ledger: %w", err)
	}
	return entries, nil
}

func GetGroupShardLedger(client *db.DBClient, groupID string) ([]db.GroupShardContribution, error) {
	body, err := client.Select("group_shard_contributions", "id,user_id,shards_contributed,contributed_at,expires_at&group_id=eq."+groupID+"&order=contributed_at.desc&limit=100", 100, 0)
	if err != nil {
		return nil, fmt.Errorf("get group shard ledger: %w", err)
	}
	var entries []db.GroupShardContribution
	if err := json.Unmarshal(body, &entries); err != nil {
		return nil, fmt.Errorf("unmarshal group shard contributions: %w", err)
	}
	return entries, nil
}

func RecalculateRanks(client *db.DBClient, tier string) error {
	params := map[string]interface{}{}
	if tier != "" {
		params["p_tier"] = tier
	}
	_, err := client.RPC("recalculate_ranks", params)
	if err != nil {
		return fmt.Errorf("recalculate ranks: %w", err)
	}
	return nil
}
