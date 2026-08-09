package db

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
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

func TestNewDBClient(t *testing.T) {
	t.Setenv("SUPABASE_URL", "http://localhost:54386")
	t.Setenv("SUPABASE_SERVICE_ROLE_KEY", "test-key")

	c, err := NewDBClient()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c.BaseURL != "http://localhost:54386" {
		t.Errorf("expected http://localhost:54386, got %s", c.BaseURL)
	}
	if c.ServiceKey != "test-key" {
		t.Errorf("expected test-key, got %s", c.ServiceKey)
	}
}

func TestNewDBClient_ValidationError(t *testing.T) {
	cases := []struct {
		name     string
		url      string
		key      string
		wantHint string
	}{
		{name: "missing both", url: "", key: "", wantHint: "SUPABASE_URL"},
		{name: "missing url", url: "", key: "k", wantHint: "SUPABASE_URL"},
		{name: "missing key", url: "http://localhost", key: "", wantHint: "SUPABASE_SERVICE_ROLE_KEY"},
		{name: "whitespace only", url: "   ", key: "\t", wantHint: "SUPABASE_URL"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			restore := unsetEnv(t, "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY")
			defer restore()
			t.Setenv("SUPABASE_URL", tc.url)
			t.Setenv("SUPABASE_SERVICE_ROLE_KEY", tc.key)

			c, err := NewDBClient()
			if err == nil {
				t.Fatal("expected validation error, got nil")
			}
			if c != nil {
				t.Errorf("expected nil client on validation error, got %+v", c)
			}
			if !strings.Contains(err.Error(), tc.wantHint) {
				t.Errorf("error %q does not name %s", err, tc.wantHint)
			}
		})
	}
}

func TestRequest_CancelledContext(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer srv.Close()
	c := &DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	start := time.Now()
	_, err := c.Select(ctx, "users", "id", 0, 0)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got: %v", err)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("canceled request did not return quickly, took %v", elapsed)
	}
}

func TestRequest_ContextTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
		w.WriteHeader(200)
	}))
	defer srv.Close()
	c := &DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()

	_, err := c.Select(ctx, "users", "id", 0, 0)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected context.DeadlineExceeded, got: %v", err)
	}
}

func TestRequest_ErrorResponseRead(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
		w.Write([]byte(`{"message":"boom"}`))
	}))
	defer srv.Close()
	c := &DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}

	_, err := c.Select(context.Background(), "users", "id", 0, 0)
	if err == nil {
		t.Fatal("expected error for 500 response")
	}
	if !strings.Contains(err.Error(), "boom") {
		t.Errorf("expected response body in error, got: %v", err)
	}
}
