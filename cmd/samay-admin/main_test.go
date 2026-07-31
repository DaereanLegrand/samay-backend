package main

import (
	"strings"
	"testing"
)

func TestRootHelpListsAllGroups(t *testing.T) {
	resetAllFlags(rootCmd)
	rootCmd.SetArgs([]string{"--help"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, group := range []string{
		"users", "events", "groups", "reports", "shards",
		"config", "subs", "system", "feature-requests",
	} {
		if !strings.Contains(out, group) {
			t.Errorf("help output missing command group %q", group)
		}
	}
}

func TestRootVersionFlag(t *testing.T) {
	resetAllFlags(rootCmd)
	rootCmd.SetArgs([]string{"--version"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "1.2.0") {
		t.Errorf("version output missing version: %q", out)
	}
}

func TestUnknownCommandReturnsError(t *testing.T) {
	resetAllFlags(rootCmd)
	rootCmd.SetArgs([]string{"does-not-exist"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "unknown command") {
		t.Errorf("expected unknown command error, got: %v", err)
	}
}
