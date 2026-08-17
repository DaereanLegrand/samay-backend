package main

import (
	"net/http"
	"os"
	"strings"
	"testing"

	"github.com/samay-app/samay/internal/db"
	"github.com/samay-app/samay/internal/validate"
	"github.com/spf13/viper"
)

func unsetEnv(t *testing.T, keys ...string) func() {
	t.Helper()
	type saved struct {
		val string
		ok  bool
	}
	prev := map[string]saved{}
	for _, k := range keys {
		v, ok := os.LookupEnv(k)
		prev[k] = saved{v, ok}
		os.Unsetenv(k)
	}
	return func() {
		for k, s := range prev {
			if s.ok {
				os.Setenv(k, s.val)
			} else {
				os.Unsetenv(k)
			}
		}
	}
}

func TestValidateEnv_MissingVars(t *testing.T) {
	viper.Reset()
	restore := unsetEnv(t, envKeys...)
	defer restore()
	initConfig()

	err := validateEnv()
	if err == nil {
		t.Fatal("expected error when env vars are missing")
	}
	for _, key := range envKeys {
		if !strings.Contains(err.Error(), key) {
			t.Errorf("error %q does not name missing variable %s", err, key)
		}
	}
}

func TestValidateEnv_Present(t *testing.T) {
	setupTestEnv(t)
	if err := validateEnv(); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestUsersListMissingEnvReturnsError(t *testing.T) {
	viper.Reset()
	restore := unsetEnv(t, envKeys...)
	defer restore()
	initConfig()

	rootCmd.SetArgs([]string{"users", "list"})
	_, err := captureStdout(t, rootCmd.Execute)
	if err == nil || !strings.Contains(err.Error(), "SUPABASE_URL") {
		t.Fatalf("expected env error naming SUPABASE_URL, got: %v", err)
	}
}

func TestParseUUID(t *testing.T) {
	valid := "12345678-1234-1234-1234-123456789012"
	if err := validate.ParseUUID(valid); err != nil {
		t.Errorf("expected valid UUID to pass, got: %v", err)
	}
	for _, bad := range []string{"", "xyz", "12345678", "12345678-1234-1234-1234-12345678901Z", "12345678-1234-1234-1234-1234567890123", "12345678 1234-1234-1234-123456789012"} {
		if err := validate.ParseUUID(bad); err == nil {
			t.Errorf("expected %q to be rejected", bad)
		}
	}
}

func TestInitClientUsesCreateClient(t *testing.T) {
	setupTestEnv(t)
	called := false
	createClient = func() (*db.DBClient, error) {
		called = true
		return &db.DBClient{BaseURL: "http://localhost", ServiceKey: "k", HTTP: &http.Client{}}, nil
	}
	defer func() { createClient = func() (*db.DBClient, error) { return db.NewDBClient() } }()

	if err := initClient(); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !called {
		t.Error("createClient was not called")
	}
	if dbClient == nil {
		t.Error("dbClient not set")
	}
}
