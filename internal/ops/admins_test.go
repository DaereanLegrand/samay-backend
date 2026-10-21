package ops

import (
	"context"
	"errors"
	"testing"
)

func TestGetAdmin_Found(t *testing.T) {
	client, srv, log := newTestClientWithLog(`[{"id":"00000000-0000-4000-8000-000000000001","email":"admin@example.com","display_name":"Admin","role":"super_admin","created_at":"2026-01-01T00:00:00Z"}]`, 200)
	defer srv.Close()

	admin, err := GetAdmin(context.Background(), client, "00000000-0000-4000-8000-000000000001")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if admin.ID != "00000000-0000-4000-8000-000000000001" || admin.Role != "super_admin" {
		t.Errorf("unexpected admin: %+v", admin)
	}
	if len(*log) != 1 || (*log)[0].Path != "/rest/v1/admin_users?select=id,email,display_name,role,created_at&id=eq.00000000-0000-4000-8000-000000000001&limit=1" {
		t.Errorf("unexpected request: %+v", *log)
	}
}

func TestGetAdmin_NotFound(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`[]`, 200)
	defer srv.Close()

	_, err := GetAdmin(context.Background(), client, "00000000-0000-4000-8000-000000000002")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestGetAdmin_RejectsNonUUID(t *testing.T) {
	client, srv, log := newTestClientWithLog(`[]`, 200)
	defer srv.Close()

	if _, err := GetAdmin(context.Background(), client, "not-a-uuid'&or=1"); err == nil {
		t.Fatal("expected invalid id to be rejected")
	}
	if len(*log) != 0 {
		t.Fatalf("invalid id must not reach the DB: %+v", *log)
	}
}
