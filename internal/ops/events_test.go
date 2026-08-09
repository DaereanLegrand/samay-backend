package ops

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestListEvents_PathConstruction(t *testing.T) {
	baseSelect := "select=id,name,type,status,starts_at,ends_at,created_by_user_id,preshards_pool,featured"

	tests := []struct {
		name    string
		params  ListEventsParams
		want    []string
		notWant []string
	}{
		{
			name:   "no filters",
			params: ListEventsParams{},
			want:   []string{"/rest/v1/events", baseSelect, "limit=100"},
		},
		{
			name:    "status filter",
			params:  ListEventsParams{Status: "upcoming"},
			want:    []string{"status=eq.upcoming"},
			notWant: []string{"type=eq.", "created_by_user_id=eq."},
		},
		{
			name:    "type filter",
			params:  ListEventsParams{Type: "juerga"},
			want:    []string{"type=eq.juerga"},
			notWant: []string{"status=eq.", "created_by_user_id=eq."},
		},
		{
			name:    "promotor filter",
			params:  ListEventsParams{Promotor: "user-1"},
			want:    []string{"created_by_user_id=eq.user-1"},
			notWant: []string{"status=eq.", "type=eq."},
		},
		{
			name:   "all filters",
			params: ListEventsParams{Status: "live", Type: "tono", Promotor: "user-2"},
			want:   []string{"status=eq.live", "type=eq.tono", "created_by_user_id=eq.user-2"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client, srv, log := newTestClientWithLog(`[]`, 200)
			defer srv.Close()

			_, err := ListEvents(context.Background(), client, tt.params)
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

func TestListEvents_ParsesResponse(t *testing.T) {
	resp := `[{"id":"e1","name":"Juerga","type":"juerga","status":"upcoming"},{"id":"e2","name":"Tono","type":"tono","status":"live"}]`
	client, srv, _ := newTestClientWithLog(resp, 200)
	defer srv.Close()

	events, err := ListEvents(context.Background(), client, ListEventsParams{})

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(events) != 2 {
		t.Fatalf("expected 2 events, got %d", len(events))
	}
	if events[0].ID != "e1" || events[1].Status != "live" {
		t.Errorf("unexpected events parsed: %+v", events)
	}
}

func TestListEvents_UnmarshalError(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`not json`, 200)
	defer srv.Close()

	_, err := ListEvents(context.Background(), client, ListEventsParams{})

	if err == nil || !strings.Contains(err.Error(), "unmarshal") {
		t.Errorf("expected unmarshal error, got: %v", err)
	}
}

func TestListEvents_PropagatesRequestError(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`{"message":"boom"}`, 500)
	defer srv.Close()

	_, err := ListEvents(context.Background(), client, ListEventsParams{})

	if err == nil || !strings.Contains(err.Error(), "500") {
		t.Errorf("expected 500 error, got: %v", err)
	}
}

func TestGetEvent_PrimaryAndSecondarySelects(t *testing.T) {
	client, srv, log := newRoutingClient(map[string]string{
		"/rest/v1/events":            `[{"id":"e1","name":"Juerga","status":"upcoming"}]`,
		"/rest/v1/event_promotores":  `[{"id":"p1","event_id":"e1","user_id":"u1","role":"main","preshards_contributed":50}]`,
		"/rest/v1/event_attendances": `[]`,
	})
	defer srv.Close()

	detail, err := GetEvent(context.Background(), client, "e1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if detail.Event.ID != "e1" || detail.Event.Name != "Juerga" {
		t.Errorf("unexpected event: %+v", detail.Event)
	}
	if len(detail.Promotores) != 1 || detail.Promotores[0].PreshardsContributed != 50 {
		t.Errorf("unexpected promotores: %+v", detail.Promotores)
	}

	if got := countRequests(log, "GET", "/rest/v1/events"); got != 1 {
		t.Errorf("expected 1 primary events select, got %d", got)
	}
	if got := countRequests(log, "GET", "/rest/v1/event_promotores"); got != 1 {
		t.Errorf("expected 1 promotores select, got %d", got)
	}
	for _, want := range []string{"id=eq.e1", "limit=1"} {
		assertContains(t, firstRequestOf(log, "GET", "/rest/v1/events").Path, want)
	}
	assertContains(t, firstRequestOf(log, "GET", "/rest/v1/event_promotores").Path, "event_id=eq.e1")
}

func TestGetEvent_NotFound(t *testing.T) {
	client, srv, _ := newRoutingClient(map[string]string{
		"/rest/v1/events":           `[]`,
		"/rest/v1/event_promotores": `[]`,
	})
	defer srv.Close()

	_, err := GetEvent(context.Background(), client, "missing")

	if err == nil || !strings.Contains(err.Error(), "not found") {
		t.Errorf("expected 'not found' error, got: %v", err)
	}
}

func TestFeatureEvent_UpdatesAndAudits(t *testing.T) {
	expires := time.Date(2026, 8, 10, 0, 0, 0, 0, time.UTC)
	client, srv, log := newTestClientWithLog(`{}`, 200)
	defer srv.Close()

	err := FeatureEvent(context.Background(), client, "e1", expires, "admin-1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := countRequests(log, "PATCH", "/rest/v1/events"); got != 1 {
		t.Errorf("expected 1 PATCH on events, got %d", got)
	}
	evPatch := firstRequestOf(log, "PATCH", "/rest/v1/events")
	assertContains(t, evPatch.Path, "id=eq.e1")
	assertContains(t, evPatch.Body, `"featured":true`)
	assertContains(t, evPatch.Body, `"featured_until":"2026-08-10T00:00:00Z"`)

	if got := countRequests(log, "PATCH", "/rest/v1/feature_requests"); got != 1 {
		t.Errorf("expected 1 PATCH on feature_requests, got %d", got)
	}
	frPatch := firstRequestOf(log, "PATCH", "/rest/v1/feature_requests")
	assertContains(t, frPatch.Path, "event_id=eq.e1")
	assertContains(t, frPatch.Path, "status=eq.pending")
	assertContains(t, frPatch.Body, `"status":"approved"`)

	if got := countRequests(log, "POST", "/rest/v1/admin_audit_log"); got != 1 {
		t.Errorf("expected 1 audit insert, got %d", got)
	}
	audit := firstRequestOf(log, "POST", "/rest/v1/admin_audit_log")
	assertContains(t, audit.Body, `"admin_user_id":"admin-1"`)
	assertContains(t, audit.Body, `"action":"feature_event"`)
	assertContains(t, audit.Body, `"target_type":"event"`)
	assertContains(t, audit.Body, `"target_id":"e1"`)
	assertContains(t, audit.Body, `"expires_at":"2026-08-10T00:00:00Z"`)
}

func TestUnfeatureEvent_ClearsAndAudits(t *testing.T) {
	client, srv, log := newTestClientWithLog(`{}`, 200)
	defer srv.Close()

	err := UnfeatureEvent(context.Background(), client, "e1", "admin-1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := countRequests(log, "PATCH", "/rest/v1/events"); got != 1 {
		t.Errorf("expected 1 PATCH on events, got %d", got)
	}
	patch := firstRequestOf(log, "PATCH", "/rest/v1/events")
	assertContains(t, patch.Path, "id=eq.e1")
	assertContains(t, patch.Body, `"featured":false`)
	assertContains(t, patch.Body, `"featured_until":null`)
	assertContains(t, lastRequest(log).Body, `"action":"unfeature_event"`)
}

func TestRejectFeatureEvent_RejectsAndAudits(t *testing.T) {
	client, srv, log := newTestClientWithLog(`{}`, 200)
	defer srv.Close()

	err := RejectFeatureEvent(context.Background(), client, "e1", "admin-1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := countRequests(log, "PATCH", "/rest/v1/feature_requests"); got != 1 {
		t.Errorf("expected 1 PATCH on feature_requests, got %d", got)
	}
	patch := firstRequestOf(log, "PATCH", "/rest/v1/feature_requests")
	assertContains(t, patch.Path, "event_id=eq.e1")
	assertContains(t, patch.Path, "status=eq.pending")
	assertContains(t, patch.Body, `"status":"rejected"`)
	assertContains(t, lastRequest(log).Body, `"action":"reject_feature"`)
}

func TestCancelEvent_AlreadyCancelledIsIdempotent(t *testing.T) {
	client, srv, log := newRoutingClient(map[string]string{
		"/rest/v1/events": `[{"id":"e1","status":"cancelled","preshards_pool":100}]`,
	})
	defer srv.Close()

	err := CancelEvent(context.Background(), client, "e1", "double cancel", "admin-1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(*log) != 1 {
		t.Errorf("expected only the status read, got %d requests", len(*log))
	}
}

func TestCancelEvent_ReturnsPoolAndAudits(t *testing.T) {
	client, srv, log := newRoutingClient(map[string]string{
		"/rest/v1/events":           `[{"id":"e1","status":"upcoming","preshards_pool":100}]`,
		"/rest/v1/event_promotores": `[{"id":"p1","event_id":"e1","user_id":"u1","preshards_contributed":25},{"id":"p2","event_id":"e1","user_id":"u2","preshards_contributed":0}]`,
		"/rest/v1/preshard_ledger":  `{}`,
		"/rest/v1/admin_audit_log":  `{}`,
	})
	defer srv.Close()

	err := CancelEvent(context.Background(), client, "e1", "no venue", "admin-1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := countRequests(log, "GET", "/rest/v1/events"); got != 1 {
		t.Errorf("expected 1 status read, got %d", got)
	}
	if got := countRequests(log, "GET", "/rest/v1/event_promotores"); got != 1 {
		t.Errorf("expected 1 pool read, got %d", got)
	}
	if got := countRequests(log, "POST", "/rest/v1/preshard_ledger"); got != 1 {
		t.Fatalf("expected exactly 1 ledger insert (only u1 contributed), got %d", got)
	}
	ledger := firstRequestOf(log, "POST", "/rest/v1/preshard_ledger")
	assertContains(t, ledger.Body, `"user_id":"u1"`)
	assertContains(t, ledger.Body, `"delta":25`)
	assertContains(t, ledger.Body, `"reason":"event_pool_returned"`)
	assertContains(t, ledger.Body, `"reference_id":"e1"`)

	statusPatch := firstRequestOf(log, "PATCH", "/rest/v1/events")
	assertContains(t, statusPatch.Path, "id=eq.e1")
	assertContains(t, statusPatch.Body, `"status":"cancelled"`)
	assertContains(t, statusPatch.Body, `"preshards_pool":0`)
	assertContains(t, statusPatch.Body, `"preshards_distributed":true`)

	audit := firstRequestOf(log, "POST", "/rest/v1/admin_audit_log")
	assertContains(t, audit.Body, `"action":"cancel_event"`)
	assertContains(t, audit.Body, `"reason":"no venue"`)
	assertContains(t, audit.Body, `"preshard_returned":true`)
}

func TestCancelEvent_NotFound(t *testing.T) {
	client, srv, _ := newRoutingClient(map[string]string{
		"/rest/v1/events": `[]`,
	})
	defer srv.Close()

	err := CancelEvent(context.Background(), client, "missing", "nope", "admin-1")

	if err == nil || !strings.Contains(err.Error(), "not found") {
		t.Errorf("expected 'not found' error, got: %v", err)
	}
}

func TestCancelEvent_SelectErrorPropagates(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`{"message":"db down"}`, 500)
	defer srv.Close()

	err := CancelEvent(context.Background(), client, "e1", "nope", "admin-1")

	if err == nil || !strings.Contains(err.Error(), "500") {
		t.Errorf("expected 500 error, got: %v", err)
	}
}

func TestDistributeShards_CallsRPCAndAudits(t *testing.T) {
	client, srv, log := newTestClientWithLog(`{"status":"ok","distributed":3}`, 200)
	defer srv.Close()

	err := DistributeShards(context.Background(), client, "e1", "admin-1")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := countRequests(log, "POST", "/rest/v1/rpc/distribute_shards"); got != 1 {
		t.Errorf("expected 1 RPC call, got %d", got)
	}
	rpc := firstRequestOf(log, "POST", "/rest/v1/rpc/distribute_shards")
	assertContains(t, rpc.Body, `"p_event_id":"e1"`)

	audit := lastRequest(log)
	assertContains(t, audit.Path, "/rest/v1/admin_audit_log")
	assertContains(t, audit.Body, `"action":"distribute_shards"`)
	assertContains(t, audit.Body, `"status":"ok"`)
	assertContains(t, audit.Body, `"distributed":3`)
}

func TestDistributeShards_RPCErrorPropagates(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`{"message":"rpc failed"}`, 500)
	defer srv.Close()

	err := DistributeShards(context.Background(), client, "e1", "admin-1")

	if err == nil || !strings.Contains(err.Error(), "distribute shards") {
		t.Errorf("expected RPC failure to propagate, got: %v", err)
	}
}

func firstRequestOf(log *[]requestLog, method, pathSubstr string) requestLog {
	for _, r := range *log {
		if r.Method == method && strings.Contains(r.Path, pathSubstr) {
			return r
		}
	}
	return requestLog{}
}
