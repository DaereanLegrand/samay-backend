// Command samay-billing-worker retries RevenueCat webhook failures recorded by
// the Edge Function (E2/Q28).
//
// It polls public.webhook_failures for due, unresolved rows (attempts < 5),
// resyncs the customer from RevenueCat v2, applies the subscription state, and
// records the result. Backoff is 1m / 5m / 30m / 2h / 12h; a row that exhausts
// the 5 attempts stays unresolved (next_attempt_at NULL) for alerting.
//
// Required env:
//
//	SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//	REVENUECAT_API_KEY, REVENUECAT_PROJECT_ID
//	REVENUECAT_ENTITLEMENT_MAP   JSON: {"<entitlement_id>": "pro"|"vip"}
//
// Optional env:
//
//	BILLING_POLL_INTERVAL (default 1m), BILLING_BATCH_SIZE (default 20)
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/joho/godotenv"
	"github.com/samay-app/samay/internal/billing"
	"github.com/samay-app/samay/internal/db"
)

func main() {
	if err := run(); err != nil {
		log.Printf("fatal: %v", err)
		os.Exit(1)
	}
}

func run() error {
	_ = godotenv.Load("supabase/.env")

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	mapping, err := billing.ParseEntitlementMap(os.Getenv("REVENUECAT_ENTITLEMENT_MAP"))
	if err != nil {
		return err
	}

	database, err := db.NewDBClient()
	if err != nil {
		return err
	}

	worker := &billing.Worker{
		DB: database,
		RC: &billing.RCClient{
			APIKey:    os.Getenv("REVENUECAT_API_KEY"),
			ProjectID: os.Getenv("REVENUECAT_PROJECT_ID"),
		},
		Map:   mapping,
		Logf:  log.Printf,
		Every: envDuration("BILLING_POLL_INTERVAL", time.Minute),
		Batch: envInt("BILLING_BATCH_SIZE", 20),
	}

	log.Printf("samay-billing-worker started (poll=%s, batch=%d)", worker.Every, worker.Batch)
	if err := worker.Run(ctx); err != nil {
		return err
	}
	return nil
}

func envDuration(name string, fallback time.Duration) time.Duration {
	v := os.Getenv(name)
	if v == "" {
		return fallback
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		log.Printf("invalid %s=%q, using %s", name, v, fallback)
		return fallback
	}
	return d
}

func envInt(name string, fallback int) int {
	v := os.Getenv(name)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		log.Printf("invalid %s=%q, using %d", name, v, fallback)
		return fallback
	}
	return n
}
