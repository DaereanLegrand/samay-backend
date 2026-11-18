package ops

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/samay-app/samay/internal/db"
)

type SystemStats struct {
	RegisteredUsers        int `json:"registered_users"`
	UsersLast7Days         int `json:"users_last_7_days"`
	UsersLast30Days        int `json:"users_last_30_days"`
	ActiveUsers7Days       int `json:"active_users_7_days"`
	PendingReportsCount    int `json:"pending_reports_count"`
	PendingFeatureRequests int `json:"pending_feature_requests"`
}

type SystemHealth struct {
	Status      string `json:"status"`
	APILatency  string `json:"api_latency"`
	DBConnected bool   `json:"db_connected"`
}

// statsPageSize is the page size for paginated stats scans. PostgREST caps
// rows per response (db-max-rows), so aggregates over large tables must page.
const statsPageSize = 1000

// fetchAllRows pages through a table with the given QueryBuilder config,
// appending pages until a short one is returned. The builder is re-built per
// page so limit/offset can be set without mutating a shared builder.
func fetchAllRows[T any](ctx context.Context, client *db.DBClient, table string, config func(*db.QueryBuilder) *db.QueryBuilder) ([]T, error) {
	var all []T
	offset := 0
	for {
		qb := config(db.NewQueryBuilder()).Limit(statsPageSize).Offset(offset)
		page, err := db.List[T](ctx, client, table, qb)
		if err != nil {
			return nil, err
		}
		all = append(all, page...)
		if len(page) < statsPageSize {
			return all, nil
		}
		offset += statsPageSize
	}
}

type userStatRow struct {
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type countStatRow struct {
	ID string `json:"id"`
}

func GetSystemStats(ctx context.Context, client *db.DBClient) (*SystemStats, error) {
	stats := &SystemStats{}
	now := time.Now().UTC()
	weekAgo := now.AddDate(0, 0, -7)
	monthAgo := now.AddDate(0, 0, -30)

	// Single paginated scan of users feeds four metrics (counts and the
	// created_at/updated_at windows) — one query, no N+1s.
	// ActiveUsers7Days is a PROXY: users has no last_login_at column, so
	// updated_at (touched on profile edits, NOT logins) stands in for
	// activity. It over/under-counts vs true logins; a last_login_at column
	// migration is needed for the spec's "logged in last 7 days" semantics.
	users, err := fetchAllRows[userStatRow](ctx, client, "users", func(qb *db.QueryBuilder) *db.QueryBuilder {
		return qb.Select("created_at", "updated_at").Order("id", true)
	})
	if err != nil {
		return nil, fmt.Errorf("stats users: %w", err)
	}
	for _, u := range users {
		stats.RegisteredUsers++
		if !u.CreatedAt.Before(weekAgo) {
			stats.UsersLast7Days++
		}
		if !u.CreatedAt.Before(monthAgo) {
			stats.UsersLast30Days++
		}
		if !u.UpdatedAt.Before(weekAgo) {
			stats.ActiveUsers7Days++
		}
	}

	reports, err := fetchAllRows[countStatRow](ctx, client, "reports", func(qb *db.QueryBuilder) *db.QueryBuilder {
		return qb.Select("id").Eq("status", "pending").Order("id", true)
	})
	if err != nil {
		return nil, fmt.Errorf("stats reports: %w", err)
	}
	stats.PendingReportsCount = len(reports)

	requests, err := fetchAllRows[countStatRow](ctx, client, "feature_requests", func(qb *db.QueryBuilder) *db.QueryBuilder {
		return qb.Select("id").Eq("status", "pending").Order("id", true)
	})
	if err != nil {
		return nil, fmt.Errorf("stats feature_requests: %w", err)
	}
	stats.PendingFeatureRequests = len(requests)

	return stats, nil
}

func HealthCheck(ctx context.Context, client *db.DBClient) (*SystemHealth, error) {
	start := time.Now()
	_, err := client.Select(ctx, "app_config", "key", 1, 0)
	latency := time.Since(start)

	health := &SystemHealth{
		Status:      "ok",
		APILatency:  latency.Round(time.Millisecond).String(),
		DBConnected: err == nil,
	}
	if err != nil {
		health.Status = "degraded"
		return health, fmt.Errorf("database health check failed: %w", err)
	}
	return health, nil
}

func CheckHTTP(url string) error {
	httpClient := &http.Client{Timeout: 5 * time.Second}
	resp, err := httpClient.Get(url)
	if err != nil {
		return fmt.Errorf("http check failed for %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("http check for %s returned %d", url, resp.StatusCode)
	}
	return nil
}
