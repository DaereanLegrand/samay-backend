package ops

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/samay-app/samay/internal/db"
)

func TestGetSystemStats_QueriesUsers(t *testing.T) {
	usersResp := `[{"id":"u1"}]`
	var usersCalled bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.Contains(r.URL.Path, "users") {
			usersCalled = true
			w.Write([]byte(usersResp))
		} else {
			w.Write([]byte(`[]`))
		}
	}))
	defer srv.Close()
	client := &db.DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}

	stats, err := GetSystemStats(context.Background(), client)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !usersCalled {
		t.Error("expected users table query")
	}
	if stats.RegisteredUsers != 1 {
		t.Errorf("expected 1 registered user, got %d", stats.RegisteredUsers)
	}
}

// The events surface is removed in slim-prod: stats must not read it.
func TestGetSystemStats_DoesNotQueryEvents(t *testing.T) {
	var eventsCalled bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.Contains(r.URL.Path, "events") {
			eventsCalled = true
		}
		w.Write([]byte(`[]`))
	}))
	defer srv.Close()
	client := &db.DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}

	if _, err := GetSystemStats(context.Background(), client); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if eventsCalled {
		t.Error("stats queried the removed events table")
	}
}

type statRow map[string]any

type statsFixture struct {
	users    []statRow
	reports  []statRow
	requests []statRow
}

func serveStatRows(w http.ResponseWriter, r *http.Request, rows []statRow, keep func(statRow) bool) {
	filtered := rows
	if keep != nil {
		filtered = nil
		for _, row := range rows {
			if keep(row) {
				filtered = append(filtered, row)
			}
		}
	}
	q := r.URL.Query()
	offset := 0
	if v := q.Get("offset"); v != "" {
		offset, _ = strconv.Atoi(v)
	}
	limit := len(filtered)
	if v := q.Get("limit"); v != "" {
		limit, _ = strconv.Atoi(v)
	}
	if offset > len(filtered) {
		offset = len(filtered)
	}
	end := offset + limit
	if end > len(filtered) {
		end = len(filtered)
	}
	body, _ := json.Marshal(filtered[offset:end])
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

func newStatsServer(fx statsFixture) (*httptest.Server, *[]requestLog) {
	log := &[]requestLog{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*log = append(*log, requestLog{Method: r.Method, Path: r.URL.RequestURI()})
		switch {
		case strings.Contains(r.URL.Path, "users"):
			serveStatRows(w, r, fx.users, nil)
		case strings.Contains(r.URL.Path, "reports"):
			serveStatRows(w, r, fx.reports, func(row statRow) bool {
				return row["status"] == "pending"
			})
		case strings.Contains(r.URL.Path, "feature_requests"):
			serveStatRows(w, r, fx.requests, func(row statRow) bool {
				return row["status"] == "pending"
			})
		default:
			w.Write([]byte(`[]`))
		}
	}))
	return srv, log
}

func TestGetSystemStats_Metrics(t *testing.T) {
	now := time.Now().UTC()
	at := func(days int) string {
		return now.AddDate(0, 0, -days).Format(time.RFC3339)
	}
	fx := statsFixture{
		users: []statRow{
			{"created_at": at(1), "updated_at": at(1)},
			{"created_at": at(20), "updated_at": at(1)},
			{"created_at": at(45), "updated_at": at(45)},
		},
		reports: []statRow{
			{"id": "r1", "status": "pending"},
			{"id": "r2", "status": "reviewed"},
		},
		requests: []statRow{
			{"id": "f1", "status": "pending"},
			{"id": "f2", "status": "approved"},
		},
	}
	srv, log := newStatsServer(fx)
	defer srv.Close()
	client := &db.DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}

	stats, err := GetSystemStats(context.Background(), client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	intCases := []struct {
		name string
		got  int
		want int
	}{
		{"registered_users", stats.RegisteredUsers, 3},
		{"users_last_7_days", stats.UsersLast7Days, 1},
		{"users_last_30_days", stats.UsersLast30Days, 2},
		{"active_users_7_days", stats.ActiveUsers7Days, 2},
		{"pending_reports_count", stats.PendingReportsCount, 1},
		{"pending_feature_requests", stats.PendingFeatureRequests, 1},
	}
	for _, tc := range intCases {
		t.Run(tc.name, func(t *testing.T) {
			if tc.got != tc.want {
				t.Errorf("%s = %d, want %d", tc.name, tc.got, tc.want)
			}
		})
	}

	t.Run("query_shape", func(t *testing.T) {
		var all []string
		for _, r := range *log {
			all = append(all, r.Path)
		}
		joined := strings.Join(all, "\n")
		checks := []struct {
			table, want string
		}{
			{"users", "created_at"},
			{"users", "updated_at"},
			{"reports", "status=eq.pending"},
			{"feature_requests", "status=eq.pending"},
		}
		for _, c := range checks {
			if !strings.Contains(joined, c.want) {
				t.Errorf("expected a %s query containing %q, got:\n%s", c.table, c.want, joined)
			}
		}
		// Removed domains must not be scanned any more.
		for _, gone := range []string{"events", "shard_ledger"} {
			if strings.Contains(joined, "/"+gone) {
				t.Errorf("stats still query the removed %s table:\n%s", gone, joined)
			}
		}
	})
}

