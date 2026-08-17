package main

import (
	"net/http"
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

func TestConfigGetSuccess(t *testing.T) {
	setupTestEnv(t)
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`[{"key":"max_group_size","value":"20","description":"Max group size","default_value":"15","updated_at":"2026-01-01T00:00:00Z"}]`))
	})
	rootCmd.SetArgs([]string{"config", "get", "max_group_size"})
	out, err := captureStdout(t, rootCmd.Execute)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "max_group_size") {
		t.Errorf("expected config key in output, got: %q", out)
	}
	if !strings.Contains(out, "20") {
		t.Errorf("expected config value in output, got: %q", out)
	}
}
