package main

import (
	"strings"
	"testing"
)

func TestReportsActionRequiresAction(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"reports", "action", "r1"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "action") {
		t.Fatalf("expected action error, got: %v", err)
	}
}

func TestReportsActionInvalidAction(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"reports", "action", "r1", "--action", "explode"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "one of") {
		t.Fatalf("expected enum error, got: %v", err)
	}
}
