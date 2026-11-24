package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/joho/godotenv"
	"github.com/samay-app/samay/internal/db"
	"github.com/samay-app/samay/internal/storage"
)

func main() {
	if err := run(); err != nil {
		log.Printf("fatal: %v", err)
		os.Exit(1)
	}
}

func run() error {
	_ = godotenv.Load("../.env/testing-local.env")

	once := flag.Bool("once", false, "drain one batch and exit")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	database, err := db.NewDBClient()
	if err != nil {
		return err
	}
	objects, err := storage.NewClient()
	if err != nil {
		return err
	}

	worker := storage.NewWorker(database, objects, log.Printf)
	worker.Batch = envInt("OBJECT_DRAIN_BATCH_SIZE", 50)
	worker.MaxAttempts = envInt("OBJECT_DRAIN_MAX_ATTEMPTS", 5)
	interval := envDuration("OBJECT_DRAIN_INTERVAL", 30*time.Second)

	if *once {
		deleted, failed, err := worker.DrainOnce(ctx)
		if err != nil {
			return err
		}
		log.Printf("storage drainer: once done (deleted=%d failed=%d)", deleted, failed)
		return nil
	}

	log.Printf("samay-storage-drainer started (interval=%s, batch=%d, max_attempts=%d)",
		interval, worker.Batch, worker.MaxAttempts)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		if _, _, err := worker.DrainOnce(ctx); err != nil {
			log.Printf("storage drain error: %v", err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func envDuration(name string, fallback time.Duration) time.Duration {
	v := os.Getenv(name)
	if v == "" {
		return fallback
	}
	d, err := time.ParseDuration(v)
	if err != nil || d <= 0 {
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
