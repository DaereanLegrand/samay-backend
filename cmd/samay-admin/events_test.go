package main

import (
	"net/http"
	"strings"
	"testing"
)

func TestEventsFeatureRequiresExpires(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"events", "feature", "e1"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "expires") {
		t.Fatalf("expected expires error, got: %v", err)
	}
}

func TestEventsFeatureInvalidDate(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"events", "feature", "e1", "--expires", "2026/01/01"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "YYYY-MM-DD") {
		t.Fatalf("expected date error, got: %v", err)
	}
}

func TestEventsCancelRequiresReason(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"events", "cancel", "e1"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "reason") {
		t.Fatalf("expected reason error, got: %v", err)
	}
}

func TestEventsDistributeShardsRequiresConfirm(t *testing.T) {
	setupTestEnv(t)
	resetFlag(t, eventsDistributeShardsCmd, "confirm", "false")
	rootCmd.SetArgs([]string{"events", "distribute-shards", "e1"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "confirm") {
		t.Fatalf("expected confirm error, got: %v", err)
	}
}

func TestEventsListInvalidStatus(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"events", "list", "--status", "bogus"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "one of") {
		t.Fatalf("expected enum error, got: %v", err)
	}
}

func TestEventsListSuccess(t *testing.T) {
	setupTestEnv(t)
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`[{"id":"e1","name":"Test Event","type":"casual","status":"upcoming","starts_at":"2026-06-01T18:00:00Z","ends_at":"2026-06-01T23:00:00Z","created_by_user_id":"u1","preshards_pool":100,"featured":false,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}]`))
	})
	rootCmd.SetArgs([]string{"events", "list"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "Test Event") {
		t.Errorf("expected event name in output, got: %q", out)
	}
	if !strings.Contains(out, "NAME") {
		t.Errorf("expected table header in output, got: %q", out)
	}
}
