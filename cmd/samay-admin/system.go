package main

import (
	"strconv"

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
		{"pending_reports_count", strconv.Itoa(stats.PendingReportsCount)},
		{"pending_feature_requests", strconv.Itoa(stats.PendingFeatureRequests)},
	}
	return headers, rows
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
