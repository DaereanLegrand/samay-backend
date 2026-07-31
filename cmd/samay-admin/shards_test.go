package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestShardsLedgerInvalidLimit(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"shards", "ledger", "u1", "--limit", "0"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "limit") {
		t.Fatalf("expected limit error, got: %v", err)
	}
}

func TestShardsRecalculateInvalidTier(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"shards", "recalculate-ranks", "--tier", "huge"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "one of") {
		t.Fatalf("expected enum error, got: %v", err)
	}
}

func TestShardsEventSummaryRendersJSON(t *testing.T) {
	setupTestEnv(t)
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`[{"id":"e1","name":"Test Event","status":"upcoming","preshards_pool":500,"preshards_distributed":false}]`))
	})
	rootCmd.SetArgs([]string{"shards", "event-summary", "e1"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !json.Valid([]byte(out)) {
		t.Fatalf("output is not valid JSON: %q", out)
	}
	if !strings.Contains(out, `"preshards_pool": 500`) {
		t.Errorf("JSON output missing event fields: %q", out)
	}
}
