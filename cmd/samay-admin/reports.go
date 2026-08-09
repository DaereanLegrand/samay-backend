package main

import (
	"fmt"

	"github.com/samay-app/samay/internal/db"
	"github.com/samay-app/samay/internal/format"
	"github.com/samay-app/samay/internal/ops"
	"github.com/spf13/cobra"
)

var reportsCmd = &cobra.Command{
	Use:   "reports",
	Short: "Moderate user reports",
	Long:  "List, inspect, and act on user-submitted reports.",
}

var reportsListCmd = &cobra.Command{
	Use:   "list",
	Short: "List reports",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		status, _ := cmd.Flags().GetString("status")
		if status != "" {
			if err := oneOf(status, "pending", "reviewed", "actioned", "dismissed"); err != nil {
				return err
			}
		}
		targetType, _ := cmd.Flags().GetString("type")
		if targetType != "" {
			if err := oneOf(targetType, "message", "photo", "user", "event"); err != nil {
				return err
			}
		}
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.ListReports(ctx, dbClient, ops.ListReportsParams{
			Status: status,
			Type:   targetType,
		})
		if err != nil {
			return err
		}
		format.Output(data, jsonFlag, reportsTableBuilder)
		return nil
	},
}

var reportsGetCmd = &cobra.Command{
	Use:   "get <report_id>",
	Short: "Show report details",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.GetReport(ctx, dbClient, args[0])
		if err != nil {
			return err
		}
		format.RenderJSON(data)
		return nil
	},
}

var reportsActionCmd = &cobra.Command{
	Use:   "action <report_id>",
	Short: "Act on a report",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		action, _ := cmd.Flags().GetString("action")
		if err := oneOf(action, "remove", "dismiss", "warn"); err != nil {
			return err
		}
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.ActionReport(ctx, dbClient, args[0], action, adminUserID()); err != nil {
			return err
		}
		fmt.Printf("report %s actioned: %s\n", args[0], action)
		return nil
	},
}

func init() {
	reportsListCmd.Flags().String("status", "", "filter by status (pending|reviewed|actioned|dismissed)")
	reportsListCmd.Flags().String("type", "", "filter by target type (message|photo|user|event)")

	reportsActionCmd.Flags().String("action", "", "action to take (remove|dismiss|warn) (required)")
	_ = reportsActionCmd.MarkFlagRequired("action")

	reportsCmd.AddCommand(reportsListCmd, reportsGetCmd, reportsActionCmd)
}

func reportsTableBuilder(data interface{}) ([]string, [][]string) {
	reports := data.([]db.Report)
	headers := []string{"ID", "REPORTER", "TARGET_TYPE", "TARGET_ID", "REASON", "STATUS", "CREATED_AT"}
	rows := make([][]string, 0, len(reports))
	for _, r := range reports {
		rows = append(rows, []string{
			r.ID,
			r.ReporterID,
			r.TargetType,
			r.TargetID,
			r.Reason,
			r.Status,
			fmtTimeVal(r.CreatedAt),
		})
	}
	return headers, rows
}
