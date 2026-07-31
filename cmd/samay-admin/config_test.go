package main

import (
	"strings"
	"testing"
)

func TestConfigSetRequiresConfirm(t *testing.T) {
	setupTestEnv(t)
	resetFlag(t, configSetCmd, "confirm", "false")
	rootCmd.SetArgs([]string{"config", "set", "max_group_size", "20"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "confirm") {
		t.Fatalf("expected confirm error, got: %v", err)
	}
}

func TestConfigGetNoArgs(t *testing.T) {
	setupTestEnv(t)
	rootCmd.SetArgs([]string{"config", "get"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "arg") {
		t.Fatalf("expected arg-count error, got: %v", err)
	}
}
