package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/samay-app/samay/internal/db"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"github.com/spf13/viper"
)

func setupTestEnv(t *testing.T) {
	t.Helper()
	viper.Reset()
	t.Setenv("SUPABASE_URL", "https://example.supabase.co")
	t.Setenv("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
	t.Setenv("SUPABASE_ADMIN_USER_ID", "admin-1")
	initConfig()
	resetAllFlags(rootCmd)
}

func resetAllFlags(cmd *cobra.Command) {
	for _, c := range cmd.Commands() {
		resetAllFlags(c)
	}
	resetFlagSet(cmd.Flags())
	resetFlagSet(cmd.PersistentFlags())
}

func resetFlagSet(flags *pflag.FlagSet) {
	flags.VisitAll(func(f *pflag.Flag) {
		if err := f.Value.Set(f.DefValue); err != nil {
			_ = flags.Set(f.Name, f.DefValue)
		}
		f.Changed = false
	})
}

func stubDBClient(t *testing.T, handler http.HandlerFunc) *db.DBClient {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	return &db.DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}
}

func stubCreateClient(t *testing.T, handler http.HandlerFunc) {
	t.Helper()
	client := stubDBClient(t, handler)
	createClient = func() (*db.DBClient, error) { return client, nil }
}

func captureStdout(t *testing.T, fn func() error) (string, error) {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	runErr := fn()
	w.Close()
	os.Stdout = old
	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	return string(out), runErr
}

func resetFlag(t *testing.T, cmd *cobra.Command, name, value string) {
	t.Helper()
	if err := cmd.Flags().Set(name, value); err == nil {
		return
	}
	if err := cmd.PersistentFlags().Set(name, value); err != nil {
		t.Fatalf("reset flag %s: %v", name, err)
	}
}
