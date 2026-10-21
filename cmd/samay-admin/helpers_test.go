package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/samay-app/samay/internal/db"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"github.com/spf13/viper"
)

const testAdminID = "00000000-0000-4000-8000-000000000001"

func setupTestEnv(t *testing.T) {
	t.Helper()
	viper.Reset()
	t.Setenv("SUPABASE_URL", "https://example.supabase.co")
	t.Setenv("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
	t.Setenv("SAMAY_ADMIN_USER_ID", testAdminID)
	initConfig()
	resetAllFlags(rootCmd)
	stubCreateClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`[]`))
	})
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
	client := stubDBClient(t, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/rest/v1/admin_users") {
			w.Header().Set("Content-Type", "application/json")
			if strings.TrimPrefix(r.URL.Query().Get("id"), "eq.") == testAdminID {
				fmt.Fprintf(w, `[{"id":%q,"email":"admin@example.com","display_name":"Admin","role":"super_admin","created_at":"2026-01-01T00:00:00Z"}]`, testAdminID)
			} else {
				w.Write([]byte(`[]`))
			}
			return
		}
		handler(w, r)
	})
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
