package ops

import (
	"encoding/json"
	"fmt"

	"github.com/vive-app/vive/internal/db"
)

type ListGroupsParams struct {
	SizeTier string
	Bracket  string
}

func ListGroups(client *db.DBClient, params ListGroupsParams) ([]db.Group, error) {
	q := "id,name,size_tier,rank_bracket,group_shards,created_at"
	if params.SizeTier != "" {
		q += "&size_tier=eq." + params.SizeTier
	}
	if params.Bracket != "" {
		q += "&rank_bracket=eq." + params.Bracket
	}
	body, err := client.Select("groups", q, 100, 0)
	if err != nil {
		return nil, fmt.Errorf("list groups: %w", err)
	}
	var groups []db.Group
	if err := json.Unmarshal(body, &groups); err != nil {
		return nil, fmt.Errorf("unmarshal groups: %w", err)
	}
	return groups, nil
}

func GetGroup(client *db.DBClient, groupID string) (*db.Group, error) {
	body, err := client.Select("groups", "*,group_members(id,user_id,role),group_shard_contributions(id,user_id,shards_contributed)&id=eq."+groupID, 1, 0)
	if err != nil {
		return nil, fmt.Errorf("get group: %w", err)
	}
	var groups []db.Group
	if err := json.Unmarshal(body, &groups); err != nil {
		return nil, fmt.Errorf("unmarshal group: %w", err)
	}
	if len(groups) == 0 {
		return nil, fmt.Errorf("group not found: %s", groupID)
	}
	return &groups[0], nil
}

func ListGroupMembers(client *db.DBClient, groupID string) ([]db.GroupMember, error) {
	body, err := client.Select("group_members", "id,user_id,role,joined_at&group_id=eq."+groupID, 100, 0)
	if err != nil {
		return nil, fmt.Errorf("list group members: %w", err)
	}
	var members []db.GroupMember
	if err := json.Unmarshal(body, &members); err != nil {
		return nil, fmt.Errorf("unmarshal group members: %w", err)
	}
	return members, nil
}
