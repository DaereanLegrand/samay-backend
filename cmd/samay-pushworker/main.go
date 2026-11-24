// Command samay-pushworker drains push-eligible notifications and sends them
// over FCM HTTP v1 (Android + iOS via APNs).
//
// It polls the `notifications` table for rows flagged push-eligible
// (minigame_invite / minigame_turn) whose `push_sent_at` is NULL, resolves the
// recipient's `device_tokens`, dispatches, and marks the row sent. Pruning of
// stale tokens happens inline on FCM UNREGISTERED. Single-instance by design.
//
// FCM credential (one of):
//
//	SUPABASE_FCM_SERVICE_ACCOUNT_JSON       path to the service-account JSON
//	SUPABASE_FCM_SERVICE_ACCOUNT_JSON_B64   base64 of the JSON (compose env)
//
// When neither is set the worker logs a warning and idles (harmless for a dev
// stack that is not testing push); it never crash-loops.
//
// Required env:
//
//	SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY   (PostgREST access)
//
// Optional env:
//
//	PUSH_POLL_INTERVAL (default 15s), PUSH_BATCH_SIZE (default 100)
package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/joho/godotenv"
	"github.com/samay-app/samay/internal/db"
	"github.com/samay-app/samay/internal/push"
)

func main() {
	if err := run(); err != nil {
		log.Printf("fatal: %v", err)
		os.Exit(1)
	}
}

func run() error {
	_ = godotenv.Load("../.env/testing-local.env")

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	database, err := db.NewDBClient()
	if err != nil {
		return err
	}

	fcm, err := fcmClientFromEnv()
	if err != nil {
		return fmt.Errorf("initialize FCM client: %w", err)
	}
	if fcm == nil {
		log.Printf("push disabled: no FCM service account configured " +
			"(set SUPABASE_FCM_SERVICE_ACCOUNT_JSON or _B64); idling")
		<-ctx.Done()
		return nil
	}

	worker := push.NewWorker(database, fcm, log.Printf)
	worker.Every = envDuration("PUSH_POLL_INTERVAL", 15*time.Second)
	worker.Batch = envInt("PUSH_BATCH_SIZE", 100)

	log.Printf("samay-pushworker started (poll=%s, batch=%d)", worker.Every, worker.Batch)
	if err := worker.Run(ctx); err != nil {
		return err
	}
	return nil
}

// fcmClientFromEnv builds the FCM client from the inline base64 credential
// (preferred, compose-friendly) or a service-account file path. Returns
// (nil, nil) when neither is configured so the caller can idle.
func fcmClientFromEnv() (*push.FCMClient, error) {
	if b64 := strings.TrimSpace(os.Getenv("SUPABASE_FCM_SERVICE_ACCOUNT_JSON_B64")); b64 != "" {
		raw, err := base64.StdEncoding.DecodeString(b64)
		if err != nil {
			return nil, fmt.Errorf("decode SUPABASE_FCM_SERVICE_ACCOUNT_JSON_B64: %w", err)
		}
		return push.NewFCMClientFromJSON(raw)
	}
	path := firstEnv("SUPABASE_FCM_SERVICE_ACCOUNT_JSON", "FCM_SERVICE_ACCOUNT_JSON")
	if path == "" {
		return nil, nil
	}
	return push.NewFCMClient(path)
}

func firstEnv(names ...string) string {
	for _, n := range names {
		if v := os.Getenv(n); v != "" {
			return v
		}
	}
	return ""
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
