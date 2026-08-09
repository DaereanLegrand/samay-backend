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
		TotalEvents:            5,
		EventsByStatus:         map[string]int{"draft": 3, "live": 2},
		EventsByType:           map[string]int{"casual": 5},
		ShardsInCirculation:    100,
		PreshardsInCirculation: 20,
		TotalShardsDistributed: 500,
		PendingReportsCount:    1,
		PendingFeatureRequests: 2,
	}

	headers, rows := statsTableBuilder(stats)

	if len(headers) != 2 || headers[0] != "METRIC" || headers[1] != "VALUE" {
		t.Fatalf("unexpected headers: %v", headers)
	}
	if len(rows) != 12 {
		t.Fatalf("expected 12 rows, got %d: %v", len(rows), rows)
	}
	expect := map[string]string{
		"registered_users":         "10",
		"users_last_7_days":        "3",
		"users_last_30_days":       "6",
		"active_users_7_days":      "2",
		"total_events":             "5",
		"events_by_status":         "draft: 3, live: 2",
		"events_by_type":           "casual: 5",
		"shards_in_circulation":    "100",
		"preshards_in_circulation": "20",
		"total_shards_distributed": "500",
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

func TestStatsTableBuilder_EmptyMaps(t *testing.T) {
	stats := &ops.SystemStats{
		EventsByStatus: map[string]int{},
		EventsByType:   map[string]int{},
	}
	_, rows := statsTableBuilder(stats)
	for _, row := range rows {
		if (row[0] == "events_by_status" || row[0] == "events_by_type") && row[1] != "0" {
			t.Errorf("%s = %q, want \"0\"", row[0], row[1])
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
		case strings.Contains(r.URL.Path, "events"):
			w.Write([]byte(`[{"status":"live","type":"tono"}]`))
		case strings.Contains(r.URL.Path, "shard_ledger"):
			w.Write([]byte(`[{"delta":50}]`))
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
		"registered_users", "users_last_30_days", "events_by_status",
		"events_by_type", "total_shards_distributed", "pending_reports_count",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in JSON output, got:\n%s", want, out)
		}
	}
}
