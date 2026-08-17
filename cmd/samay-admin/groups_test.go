package main

import (
	"net/http"
	"strings"
	"testing"
)

func TestGroupsListRejectsInvalidBracket(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"groups", "list", "--bracket", "b80_100"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "must be one of") {
		t.Fatalf("expected invalid-bracket error, got: %v", err)
	}
}

func TestGroupsListAcceptsAllSpecBrackets(t *testing.T) {
	for _, bracket := range []string{"b0_20", "b20_40", "b40_60", "b60_80", "b80_90", "b90_100"} {
		setupTestEnv(t)
		rootCmd.SetArgs([]string{"groups", "list", "--bracket", bracket})
		_, err := captureStdout(t, rootCmd.Execute)
		if err == nil {
			continue
		}
		if strings.Contains(err.Error(), "must be one of") {
			t.Fatalf("bracket %q unexpectedly rejected: %v", bracket, err)
		}
	}
}

func TestGroupsListRejectsInvalidTier(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"groups", "list", "--tier", "huge"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "must be one of") {
		t.Fatalf("expected invalid-tier error, got: %v", err)
	}
}

func TestGroupsListSuccess(t *testing.T) {
	setupTestEnv(t)
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`[{"id":"g1","name":"Test Group","size_tier":"small","rank_bracket":"b0_20","group_shards":50,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}]`))
	})
	rootCmd.SetArgs([]string{"groups", "list"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "Test Group") {
		t.Errorf("expected group name in output, got: %q", out)
	}
	if !strings.Contains(out, "NAME") {
		t.Errorf("expected table header in output, got: %q", out)
	}
}
