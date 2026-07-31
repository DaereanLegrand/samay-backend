package main

import (
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
