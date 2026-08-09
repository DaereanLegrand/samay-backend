package ops

import (
	"context"
	"strings"
	"testing"
)

func TestGetShardLedger_DefaultLimit(t *testing.T) {
	client, srv, log := newTestClientWithLog(`[]`, 200)
	defer srv.Close()

	_, err := GetShardLedger(context.Background(), client, "u1", 0)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	assertContains(t, (*log)[0].Path, "/rest/v1/shard_ledger")
	assertContains(t, (*log)[0].Path, "user_id=eq.u1")
	assertContains(t, (*log)[0].Path, "order=created_at.desc")
	assertContains(t, (*log)[0].Path, "limit=50")
}

func TestGetShardLedger_CustomLimit(t *testing.T) {
	tests := []struct {
		name     string
		limit    int
		wantPath string
	}{
		{name: "negative becomes default", limit: -5, wantPath: "limit=50"},
		{name: "custom limit", limit: 25, wantPath: "limit=25"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client, srv, log := newTestClientWithLog(`[]`, 200)
			defer srv.Close()

			_, err := GetShardLedger(context.Background(), client, "u1", tt.limit)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			assertContains(t, (*log)[0].Path, tt.wantPath)
		})
	}
}

func TestGetShardLedger_ParsesResponse(t *testing.T) {
	resp := `[{"id":"s1","user_id":"u1","delta":50,"reason":"admin_grant"},{"id":"s2","user_id":"u1","delta":-10,"reason":"purchase"}]`
	client, srv, _ := newTestClientWithLog(resp, 200)
	defer srv.Close()

	entries, err := GetShardLedger(context.Background(), client, "u1", 50)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(entries) != 2 || entries[0].Delta != 50 || entries[1].Reason != "purchase" {
		t.Errorf("unexpected ledger parsed: %+v", entries)
	}
}

func TestGetShardLedger_UnmarshalError(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`bad`, 200)
	defer srv.Close()

	_, err := GetShardLedger(context.Background(), client, "u1", 50)

	if err == nil || !strings.Contains(err.Error(), "unmarshal") {
		t.Errorf("expected unmarshal error, got: %v", err)
	}
}

func TestGetGroupShardLedger_PathAndParse(t *testing.T) {
	resp := `[{"id":"c1","group_id":"g1","user_id":"u1","shards_contributed":100}]`
	client, srv, log := newTestClientWithLog(resp, 200)
	defer srv.Close()

	entries, err := GetGroupShardLedger(context.Background(), client, "g1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(entries) != 1 || entries[0].ShardsContributed != 100 {
		t.Errorf("unexpected contributions parsed: %+v", entries)
	}
	assertContains(t, (*log)[0].Path, "/rest/v1/group_shard_contributions")
	assertContains(t, (*log)[0].Path, "group_id=eq.g1")
	assertContains(t, (*log)[0].Path, "order=contributed_at.desc")
}

func TestGetGroupShardLedger_UnmarshalError(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`bad`, 200)
	defer srv.Close()

	_, err := GetGroupShardLedger(context.Background(), client, "g1")

	if err == nil || !strings.Contains(err.Error(), "unmarshal") {
		t.Errorf("expected unmarshal error, got: %v", err)
	}
}

func TestRecalculateRanks_RPCParams(t *testing.T) {
	tests := []struct {
		name    string
		tier    string
		want    string
		notWant string
	}{
		{name: "no tier", tier: "", want: "", notWant: "p_tier"},
		{name: "with tier", tier: "small", want: `"p_tier":"small"`, notWant: ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client, srv, log := newTestClientWithLog(`{}`, 200)
			defer srv.Close()

			err := RecalculateRanks(context.Background(), client, tt.tier)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(*log) != 1 {
				t.Fatalf("expected 1 request, got %d", len(*log))
			}
			assertContains(t, (*log)[0].Path, "/rest/v1/rpc/recalculate_ranks")
			if tt.want != "" {
				assertContains(t, (*log)[0].Body, tt.want)
			}
			if tt.notWant != "" {
				assertNotContains(t, (*log)[0].Body, tt.notWant)
			}
		})
	}
}

func TestRecalculateRanks_RPCErrorPropagates(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`{"message":"rpc failed"}`, 500)
	defer srv.Close()

	err := RecalculateRanks(context.Background(), client, "medium")

	if err == nil || !strings.Contains(err.Error(), "recalculate ranks") {
		t.Errorf("expected RPC failure to propagate, got: %v", err)
	}
}
