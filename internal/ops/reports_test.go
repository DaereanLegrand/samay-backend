package ops

import (
	"context"
	"strings"
	"testing"
)

func TestListReports_PathConstruction(t *testing.T) {
	baseSelect := "select=id,reporter_id,target_type,target_id,reason,status,created_at"

	tests := []struct {
		name    string
		params  ListReportsParams
		want    []string
		notWant []string
	}{
		{
			name:   "no filters",
			params: ListReportsParams{},
			want:   []string{"/rest/v1/reports", baseSelect, "limit=100"},
		},
		{
			name:    "status filter",
			params:  ListReportsParams{Status: "pending"},
			want:    []string{"status=eq.pending"},
			notWant: []string{"target_type=eq."},
		},
		{
			name:    "target type filter",
			params:  ListReportsParams{Type: "message"},
			want:    []string{"target_type=eq.message"},
			notWant: []string{"status=eq."},
		},
		{
			name:   "both filters",
			params: ListReportsParams{Status: "actioned", Type: "photo"},
			want:   []string{"status=eq.actioned", "target_type=eq.photo"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client, srv, log := newTestClientWithLog(`[]`, 200)
			defer srv.Close()

			_, err := ListReports(context.Background(), client, tt.params)
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

func TestListReports_ParsesResponse(t *testing.T) {
	resp := `[{"id":"r1","reporter_id":"u1","target_type":"message","reason":"spam","status":"pending"}]`
	client, srv, _ := newTestClientWithLog(resp, 200)
	defer srv.Close()

	reports, err := ListReports(context.Background(), client, ListReportsParams{})

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(reports) != 1 || reports[0].ID != "r1" || reports[0].Status != "pending" {
		t.Errorf("unexpected reports parsed: %+v", reports)
	}
}

func TestListReports_UnmarshalError(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`not json`, 200)
	defer srv.Close()

	_, err := ListReports(context.Background(), client, ListReportsParams{})

	if err == nil || !strings.Contains(err.Error(), "unmarshal") {
		t.Errorf("expected unmarshal error, got: %v", err)
	}
}

func TestGetReport_PathAndParse(t *testing.T) {
	resp := `[{"id":"r1","reporter_id":"u1","target_type":"user","target_id":"u2","reason":"abuse","status":"reviewed"}]`
	client, srv, log := newTestClientWithLog(resp, 200)
	defer srv.Close()

	report, err := GetReport(context.Background(), client, "r1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if report.ID != "r1" || report.TargetType != "user" {
		t.Errorf("unexpected report: %+v", report)
	}
	assertContains(t, (*log)[0].Path, "/rest/v1/reports")
	assertContains(t, (*log)[0].Path, "id=eq.r1")
	assertContains(t, (*log)[0].Path, "limit=1")
}

func TestGetReport_NotFound(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`[]`, 200)
	defer srv.Close()

	_, err := GetReport(context.Background(), client, "missing")

	if err == nil || !strings.Contains(err.Error(), "not found") {
		t.Errorf("expected 'not found' error, got: %v", err)
	}
}

func TestActionReport_CallsModerateRPC(t *testing.T) {
	for _, action := range []string{"remove", "dismiss", "warn"} {
		t.Run(action, func(t *testing.T) {
			client, srv, log := newTestClientWithLog(`{"status":"ok"}`, 200)
			defer srv.Close()

			err := ActionReport(context.Background(), client, "r1", action, "admin-1")
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got := countRequests(log, "POST", "/rest/v1/rpc/moderate_report"); got != 1 {
				t.Fatalf("expected 1 moderate_report RPC, got %d", got)
			}
			req := lastRequest(log)
			assertContains(t, req.Path, "/rest/v1/rpc/moderate_report")
			assertContains(t, req.Body, `"p_report_id":"r1"`)
			assertContains(t, req.Body, `"p_action":"`+action+`"`)
			assertContains(t, req.Body, `"p_admin_user_id":"admin-1"`)
		})
	}
}

func TestActionReport_InvalidAction(t *testing.T) {
	client, srv, log := newTestClientWithLog(`{}`, 200)
	defer srv.Close()

	err := ActionReport(context.Background(), client, "r1", "explode", "admin-1")

	if err == nil || !strings.Contains(err.Error(), "invalid action") {
		t.Errorf("expected invalid action error, got: %v", err)
	}
	if len(*log) != 0 {
		t.Errorf("expected no requests for invalid action, got %d", len(*log))
	}
}

func TestActionReport_RPCErrorPropagates(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`{"message":"db down"}`, 500)
	defer srv.Close()

	err := ActionReport(context.Background(), client, "r1", "warn", "admin-1")

	if err == nil || !strings.Contains(err.Error(), "500") {
		t.Errorf("expected 500 error, got: %v", err)
	}
}
