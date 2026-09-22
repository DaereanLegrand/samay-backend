package loadtest

import (
	"flag"
	"strings"
	"testing"
	"time"
)

func parseConfig(t *testing.T, args ...string) (*Config, error) {
	t.Helper()
	fs := flag.NewFlagSet("loadtest-test", flag.ContinueOnError)
	cfg := BindFlags(fs)
	if err := fs.Parse(args); err != nil {
		t.Fatalf("parse: %v", err)
	}
	return cfg, cfg.Validate()
}

func TestBindFlagsDefaults(t *testing.T) {
	cfg, err := parseConfig(t,
		"--url", "http://127.0.0.1:54386",
		"--anon-key", "a",
		"--service-key", "s",
	)
	if err != nil {
		t.Fatalf("validate: %v", err)
	}
	if cfg.Users != 100 {
		t.Errorf("Users = %d, want 100", cfg.Users)
	}
	if cfg.Matches != 100 {
		t.Errorf("Matches = %d, want 100", cfg.Matches)
	}
	if cfg.Groups != 15 {
		t.Errorf("Groups = %d, want 15", cfg.Groups)
	}
	if cfg.Events != 20 {
		t.Errorf("Events = %d, want 20", cfg.Events)
	}
	if cfg.Workers != 50 {
		t.Errorf("Workers = %d, want 50", cfg.Workers)
	}
	if cfg.Duration != 60*time.Second {
		t.Errorf("Duration = %s, want 60s", cfg.Duration)
	}
	if cfg.RunID == "" {
		t.Error("RunID must be defaulted")
	}
}

func TestValidateRequiresURL(t *testing.T) {
	_, err := parseConfig(t, "--anon-key", "a", "--service-key", "s")
	if err == nil || !strings.Contains(err.Error(), "url") {
		t.Fatalf("want url error, got %v", err)
	}
}

func TestValidateRequiresKeys(t *testing.T) {
	_, err := parseConfig(t, "--url", "http://127.0.0.1:54386")
	if err == nil {
		t.Fatal("want error for missing keys, got nil")
	}
}

func TestValidateRejectsBadURL(t *testing.T) {
	_, err := parseConfig(t, "--url", "not a url", "--anon-key", "a", "--service-key", "s")
	if err == nil {
		t.Fatal("want error for bad url, got nil")
	}
}

func TestValidateRejectsBadScheme(t *testing.T) {
	_, err := parseConfig(t, "--url", "ftp://example.com", "--anon-key", "a", "--service-key", "s", "--yes")
	if err == nil {
		t.Fatal("want error for non-http scheme, got nil")
	}
}

func TestValidateNonLocalRequiresAck(t *testing.T) {
	_, err := parseConfig(t,
		"--url", "https://samay-api.example.com",
		"--anon-key", "a",
		"--service-key", "s",
	)
	if err == nil || !strings.Contains(err.Error(), "--yes") {
		t.Fatalf("want --yes acknowledgement error, got %v", err)
	}
}

func TestValidateNonLocalWithAck(t *testing.T) {
	cfg, err := parseConfig(t,
		"--url", "https://samay-api.example.com",
		"--anon-key", "a",
		"--service-key", "s",
		"--yes",
	)
	if err != nil {
		t.Fatalf("validate: %v", err)
	}
	if cfg.IsLocal() {
		t.Error("IsLocal() = true for remote host")
	}
}

func TestValidateLocalSkipsAck(t *testing.T) {
	for _, host := range []string{"http://127.0.0.1:54386", "http://localhost:8000", "http://[::1]:54386"} {
		cfg, err := parseConfig(t, "--url", host, "--anon-key", "a", "--service-key", "s")
		if err != nil {
			t.Errorf("%s: validate: %v", host, err)
			continue
		}
		if !cfg.IsLocal() {
			t.Errorf("%s: IsLocal() = false", host)
		}
	}
}

func TestValidateRejectsBadCounts(t *testing.T) {
	cases := [][]string{
		{"--users", "-1"},
		{"--workers", "0"},
		{"--matches", "-2"},
	}
	for _, extra := range cases {
		args := append([]string{"--url", "http://127.0.0.1:54386", "--anon-key", "a", "--service-key", "s"}, extra...)
		if _, err := parseConfig(t, args...); err == nil {
			t.Errorf("args %v: want error, got nil", extra)
		}
	}
}

func TestValidateRequiresDurationForLoad(t *testing.T) {
	_, err := parseConfig(t,
		"--url", "http://127.0.0.1:54386", "--anon-key", "a", "--service-key", "s",
		"--duration", "0s",
	)
	if err == nil {
		t.Fatal("want error for zero duration, got nil")
	}
	// seed-only does not need a duration.
	if _, err := parseConfig(t,
		"--url", "http://127.0.0.1:54386", "--anon-key", "a", "--service-key", "s",
		"--duration", "0s", "--seed-only",
	); err != nil {
		t.Fatalf("seed-only with zero duration should validate: %v", err)
	}
}

func TestRealtimeURL(t *testing.T) {
	cases := []struct {
		base string
		want string
	}{
		{"https://samay-api.example.com", "wss://samay-api.example.com/realtime/v1/websocket?apikey=anon&vsn=1.0.0"},
		{"http://127.0.0.1:54386", "ws://127.0.0.1:54386/realtime/v1/websocket?apikey=anon&vsn=1.0.0"},
		{"https://host/base/", "wss://host/base/realtime/v1/websocket?apikey=anon&vsn=1.0.0"},
	}
	for _, c := range cases {
		cfg := &Config{URL: c.base, AnonKey: "anon"}
		got := cfg.RealtimeURL()
		if got != c.want {
			t.Errorf("RealtimeURL(%q) = %q, want %q", c.base, got, c.want)
		}
		if !strings.Contains(got, "apikey=anon") {
			t.Errorf("RealtimeURL missing apikey: %q", got)
		}
		if !strings.Contains(got, "vsn=1.0.0") {
			t.Errorf("RealtimeURL missing vsn: %q", got)
		}
	}
}

func TestRunIDNamespace(t *testing.T) {
	cfg := &Config{RunID: "abc"}
	if got := cfg.username(0); got != "ldabc_0" {
		t.Errorf("username(0) = %q", got)
	}
	if got := cfg.email(0); got != "ldabc_0@loadtest.samay" {
		t.Errorf("email(0) = %q", got)
	}
}
