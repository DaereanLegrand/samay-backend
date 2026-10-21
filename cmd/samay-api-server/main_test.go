package main

import (
	"strings"
	"testing"
)

func TestValidateEnv_MissingVars(t *testing.T) {
	for _, key := range envKeys {
		t.Setenv(key, "")
	}
	initConfig()

	err := validateEnv()

	if err == nil {
		t.Fatal("expected error for missing env vars")
	}
	for _, key := range envKeys {
		if !strings.Contains(err.Error(), key) {
			t.Errorf("expected error to mention %s, got: %v", key, err)
		}
	}
}

func TestValidateEnv_AllSet(t *testing.T) {
	t.Setenv("SUPABASE_URL", "https://example.supabase.co")
	t.Setenv("SUPABASE_SERVICE_ROLE_KEY", "placeholder-service-key")
	initConfig()

	if err := validateEnv(); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestNewVerifierFromEnv_FallsBackToLocalSecret(t *testing.T) {
	t.Setenv("SUPABASE_JWT_SECRET", "")
	t.Setenv("JWT_SECRET", "local-secret")
	if _, err := newVerifier(); err != nil {
		t.Fatalf("expected JWT_SECRET fallback to succeed: %v", err)
	}
}

func TestNewVerifierFromEnv_RequiresSecret(t *testing.T) {
	t.Setenv("SUPABASE_JWT_SECRET", "")
	t.Setenv("JWT_SECRET", "")
	if _, err := newVerifier(); err == nil {
		t.Fatal("expected an error when no JWT secret is configured")
	}
}

func TestRun_FailsFastOnMissingEnv(t *testing.T) {
	for _, key := range envKeys {
		t.Setenv(key, "")
	}
	initConfig()

	err := run()

	if err == nil {
		t.Fatal("expected run() to fail fast when env vars are missing")
	}
	if !strings.Contains(err.Error(), "missing required environment variable") {
		t.Errorf("unexpected error: %v", err)
	}
}
