package main

import (
	"net/http"
	"strings"
	"testing"

	"github.com/samay-app/samay/internal/ops"
)

func TestSystemHealthPropagatesDBError(t *testing.T) {
	setupTestEnv(t)
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
		w.Write([]byte(`{"message":"db down"}`))
	})
	rootCmd.SetArgs([]string{"system", "health"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil {
		t.Fatal("expected error when the health DB query fails")
	}
	if !strings.Contains(err.Error(), "health check") {
		t.Errorf("expected health-check error, got: %v", err)
	}
}

func TestSystemHealthOK(t *testing.T) {
	setupTestEnv(t)
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`[{"key":"app.name"}]`))
	})
	rootCmd.SetArgs([]string{"system", "health"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "db_connected") {
		t.Errorf("expected health table, got: %q", out)
	}
}

func TestStatsTableBuilder_AllMetrics(t *testing.T) {
	stats := &ops.SystemStats{
		RegisteredUsers:        10,
		UsersLast7Days:         3,
		UsersLast30Days:        6,
		ActiveUsers7Days:       2,
		PendingReportsCount:    1,
		PendingFeatureRequests: 2,
	}

	headers, rows := statsTableBuilder(stats)

	if len(headers) != 2 || headers[0] != "METRIC" || headers[1] != "VALUE" {
		t.Fatalf("unexpected headers: %v", headers)
	}
	if len(rows) != 6 {
		t.Fatalf("expected 6 rows, got %d: %v", len(rows), rows)
	}
	expect := map[string]string{
		"registered_users":         "10",
		"users_last_7_days":        "3",
		"users_last_30_days":       "6",
		"active_users_7_days":      "2",
		"pending_reports_count":    "1",
		"pending_feature_requests": "2",
	}
	for _, row := range rows {
		want, ok := expect[row[0]]
		if !ok {
			t.Errorf("unexpected row %q", row[0])
			continue
		}
		if row[1] != want {
			t.Errorf("%s = %q, want %q", row[0], row[1], want)
		}
	}
}

func TestSystemStatsJSONOutput(t *testing.T) {
	setupTestEnv(t)
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.Contains(r.URL.Path, "users"):
			w.Write([]byte(`[{"created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-08T00:00:00Z","personal_shards":10,"preshards":2}]`))
		case strings.Contains(r.URL.Path, "reports"):
			w.Write([]byte(`[{"id":"r1","status":"pending"}]`))
		case strings.Contains(r.URL.Path, "feature_requests"):
			w.Write([]byte(`[]`))
		default:
			w.Write([]byte(`[]`))
		}
	})
	rootCmd.SetArgs([]string{"system", "stats", "--json"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, want := range []string{
		"registered_users", "users_last_30_days", "pending_reports_count",
		"pending_feature_requests",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in JSON output, got:\n%s", want, out)
		}
	}
}