func TestGetSystemStats_PaginatesLargeTables(t *testing.T) {
	now := time.Now().UTC().Format(time.RFC3339)
	users := make([]statRow, 1001)
	for i := range users {
		users[i] = statRow{"created_at": now, "updated_at": now}
	}
	srv, log := newStatsServer(statsFixture{users: users})
	defer srv.Close()
	client := &db.DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}

	stats, err := GetSystemStats(context.Background(), client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if stats.RegisteredUsers != 1001 {
		t.Errorf("registered_users = %d, want 1001", stats.RegisteredUsers)
	}
	if stats.UsersLast7Days != 1001 {
		t.Errorf("users_last_7_days = %d, want 1001", stats.UsersLast7Days)
	}

	var usersRequests int
	var offsets []string
	for _, r := range *log {
		if !strings.Contains(r.Path, "users") {
			continue
		}
		usersRequests++
		u, err := url.Parse(r.Path)
		if err != nil {
			t.Fatalf("parse request uri: %v", err)
		}
		if o := u.Query().Get("offset"); o != "" {
			offsets = append(offsets, o)
		}
	}
	if usersRequests != 2 {
		t.Errorf("expected 2 users requests, got %d", usersRequests)
	}
	if fmt.Sprint(offsets) != "[1000]" {
		t.Errorf("expected pagination offset 1000 on the second page, got %v", offsets)
	}
}

func TestGetSystemStats_ReturnsErrorOnQueryFailure(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`oops`, 500)
	defer srv.Close()

	_, err := GetSystemStats(context.Background(), client)

	if err == nil {
		t.Error("expected error when a stats query fails")
	}
}

func TestHealthCheck_ReturnsOk(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`[{"key":"app.name"}]`, 200)
	defer srv.Close()

	health, err := HealthCheck(context.Background(), client)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if health.Status != "ok" {
		t.Errorf("expected ok, got %s", health.Status)
	}
	if health.DBConnected != true {
		t.Errorf("expected DBConnected=true, got %v", health.DBConnected)
	}
}

func TestHealthCheck_ReturnsErrorOnFailure(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`error`, 500)
	defer srv.Close()

	health, err := HealthCheck(context.Background(), client)

	if err == nil {
		t.Fatal("HealthCheck must return an error when the DB query fails")
	}
	if health.Status != "degraded" {
		t.Errorf("expected degraded, got %s", health.Status)
	}
	if health.DBConnected != false {
		t.Errorf("expected DBConnected=false, got %v", health.DBConnected)
	}
	if health.APILatency == "" {
		t.Error("expected APILatency to be set")
	}
}

func TestCheckHTTP_ValidURL(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()

	err := CheckHTTP(srv.URL)

	if err != nil {
		t.Errorf("expected no error for valid URL, got: %v", err)
	}
}

func TestCheckHTTP_404URL(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(404)
	}))
	defer srv.Close()

	err := CheckHTTP(srv.URL)

	if err == nil {
		t.Error("expected error for 404")
	}
}

func TestCheckHTTP_Unreachable(t *testing.T) {
	err := CheckHTTP("http://127.0.0.1:1")

	if err == nil {
		t.Error("expected error for unreachable URL")
	}
}
