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
		"users", "reports", "appeals", "config", "system", "feature-requests",
	} {
		if !strings.Contains(out, group) {
			t.Errorf("help output missing command group %q", group)
		}
	}
}

func TestRootHelpOmitsRemovedGroups(t *testing.T) {
	resetAllFlags(rootCmd)
	rootCmd.SetArgs([]string{"--help"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, group := range []string{"events", "groups", "shards", "subs"} {
		if strings.Contains(out, group+" ") || strings.Contains(out, group+"\n") {
			t.Errorf("help output still lists removed command group %q:\n%s", group, out)
		}
	}
}

func TestRemovedCommandsAreUnknown(t *testing.T) {
	for _, args := range [][]string{
		{"events", "list"},
		{"groups", "list"},
		{"shards", "ledger", "u1"},
		{"subs", "list"},
		{"users", "grant-shards", "u1", "10", "--confirm"},
		{"users", "grant-preshards", "u1", "10", "--confirm"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			resetAllFlags(rootCmd)
			rootCmd.SetArgs(args)
			_, err := captureStdout(t, rootCmd.Execute)
			if err == nil {
				t.Fatalf("expected %v to be rejected as removed", args)
			}
			if !strings.Contains(err.Error(), "unknown command") && !strings.Contains(err.Error(), "unknown flag") {
				t.Fatalf("expected unknown command/flag for %v, got: %v", args, err)
			}
		})
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
