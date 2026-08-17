package ops

import (
	"context"
	"fmt"

	"github.com/samay-app/samay/internal/db"
)

type ShardLedgerParams struct {
	UserID string
	Limit  int
}

func GetShardLedger(ctx context.Context, client *db.DBClient, userID string, limit int) ([]db.ShardLedgerEntry, error) {
	if limit <= 0 {
		limit = 50
	}
	qb := db.NewQueryBuilder().
		Select("id", "delta", "reason", "reference_id", "created_at").
		Eq("user_id", userID).
		Order("created_at", false).
		Limit(limit)
	return db.List[db.ShardLedgerEntry](ctx, client, "shard_ledger", qb)
}

func GetGroupShardLedger(ctx context.Context, client *db.DBClient, groupID string) ([]db.GroupShardContribution, error) {
	qb := db.NewQueryBuilder().
		Select("id", "user_id", "shards_contributed", "contributed_at", "expires_at").
		Eq("group_id", groupID).
		Order("contributed_at", false).
		Limit(100)
	return db.List[db.GroupShardContribution](ctx, client, "group_shard_contributions", qb)
}

func RecalculateRanks(ctx context.Context, client *db.DBClient, tier string) error {
	params := map[string]any{}
	if tier != "" {
		params["p_tier"] = tier
	}
	_, err := client.RPC(ctx, "recalculate_ranks", params)
	if err != nil {
		return fmt.Errorf("recalculate ranks: %w", err)
	}
	return nil
}
