package ops

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/samay-app/samay/internal/db"
)

func TestListUsers_ConstructsCorrectPath(t *testing.T) {
	client, srv, log := newTestClientWithLog(`[]`, 200)
	defer srv.Close()

	ListUsers(client, ListUsersParams{})

	if len(*log) != 1 {
		t.Fatalf("expected 1 request, got %d", len(*log))
	}
	req := (*log)[0]
	assertContains(t, req.Path, "/rest/v1/users")
	assertContains(t, req.Path, "select=id,username,subscription_tier,personal_shards,preshards,created_at,banned_at")
	assertContains(t, req.Path, "limit=100")
}

func TestListUsers_WithSearch(t *testing.T) {
	client, srv, log := newTestClientWithLog(`[]`, 200)
	defer srv.Close()

	ListUsers(client, ListUsersParams{Search: "alice"})

	req := (*log)[0]
	assertContains(t, req.Path, "username.ilike.*alice*")
}

func TestListUsers_WithTier(t *testing.T) {
	client, srv, log := newTestClientWithLog(`[]`, 200)
	defer srv.Close()

	ListUsers(client, ListUsersParams{Tier: "pro"})

	req := (*log)[0]
	assertContains(t, req.Path, "subscription_tier=eq.pro")
}

func TestListUsers_Banned(t *testing.T) {
	client, srv, log := newTestClientWithLog(`[]`, 200)
	defer srv.Close()

	ListUsers(client, ListUsersParams{Banned: true})

	req := (*log)[0]
	assertContains(t, req.Path, "banned_at=not.is.null")
}

func TestListUsers_ReturnsUsers(t *testing.T) {
	resp := `[{"id":"u1","username":"alice","subscription_tier":"free","personal_shards":100}]`
	client, srv, _ := newTestClientWithLog(resp, 200)
	defer srv.Close()

	users, err := ListUsers(client, ListUsersParams{})

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(users) != 1 {
		t.Fatalf("expected 1 user, got %d", len(users))
	}
	if users[0].ID != "u1" {
		t.Errorf("expected id u1, got %s", users[0].ID)
	}
	if users[0].PersonalShards != 100 {
		t.Errorf("expected 100 shards, got %d", users[0].PersonalShards)
	}
}

func TestListUsers_InvalidJSON(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`not json`, 200)
	defer srv.Close()

	_, err := ListUsers(client, ListUsersParams{})

	if err == nil || !strings.Contains(err.Error(), "unmarshal") {
		t.Errorf("expected unmarshal error, got: %v", err)
	}
}

func TestGetUser_ConstructsPath(t *testing.T) {
	userID := "abc-123"
	respUser := `[{"id":"abc-123","username":"bob"}]`
	respLedger := `[]`
	respMembers := `[]`

	var calls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		calls++
		switch {
		case strings.Contains(r.URL.Path, "users"):
			w.Write([]byte(respUser))
		case strings.Contains(r.URL.Path, "shard_ledger"):
			w.Write([]byte(respLedger))
		case strings.Contains(r.URL.Path, "group_members"):
			w.Write([]byte(respMembers))
		}
	}))
	defer srv.Close()
	client := &db.DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}

	result, err := GetUser(client, userID)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.User.ID != "abc-123" {
		t.Errorf("expected id abc-123, got %s", result.User.ID)
	}
	if calls < 3 {
		t.Errorf("expected at least 3 requests (users, ledger, members), got %d", calls)
	}
}

func TestGetUser_NotFound(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`[]`, 200)
	defer srv.Close()

	_, err := GetUser(client, "nonexistent")

	if err == nil || !strings.Contains(err.Error(), "not found") {
		t.Errorf("expected 'not found' error, got: %v", err)
	}
}

func TestBanUser_CallsUpdate(t *testing.T) {
	client, srv, log := newTestClientWithLog(`{}`, 200)
	defer srv.Close()

	err := BanUser(client, "u1", "spam", "admin1")

	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	foundUpdate := false
	for _, req := range *log {
		if req.Method == "PATCH" && strings.Contains(req.Path, "users") {
			foundUpdate = true
			assertContains(t, req.Path, "id=eq.u1")
		}
	}
	if !foundUpdate {
		t.Error("expected PATCH request on users")
	}
}

func TestUnbanUser_ClearsBanFields(t *testing.T) {
	client, srv, log := newTestClientWithLog(`{}`, 200)
	defer srv.Close()

	err := UnbanUser(client, "u1", "admin1")

	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	foundUpdate := false
	for _, req := range *log {
		if req.Method == "PATCH" && strings.Contains(req.Path, "users") {
			foundUpdate = true
		}
	}
	if !foundUpdate {
		t.Error("expected PATCH request on users for unban")
	}
}

func TestGrantShards_CallsRPC(t *testing.T) {
	client, srv, log := newTestClientWithLog(`{}`, 200)
	defer srv.Close()

	err := GrantShards(client, "u1", 500, "bonus", "admin1")

	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	foundRPC := false
	for _, req := range *log {
		if req.Method == "POST" && strings.Contains(req.Path, "grant_shards") {
			foundRPC = true
		}
	}
	if !foundRPC {
		t.Error("expected RPC call to grant_shards")
	}
}

func TestGrantPreshards_CallsRPC(t *testing.T) {
	client, srv, log := newTestClientWithLog(`{}`, 200)
	defer srv.Close()

	err := GrantPreshards(client, "u1", 300, "admin_grant", "admin1")

	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	foundRPC := false
	for _, req := range *log {
		if req.Method == "POST" && strings.Contains(req.Path, "grant_preshards") {
			foundRPC = true
		}
	}
	if !foundRPC {
		t.Error("expected RPC call to grant_preshards")
	}
}

func TestSoftDeleteUser_AnonymizesAndLogs(t *testing.T) {
	client, srv, log := newTestClientWithLog(`{}`, 200)
	defer srv.Close()

	err := SoftDeleteUser(client, "user-12345678", "admin1")

	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	foundUpdate := false
	foundAudit := false
	for _, req := range *log {
		if req.Method == "PATCH" && strings.Contains(req.Path, "users") {
			foundUpdate = true
		}
		if req.Method == "POST" && strings.Contains(req.Path, "admin_audit_log") {
			foundAudit = true
		}
	}
	if !foundUpdate {
		t.Error("expected PATCH request on users for soft delete")
	}
	if !foundAudit {
		t.Error("expected audit log entry for soft delete")
	}
}

func TestListUsers_JSONRoundTrip(t *testing.T) {
	username := "testuser"
	user := db.User{
		ID:                "uuid-1",
		Username:          &username,
		SubscriptionTier:  "pro",
		PersonalShards:    256,
		Preshards:         1000,
	}
	resp, _ := json.Marshal([]db.User{user})
	client, srv, _ := newTestClientWithLog(string(resp), 200)
	defer srv.Close()

	users, err := ListUsers(client, ListUsersParams{})

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if users[0].Username == nil || *users[0].Username != "testuser" {
		t.Errorf("expected testuser, got %v", users[0].Username)
	}
	if users[0].SubscriptionTier != "pro" {
		t.Errorf("expected pro, got %s", users[0].SubscriptionTier)
	}
}
