package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

const testUsersJSON = `[{"id":"u1","username":"alice","subscription_tier":"pro","personal_shards":100,"preshards":5,"created_at":"2026-01-01T00:00:00Z"}]`

func TestUsersDeleteRequiresConfirm(t *testing.T) {
	setupTestEnv(t)
	resetFlag(t, usersDeleteCmd, "confirm", "false")
	rootCmd.SetArgs([]string{"users", "delete", "u1"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "confirm") {
		t.Fatalf("expected confirm-required error, got: %v", err)
	}
}

func TestUsersDeleteWithConfirmProceeds(t *testing.T) {
	setupTestEnv(t)
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{}`))
	})
	rootCmd.SetArgs([]string{"users", "delete", "12345678-1234-1234-1234-123456789012", "--confirm"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "deleted") {
		t.Errorf("expected success message, got: %q", out)
	}
}

func TestUsersDeleteInvalidUUID(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"users", "delete", "not-a-uuid", "--confirm"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "UUID") {
		t.Fatalf("expected UUID error, got: %v", err)
	}
}

func TestUsersListTruncatesID(t *testing.T) {
	setupTestEnv(t)
	resetFlag(t, rootCmd, "json", "false")
	const longID = "12345678-1234-1234-1234-123456789012"
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`[{"id":"` + longID + `","username":"alice","subscription_tier":"free","personal_shards":1,"preshards":0,"created_at":"2026-01-01T00:00:00Z"}]`))
	})
	rootCmd.SetArgs([]string{"users", "list"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if strings.Contains(out, longID) {
		t.Errorf("table output should truncate id, found full id: %q", out)
	}
	if !strings.Contains(out, "12345678") {
		t.Errorf("table output missing truncated id: %q", out)
	}
}

func TestUsersBanRequiresReason(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"users", "ban", "u1"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "reason") {
		t.Fatalf("expected reason error, got: %v", err)
	}
}

func TestUsersGetNoArgs(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"users", "get"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "arg") {
		t.Fatalf("expected arg-count error, got: %v", err)
	}
}

func TestUsersListTableOutput(t *testing.T) {
	setupTestEnv(t)
	resetFlag(t, rootCmd, "json", "false")
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(testUsersJSON))
	})
	rootCmd.SetArgs([]string{"users", "list"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, want := range []string{"USERNAME", "alice", "SHARDS"} {
		if !strings.Contains(out, want) {
			t.Errorf("table output missing %q: %q", want, out)
		}
	}
}

func TestUsersListJSONOutput(t *testing.T) {
	setupTestEnv(t)
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(testUsersJSON))
	})
	rootCmd.SetArgs([]string{"users", "list", "--json"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !json.Valid([]byte(out)) {
		t.Fatalf("output is not valid JSON: %q", out)
	}
	if !strings.Contains(out, `"username": "alice"`) {
		t.Errorf("JSON output missing user fields: %q", out)
	}
}

func TestUsersBanSuccess(t *testing.T) {
	setupTestEnv(t)
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`[]`))
	})
	rootCmd.SetArgs([]string{"users", "ban", "12345678-1234-1234-1234-123456789012", "--reason", "spam"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "banned") {
		t.Errorf("expected success message, got: %q", out)
	}
}

func TestUsersUnbanSuccess(t *testing.T) {
	setupTestEnv(t)
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`[]`))
	})
	rootCmd.SetArgs([]string{"users", "unban", "12345678-1234-1234-1234-123456789012"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "unbanned") {
		t.Errorf("expected success message, got: %q", out)
	}
}

func TestUsersLedgerRequiresArg(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"users", "ledger"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "arg") {
		t.Fatalf("expected arg-count error, got: %v", err)
	}
}

func TestUsersLedgerRejectsNonPositiveLimit(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"users", "ledger", "u1", "--limit", "0"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "limit") {
		t.Fatalf("expected limit error, got: %v", err)
	}
}

func TestUsersLedgerTableOutput(t *testing.T) {
	setupTestEnv(t)
	resetFlag(t, rootCmd, "json", "false")
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`[{"id":"s1","delta":50,"reason":"admin_grant","reference_id":null,"created_at":"2026-01-01T00:00:00Z"}]`))
	})
	rootCmd.SetArgs([]string{"users", "ledger", "12345678-1234-1234-1234-123456789012"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, want := range []string{"DELTA", "REASON", "admin_grant", "50"} {
		if !strings.Contains(out, want) {
			t.Errorf("ledger output missing %q: %q", want, out)
		}
	}
}
