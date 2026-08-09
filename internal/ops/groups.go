package ops

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/samay-app/samay/internal/db"
)

type ListGroupsParams struct {
	SizeTier string
	Bracket  string
}

func ListGroups(ctx context.Context, client *db.DBClient, params ListGroupsParams) ([]db.Group, error) {
	qb := db.NewQueryBuilder().
		Select("id", "name", "size_tier", "rank_bracket", "group_shards", "created_at").
		Limit(100)
	if params.SizeTier != "" {
		qb.Eq("size_tier", params.SizeTier)
	}
	if params.Bracket != "" {
		qb.Eq("rank_bracket", params.Bracket)
	}
	return db.List[db.Group](ctx, client, "groups", qb)
}

func GetGroup(ctx context.Context, client *db.DBClient, groupID string) (*db.Group, error) {
	qb := db.NewQueryBuilder().
		Select("*,group_members(id,user_id,role),group_shard_contributions(id,user_id,shards_contributed)")
	return db.GetByID[db.Group](ctx, client, "groups", groupID, qb)
}

func ListGroupMembers(ctx context.Context, client *db.DBClient, groupID string) ([]db.GroupMember, error) {
	body, err := client.Select(ctx, "group_members", "id,user_id,role,joined_at&group_id=eq."+groupID, 100, 0)
	if err != nil {
		return nil, fmt.Errorf("list group members: %w", err)
	}
	var members []db.GroupMember
	if err := json.Unmarshal(body, &members); err != nil {
		return nil, fmt.Errorf("unmarshal group members: %w", err)
	}
	return members, nil
}
