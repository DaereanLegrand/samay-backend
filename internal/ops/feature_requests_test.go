package ops

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestListFeatureRequests_PathConstruction(t *testing.T) {
	baseSelect := "select=id,event_id,requested_by_user_id,contact_info,desired_duration_days,status,created_at"

	tests := []struct {
		name    string
		params  ListFeatureRequestsParams
		want    []string
		notWant []string
	}{
		{
			name:   "no filters",
			params: ListFeatureRequestsParams{},
			want:   []string{"/rest/v1/feature_requests", baseSelect, "limit=100"},
		},
		{
			name:   "status filter",
			params: ListFeatureRequestsParams{Status: "pending"},
			want:   []string{"status=eq.pending"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client, srv, log := newTestClientWithLog(`[]`, 200)
			defer srv.Close()

			_, err := ListFeatureRequests(context.Background(), client, tt.params)
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

func TestListFeatureRequests_ParsesResponse(t *testing.T) {
	resp := `[{"id":"f1","event_id":"e1","requested_by_user_id":"u1","desired_duration_days":3,"status":"pending"}]`
	client, srv, _ := newTestClientWithLog(resp, 200)
	defer srv.Close()

	requests, err := ListFeatureRequests(context.Background(), client, ListFeatureRequestsParams{})

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(requests) != 1 || requests[0].ID != "f1" || requests[0].Status != "pending" {
		t.Errorf("unexpected requests parsed: %+v", requests)
	}
}

func TestListFeatureRequests_UnmarshalError(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`not json`, 200)
	defer srv.Close()

	_, err := ListFeatureRequests(context.Background(), client, ListFeatureRequestsParams{})

	if err == nil || !strings.Contains(err.Error(), "unmarshal") {
		t.Errorf("expected unmarshal error, got: %v", err)
	}
}

func TestApproveFeatureRequest_PatchesAndAudits(t *testing.T) {
	featuredUntil := time.Date(2026, 8, 15, 0, 0, 0, 0, time.UTC)
	client, srv, log := newTestClientWithLog(`{}`, 200)
	defer srv.Close()

	err := ApproveFeatureRequest(context.Background(), client, "f1", featuredUntil, "admin-1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := countRequests(log, "PATCH", "/rest/v1/feature_requests"); got != 1 {
		t.Fatalf("expected 1 PATCH on feature_requests, got %d", got)
	}
	patch := firstRequestOf(log, "PATCH", "/rest/v1/feature_requests")
	assertContains(t, patch.Path, "id=eq.f1")
	assertContains(t, patch.Body, `"status":"approved"`)
	assertContains(t, patch.Body, `"featured_until":"2026-08-15T00:00:00Z"`)

	audit := lastRequest(log)
	assertContains(t, audit.Path, "/rest/v1/admin_audit_log")
	assertContains(t, audit.Body, `"action":"approve_feature_request"`)
	assertContains(t, audit.Body, `"target_type":"feature_request"`)
	assertContains(t, audit.Body, `"target_id":"f1"`)
	assertContains(t, audit.Body, `"featured_until":"2026-08-15T00:00:00Z"`)
}

func TestApproveFeatureRequest_UpdateErrorPropagates(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`{"message":"boom"}`, 500)
	defer srv.Close()

	err := ApproveFeatureRequest(context.Background(), client, "f1", time.Now(), "admin-1")

	if err == nil || !strings.Contains(err.Error(), "500") {
		t.Errorf("expected 500 error, got: %v", err)
	}
}

func TestRejectFeatureRequest_PatchesAndAudits(t *testing.T) {
	client, srv, log := newTestClientWithLog(`{}`, 200)
	defer srv.Close()

	err := RejectFeatureRequest(context.Background(), client, "f1", "admin-1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := countRequests(log, "PATCH", "/rest/v1/feature_requests"); got != 1 {
		t.Fatalf("expected 1 PATCH on feature_requests, got %d", got)
	}
	patch := firstRequestOf(log, "PATCH", "/rest/v1/feature_requests")
	assertContains(t, patch.Path, "id=eq.f1")
	assertContains(t, patch.Body, `"status":"rejected"`)

	audit := lastRequest(log)
	assertContains(t, audit.Path, "/rest/v1/admin_audit_log")
	assertContains(t, audit.Body, `"action":"reject_feature_request"`)
	assertContains(t, audit.Body, `"target_id":"f1"`)
}
