package ops

import (
	"context"
	"strings"
	"testing"
)

func TestListGroups_PathConstruction(t *testing.T) {
	baseSelect := "select=id,name,size_tier,rank_bracket,group_shards,created_at"

	tests := []struct {
		name    string
		params  ListGroupsParams
		want    []string
		notWant []string
	}{
		{
			name:   "no filters",
			params: ListGroupsParams{},
			want:   []string{"/rest/v1/groups", baseSelect, "limit=100"},
		},
		{
			name:    "size tier filter",
			params:  ListGroupsParams{SizeTier: "small"},
			want:    []string{"size_tier=eq.small"},
			notWant: []string{"rank_bracket=eq."},
		},
		{
			name:    "bracket filter",
			params:  ListGroupsParams{Bracket: "b20_40"},
			want:    []string{"rank_bracket=eq.b20_40"},
			notWant: []string{"size_tier=eq."},
		},
		{
			name:   "both filters",
			params: ListGroupsParams{SizeTier: "large", Bracket: "b80_90"},
			want:   []string{"size_tier=eq.large", "rank_bracket=eq.b80_90"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client, srv, log := newTestClientWithLog(`[]`, 200)
			defer srv.Close()

			_, err := ListGroups(context.Background(), client, tt.params)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(*log) != 1 {
				t.Fatalf("expected 1 request, got %d", len(*log))
			}
			for _, want := range tt.want {
				assertContains(t, (*log)[0].Path, want)
			}
			for _, notWant := range tt.notWant {
				assertNotContains(t, (*log)[0].Path, notWant)
			}
		})
	}
}

func TestListGroups_ParsesResponse(t *testing.T) {
	resp := `[{"id":"g1","name":"Disco Kings","group_shards":500},{"id":"g2","name":"Synthwave","group_shards":120}]`
	client, srv, _ := newTestClientWithLog(resp, 200)
	defer srv.Close()

	groups, err := ListGroups(context.Background(), client, ListGroupsParams{})

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(groups) != 2 {
		t.Fatalf("expected 2 groups, got %d", len(groups))
	}
	if groups[0].ID != "g1" || groups[0].GroupShards != 500 {
		t.Errorf("unexpected groups parsed: %+v", groups)
	}
}

func TestListGroups_UnmarshalError(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`not json`, 200)
	defer srv.Close()

	_, err := ListGroups(context.Background(), client, ListGroupsParams{})

	if err == nil || !strings.Contains(err.Error(), "unmarshal") {
		t.Errorf("expected unmarshal error, got: %v", err)
	}
}

func TestGetGroup_EmbeddedSelectPath(t *testing.T) {
	client, srv, log := newTestClientWithLog(`[{"id":"g1","name":"Disco Kings","size_tier":"small"}]`, 200)
	defer srv.Close()

	group, err := GetGroup(context.Background(), client, "g1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if group.ID != "g1" || group.Name != "Disco Kings" {
		t.Errorf("unexpected group: %+v", group)
	}
	if len(*log) != 1 {
		t.Fatalf("expected 1 request, got %d", len(*log))
	}
	assertContains(t, (*log)[0].Path, "*,group_members(id,user_id,role),group_shard_contributions(id,user_id,shards_contributed)")
	assertContains(t, (*log)[0].Path, "id=eq.g1")
	assertContains(t, (*log)[0].Path, "limit=1")
}

func TestGetGroup_NotFound(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`[]`, 200)
	defer srv.Close()

	_, err := GetGroup(context.Background(), client, "missing")

	if err == nil || !strings.Contains(err.Error(), "not found") {
		t.Errorf("expected 'not found' error, got: %v", err)
	}
}

func TestListGroupMembers_PathAndParse(t *testing.T) {
	resp := `[{"id":"m1","user_id":"u1","role":"member","status":"active"},{"id":"m2","user_id":"u2","role":"leader","status":"active"}]`
	client, srv, log := newTestClientWithLog(resp, 200)
	defer srv.Close()

	members, err := ListGroupMembers(context.Background(), client, "g1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(members) != 2 {
		t.Fatalf("expected 2 members, got %d", len(members))
	}
	if members[1].Role != "leader" {
		t.Errorf("unexpected members parsed: %+v", members)
	}
	assertContains(t, (*log)[0].Path, "/rest/v1/group_members")
	assertContains(t, (*log)[0].Path, "group_id=eq.g1")
	assertContains(t, (*log)[0].Path, "limit=100")
}

func TestListGroupMembers_UnmarshalError(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`bad`, 200)
	defer srv.Close()

	_, err := ListGroupMembers(context.Background(), client, "g1")

	if err == nil || !strings.Contains(err.Error(), "unmarshal") {
		t.Errorf("expected unmarshal error, got: %v", err)
	}
}
