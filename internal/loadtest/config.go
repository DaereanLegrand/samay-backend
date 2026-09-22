// Package loadtest implements Samay's backend + realtime stress harness.
//
// It generates realistic seed data (users, friendships, groups, events, chats,
// minigame matches — all with images) and drives a concurrent read/write load
// plus RLS-gated Realtime subscriptions against a Supabase-compatible backend.
//
// The harness is deliberately self-contained: it talks plain HTTP/WS to the
// Kong gateway (auth, REST/RPC, storage, realtime) and never connects to
// PostgreSQL directly.
package loadtest

import (
	"flag"
	"fmt"
	"net"
	"net/url"
	"strings"
	"time"
)

// Config is the fully-resolved harness configuration.
type Config struct {
	URL          string
	AnonKey      string
	ServiceKey   string
	JWTSecret    string
	RunID        string
	Seed         int64
	Users        int
	Friendships  int
	Groups       int
	Events       int
	Matches      int
	Workers      int
	Duration     time.Duration
	Realtime     int
	SeedOnly     bool
	LoadOnly     bool
	RealtimeOnly bool
	Yes          bool
	JSON         bool
	MaxErrorRate float64
	Timeout      time.Duration
}

// BindFlags registers the harness flags on fs and returns the target Config
// pre-filled with defaults.
func BindFlags(fs *flag.FlagSet) *Config {
	cfg := &Config{}
	fs.StringVar(&cfg.URL, "url", "", "target base URL, e.g. https://samay-api.qallariy.lat (required)")
	fs.StringVar(&cfg.AnonKey, "anon-key", "", "anon API key (or SAMAY_ANON_KEY)")
	fs.StringVar(&cfg.ServiceKey, "service-key", "", "service_role API key (or SAMAY_SERVICE_KEY)")
	fs.StringVar(&cfg.JWTSecret, "jwt-secret", "", "target JWT secret; when set, user tokens are minted locally and GoTrue login is skipped")
	fs.StringVar(&cfg.RunID, "run-id", "", "namespace for created data (default: UTC timestamp)")
	fs.Int64Var(&cfg.Seed, "seed", time.Now().UnixNano(), "RNG seed for deterministic generation")
	fs.IntVar(&cfg.Users, "users", 100, "number of users to create")
	fs.IntVar(&cfg.Friendships, "friendships", 300, "number of friendship edges to create")
	fs.IntVar(&cfg.Groups, "groups", 15, "number of groups to create")
	fs.IntVar(&cfg.Events, "events", 20, "number of events to create")
	fs.IntVar(&cfg.Matches, "matches", 100, "number of minigame matches to create")
	fs.IntVar(&cfg.Workers, "workers", 50, "concurrent load workers")
	fs.DurationVar(&cfg.Duration, "duration", 60*time.Second, "load phase duration")
	fs.IntVar(&cfg.Realtime, "realtime", 25, "number of realtime websocket clients")
	fs.BoolVar(&cfg.SeedOnly, "seed-only", false, "only seed data; skip load and realtime")
	fs.BoolVar(&cfg.LoadOnly, "load-only", false, "only run the REST/RPC load phase")
	fs.BoolVar(&cfg.RealtimeOnly, "realtime-only", false, "only run the realtime phase")
	fs.BoolVar(&cfg.Yes, "yes", false, "acknowledge writing data to a non-local host")
	fs.BoolVar(&cfg.JSON, "json", false, "emit a machine-readable JSON report")
	fs.Float64Var(&cfg.MaxErrorRate, "max-error-rate", 0.05, "exit non-zero above this error ratio")
	fs.DurationVar(&cfg.Timeout, "timeout", 30*time.Second, "per-request HTTP timeout")
	return cfg
}

// Validate checks the configuration is internally consistent and safe to run.
func (c *Config) Validate() error {
	if strings.TrimSpace(c.URL) == "" {
		return fmt.Errorf("--url is required")
	}
	u, err := url.Parse(c.URL)
	if err != nil {
		return fmt.Errorf("--url is not a valid URL: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("--url must use http or https, got %q", u.Scheme)
	}
	if u.Host == "" {
		return fmt.Errorf("--url is missing a host")
	}
	if c.AnonKey == "" {
		return fmt.Errorf("--anon-key is required (or set SAMAY_ANON_KEY)")
	}
	if c.ServiceKey == "" {
		return fmt.Errorf("--service-key is required (or set SAMAY_SERVICE_KEY)")
	}
	if c.RunID == "" {
		c.RunID = time.Now().UTC().Format("20060102T150405")
	}
	if c.Users < 0 || c.Friendships < 0 || c.Groups < 0 || c.Events < 0 || c.Matches < 0 {
		return fmt.Errorf("counts must not be negative")
	}
	if c.Workers < 1 {
		return fmt.Errorf("--workers must be >= 1")
	}
	if c.Realtime < 0 {
		return fmt.Errorf("--realtime must not be negative")
	}
	if c.MaxErrorRate < 0 || c.MaxErrorRate > 1 {
		return fmt.Errorf("--max-error-rate must be within [0,1]")
	}
	if c.Timeout <= 0 {
		return fmt.Errorf("--timeout must be positive")
	}
	needsDuration := !c.SeedOnly
	if needsDuration && c.Duration <= 0 {
		return fmt.Errorf("--duration must be positive for the load phase")
	}
	if c.LoadOnly && c.SeedOnly {
		return fmt.Errorf("--load-only and --seed-only are mutually exclusive")
	}
	if c.RealtimeOnly && c.SeedOnly {
		return fmt.Errorf("--realtime-only and --seed-only are mutually exclusive")
	}
	if !c.IsLocal() && !c.Yes {
		return fmt.Errorf("target %q is not localhost; pass --yes to acknowledge writing data to a remote backend", c.URL)
	}
	return nil
}

// IsLocal reports whether the target host is a loopback address.
func (c *Config) IsLocal() bool {
	u, err := url.Parse(c.URL)
	if err != nil {
		return false
	}
	host := u.Hostname()
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// RealtimeURL builds the Kong-routed Realtime websocket URL
// (…/realtime/v1/websocket?apikey=…&vsn=1.0.0), preserving any base path.
func (c *Config) RealtimeURL() string {
	u, err := url.Parse(c.URL)
	if err != nil {
		return ""
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	case "http":
		u.Scheme = "ws"
	}
	base := strings.TrimRight(u.Path, "/")
	u.Path = base + "/realtime/v1/websocket"
	q := u.Query()
	q.Set("apikey", c.AnonKey)
	q.Set("vsn", "1.0.0")
	u.RawQuery = q.Encode()
	return u.String()
}

func (c *Config) username(i int) string { return fmt.Sprintf("ld%s_%d", c.RunID, i) }

func (c *Config) email(i int) string { return c.username(i) + "@loadtest.samay" }
