package main

import (
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
