package ops

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/vive-app/vive/internal/db"
)

type SystemStats struct {
	RegisteredUsers       int `json:"registered_users"`
	UsersLast7Days        int `json:"users_last_7_days"`
	ActiveUsers7Days      int `json:"active_users_7_days"`
	TotalEvents           int `json:"total_events"`
	ShardsInCirculation   int `json:"shards_in_circulation"`
	PreshardsInCirculation int `json:"preshards_in_circulation"`
	PendingReportsCount   int `json:"pending_reports_count"`
	PendingFeatureRequests int `json:"pending_feature_requests"`
}

type SystemHealth struct {
	Status     string `json:"status"`
	APILatency string `json:"api_latency"`
	DBConnected bool  `json:"db_connected"`
}

func GetSystemStats(client *db.DBClient) (*SystemStats, error) {
	stats := &SystemStats{}

	usersBody, err := client.Select("users", "id", 0, 0)
	if err == nil {
		var users []db.User
		json.Unmarshal(usersBody, &users)
		stats.RegisteredUsers = len(users)
	}

	eventsBody, err := client.Select("events", "id", 0, 0)
	if err == nil {
		var events []db.Event
		json.Unmarshal(eventsBody, &events)
		stats.TotalEvents = len(events)
	}

	return stats, nil
}

func HealthCheck(client *db.DBClient) (*SystemHealth, error) {
	start := time.Now()
	_, err := client.Select("app_config", "key", 1, 0)
	latency := time.Since(start)

	health := &SystemHealth{
		Status:      "ok",
		APILatency:  latency.Round(time.Millisecond).String(),
		DBConnected: err == nil,
	}
	if err != nil {
		health.Status = "degraded"
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
