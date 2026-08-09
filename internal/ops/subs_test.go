package ops

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestListSubs_PathConstruction(t *testing.T) {
	baseSelect := "select=id,username,subscription_tier,subscription_expires_at,created_at"

	tests := []struct {
		name    string
		params  ListSubsParams
		want    []string
		notWant []string
	}{
		{
			name:   "no filters",
			params: ListSubsParams{},
			want:   []string{"/rest/v1/users", baseSelect, "limit=100"},
		},
		{
			name:   "tier filter",
			params: ListSubsParams{Tier: "pro"},
			want:   []string{"subscription_tier=eq.pro"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client, srv, log := newTestClientWithLog(`[]`, 200)
			defer srv.Close()

			_, err := ListSubs(context.Background(), client, tt.params)
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

func TestListSubs_ParsesResponse(t *testing.T) {
	resp := `[{"id":"u1","username":"alice","subscription_tier":"pro"},{"id":"u2","username":"bob","subscription_tier":"vip"}]`
	client, srv, _ := newTestClientWithLog(resp, 200)
	defer srv.Close()

	users, err := ListSubs(context.Background(), client, ListSubsParams{})

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(users) != 2 || users[0].ID != "u1" || users[1].SubscriptionTier != "vip" {
		t.Errorf("unexpected users parsed: %+v", users)
	}
}

func TestListSubs_UnmarshalError(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`not json`, 200)
	defer srv.Close()

	_, err := ListSubs(context.Background(), client, ListSubsParams{})

	if err == nil || !strings.Contains(err.Error(), "unmarshal") {
		t.Errorf("expected unmarshal error, got: %v", err)
	}
}

func TestGetSub_PathAndParse(t *testing.T) {
	resp := `[{"id":"u1","username":"alice","subscription_tier":"pro"}]`
	client, srv, log := newTestClientWithLog(resp, 200)
	defer srv.Close()

	user, err := GetSub(context.Background(), client, "u1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if user.ID != "u1" || user.SubscriptionTier != "pro" {
		t.Errorf("unexpected user: %+v", user)
	}
	assertContains(t, (*log)[0].Path, "/rest/v1/users")
	assertContains(t, (*log)[0].Path, "id=eq.u1")
	assertContains(t, (*log)[0].Path, "limit=1")
}

func TestGetSub_NotFound(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`[]`, 200)
	defer srv.Close()

	_, err := GetSub(context.Background(), client, "missing")

	if err == nil || !strings.Contains(err.Error(), "not found") {
		t.Errorf("expected 'not found' error, got: %v", err)
	}
}

func TestOverrideSub_InsertsAndAudits(t *testing.T) {
	expires := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	client, srv, log := newTestClientWithLog(`{}`, 200)
	defer srv.Close()

	err := OverrideSub(context.Background(), client, "u1", "vip", "admin-1", expires, "compensation")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := countRequests(log, "POST", "/rest/v1/subscription_overrides"); got != 1 {
		t.Fatalf("expected 1 insert on subscription_overrides, got %d", got)
	}
	insert := firstRequestOf(log, "POST", "/rest/v1/subscription_overrides")
	assertContains(t, insert.Path, "select=*")
	assertContains(t, insert.Body, `"user_id":"u1"`)
	assertContains(t, insert.Body, `"admin_user_id":"admin-1"`)
	assertContains(t, insert.Body, `"tier":"vip"`)
	assertContains(t, insert.Body, `"expires_at":"2026-09-01T00:00:00Z"`)
	assertContains(t, insert.Body, `"reason":"compensation"`)

	audit := lastRequest(log)
	assertContains(t, audit.Path, "/rest/v1/admin_audit_log")
	assertContains(t, audit.Body, `"action":"subscription_override"`)
	assertContains(t, audit.Body, `"target_id":"u1"`)
	assertContains(t, audit.Body, `"tier":"vip"`)
	assertContains(t, audit.Body, `"expires":"2026-09-01T00:00:00Z"`)
}

func TestOverrideSub_InsertErrorPropagates(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`{"message":"boom"}`, 500)
	defer srv.Close()

	err := OverrideSub(context.Background(), client, "u1", "vip", "admin-1", time.Now(), "test")

	if err == nil || !strings.Contains(err.Error(), "500") {
		t.Errorf("expected 500 error, got: %v", err)
	}
}

func TestRevokeOverride_PatchesAndAudits(t *testing.T) {
	client, srv, log := newTestClientWithLog(`{}`, 200)
	defer srv.Close()

	err := RevokeOverride(context.Background(), client, "u1", "admin-1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := countRequests(log, "PATCH", "/rest/v1/subscription_overrides"); got != 1 {
		t.Fatalf("expected 1 PATCH on subscription_overrides, got %d", got)
	}
	patch := firstRequestOf(log, "PATCH", "/rest/v1/subscription_overrides")
	assertContains(t, patch.Path, "user_id=eq.u1")
	assertContains(t, patch.Path, "revoked=eq.false")
	assertContains(t, patch.Body, `"revoked":true`)

	audit := lastRequest(log)
	assertContains(t, audit.Path, "/rest/v1/admin_audit_log")
	assertContains(t, audit.Body, `"action":"revoke_subscription_override"`)
	assertContains(t, audit.Body, `"target_type":"subscription"`)
	assertContains(t, audit.Body, `"target_id":"u1"`)
}
