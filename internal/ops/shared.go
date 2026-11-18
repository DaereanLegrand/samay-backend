package ops

import (
	"context"

	"github.com/samay-app/samay/internal/db"
)

// GetShardLedger reads a user's shard ledger page. The shard economy was
// removed from the product, but the row history is retained read-only for the
// admin users surface (`GET /users/:id/ledger`, `samay-admin users`).
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
