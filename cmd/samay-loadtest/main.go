// Command samay-loadtest is Samay's backend + realtime stress harness.
//
// It creates realistic seed data (users, friendships, groups, events, chats and
// minigame matches, all with images) and then drives a concurrent REST/RPC
// workload plus RLS-gated Realtime subscriptions against a Supabase-compatible
// backend. It never deletes what it created — each run is namespaced by
// --run-id.
//
// Usage:
//
//	samay-loadtest --url https://samay-api.example.com \
//	    --anon-key "$ANON" --service-key "$SERVICE_ROLE" --yes
//
// See --help for every flag.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/samay-app/samay/internal/loadtest"
)

func main() {
	fs := flag.NewFlagSet("samay-loadtest", flag.ExitOnError)
	cfg := loadtest.BindFlags(fs)
	if err := fs.Parse(os.Args[1:]); err != nil {
		os.Exit(2)
	}
	applyEnvFallbacks(cfg)
	if err := cfg.Validate(); err != nil {
		fmt.Fprintf(os.Stderr, "config error: %v\n\n", err)
		fs.Usage()
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	logf := func(format string, args ...any) {
		fmt.Fprintf(os.Stderr, "[loadtest] "+format+"\n", args...)
	}

	rep, err := loadtest.Run(ctx, cfg, logf)
	if rep != nil {
		rep.Render(cfg.JSON)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "run failed: %v\n", err)
		os.Exit(1)
	}
	if !rep.Passed {
		os.Exit(1)
	}
}

// applyEnvFallbacks fills unset flags from the environment (SAMAY_* first, then
// the generic Supabase names used elsewhere in the repo).
func applyEnvFallbacks(cfg *loadtest.Config) {
	if cfg.URL == "" {
		cfg.URL = firstEnv("SAMAY_URL", "SUPABASE_URL")
	}
	if cfg.AnonKey == "" {
		cfg.AnonKey = firstEnv("SAMAY_ANON_KEY", "SUPABASE_ANON_KEY")
	}
	if cfg.ServiceKey == "" {
		cfg.ServiceKey = firstEnv("SAMAY_SERVICE_KEY", "SUPABASE_SERVICE_ROLE_KEY")
	}
	if cfg.JWTSecret == "" {
		cfg.JWTSecret = firstEnv("SAMAY_JWT_SECRET", "JWT_SECRET")
	}
}

func firstEnv(names ...string) string {
	for _, n := range names {
		if v := os.Getenv(n); v != "" {
			return v
		}
	}
	return ""
}
