package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/joho/godotenv"
	"github.com/samay-app/samay/internal/db"
)

// envKeys are the required environment variables, mirroring cmd/samay-admin/root.go.
var envKeys = []string{"SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_ADMIN_USER_ID"}

// serverVersion is reported by /api/v1/health. Bumped at release time; M-21 may
// source it from a VERSION file later (DEPLOYMENT-PLACEHOLDER.md §3.1).
const serverVersion = "0.1.0"

var (
	dbClient     *db.DBClient
	createClient = func() (*db.DBClient, error) {
		return db.NewDBClient()
	}
)

func main() {
	if err := run(); err != nil {
		log.Printf("fatal: %v", err)
		os.Exit(1)
	}
}

func run() error {
	_ = godotenv.Load()
	if err := validateEnv(); err != nil {
		return err
	}
	client, err := createClient()
	if err != nil {
		return fmt.Errorf("initialize database client: %w", err)
	}
	dbClient = client

	// PORT defaults to 8090, keeping the Samay server off common dev ports.
	port := os.Getenv("PORT")
	if port == "" {
		port = "8090"
	}

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           newRouter(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("samay-api-server listening on %s", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("server error: %v", err)
		}
	}()

	<-ctx.Done()
	log.Println("shutdown signal received; draining connections")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}

func validateEnv() error {
	var missing []string
	for _, key := range envKeys {
		if os.Getenv(key) == "" {
			missing = append(missing, key)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing required environment variable(s): %s", strings.Join(missing, ", "))
	}
	return nil
}

// adminIdentity returns the audit actor id for admin mutations. The CLI reads the
// same var; when JWT verification lands (S-06/M-21), this becomes the token subject.
func adminIdentity() string {
	return os.Getenv("SUPABASE_ADMIN_USER_ID")
}
