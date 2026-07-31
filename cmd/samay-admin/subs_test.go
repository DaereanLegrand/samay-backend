package main

import (
	"strings"
	"testing"
)

func TestSubsOverrideRequiresTierAndExpires(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"subs", "override", "u1"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "expires") || !strings.Contains(err.Error(), "tier") {
		t.Fatalf("expected missing-flag error, got: %v", err)
	}
}

func TestSubsOverrideInvalidTier(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"subs", "override", "u1", "--tier", "gold", "--expires", "2026-12-31"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "one of") {
		t.Fatalf("expected enum error, got: %v", err)
	}
}

func TestSubsListInvalidTier(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"subs", "list", "--tier", "gold"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "one of") {
		t.Fatalf("expected enum error, got: %v", err)
	}
}

func TestSubsListNegativeExpiringWithin(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"subs", "list", "--expiring-within", "-3"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "expiring-within") {
		t.Fatalf("expected expiring-within error, got: %v", err)
	}
}
