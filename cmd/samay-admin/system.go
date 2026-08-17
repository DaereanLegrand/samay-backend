package main

import (
	"sort"
	"strconv"
	"strings"

	"github.com/samay-app/samay/internal/format"
	"github.com/samay-app/samay/internal/ops"
	"github.com/spf13/cobra"
)

var systemCmd = &cobra.Command{
	Use:   "system",
	Short: "System statistics and health checks",
	Long:  "Aggregate platform statistics and connectivity checks.",
}

var systemStatsCmd = &cobra.Command{
	Use:   "stats",
	Short: "Show platform statistics",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.GetSystemStats(ctx, dbClient)
		if err != nil {
			return err
		}
		format.Output(data, jsonFlag, statsTableBuilder)
		return nil
	},
}

var systemHealthCmd = &cobra.Command{
	Use:   "health",
	Short: "Check Supabase connectivity",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		report, err := ops.HealthCheck(ctx, dbClient)
		if err != nil {
			return err
		}
		format.Output(report, jsonFlag, healthTableBuilder)
		return nil
	},
}

func init() {
	systemCmd.AddCommand(systemStatsCmd, systemHealthCmd)
}

func statsTableBuilder(data any) ([]string, [][]string) {
	stats := data.(*ops.SystemStats)
	headers := []string{"METRIC", "VALUE"}
	rows := [][]string{
		{"registered_users", strconv.Itoa(stats.RegisteredUsers)},
		{"users_last_7_days", strconv.Itoa(stats.UsersLast7Days)},
		{"users_last_30_days", strconv.Itoa(stats.UsersLast30Days)},
		{"active_users_7_days", strconv.Itoa(stats.ActiveUsers7Days)},
		{"total_events", strconv.Itoa(stats.TotalEvents)},
		{"events_by_status", mapSummary(stats.EventsByStatus)},
		{"events_by_type", mapSummary(stats.EventsByType)},
		{"shards_in_circulation", strconv.Itoa(stats.ShardsInCirculation)},
		{"preshards_in_circulation", strconv.Itoa(stats.PreshardsInCirculation)},
		{"total_shards_distributed", strconv.Itoa(stats.TotalShardsDistributed)},
		{"pending_reports_count", strconv.Itoa(stats.PendingReportsCount)},
		{"pending_feature_requests", strconv.Itoa(stats.PendingFeatureRequests)},
	}
	return headers, rows
}

// mapSummary renders a count map deterministically, e.g. "draft: 1, live: 2".
func mapSummary(m map[string]int) string {
	if len(m) == 0 {
		return "0"
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, k+": "+strconv.Itoa(m[k]))
	}
	return strings.Join(parts, ", ")
}

func healthTableBuilder(data any) ([]string, [][]string) {
	health := data.(*ops.SystemHealth)
	headers := []string{"METRIC", "VALUE"}
	rows := [][]string{
		{"status", health.Status},
		{"api_latency", health.APILatency},
		{"db_connected", boolStr(health.DBConnected, "true", "false")},
	}
	return headers, rows
}
