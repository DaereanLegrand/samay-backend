package main

import (
	"fmt"

	"github.com/samay-app/samay/internal/db"
	"github.com/samay-app/samay/internal/format"
	"github.com/samay-app/samay/internal/ops"
	"github.com/samay-app/samay/internal/validate"
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
			if err := validate.OneOf(status, "pending", "reviewed", "actioned", "dismissed"); err != nil {
				return err
			}
		}
		targetType, _ := cmd.Flags().GetString("type")
		if targetType != "" {
			if err := validate.OneOf(targetType,
				"message", "photo", "user", "event", "minigame_answer",
				"minigame_image", "avatar", "group_cover", "event_description"); err != nil {
				return err
			}
		}
		category, _ := cmd.Flags().GetString("category")
		if category != "" {
			if err := validate.OneOf(category,
				"csam", "credible_threat", "ncii", "harassment",
				"hate", "spam", "impersonation", "other"); err != nil {
				return err
			}
		}
		limit, _ := cmd.Flags().GetInt("limit")
		offset, _ := cmd.Flags().GetInt("offset")
		var priority *int
		if cmd.Flags().Changed("priority") {
			p, _ := cmd.Flags().GetInt("priority")
			priority = &p
		}
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.ListReports(ctx, dbClient, ops.ListReportsParams{
			Status:   status,
			Type:     targetType,
			Category: category,
			Priority: priority,
			Limit:    limit,
			Offset:   offset,
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

var reportsMessageCmd = &cobra.Command{
	Use:   "message <report_id>",
	Short: "Show the reported message content (moderator view)",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.GetMessageReport(ctx, dbClient, args[0])
		if err != nil {
			return err
		}
		format.RenderJSON(data)
		return nil
	},
}

var reportsClaimCmd = &cobra.Command{
	Use:   "claim <report_id>",
	Short: "Claim a pending report (records the real admin actor)",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.ClaimReport(ctx, dbClient, args[0], adminUserID()); err != nil {
			return err
		}
		fmt.Printf("report %s claimed\n", args[0])
		return nil
	},
}

var reportsActionCmd = &cobra.Command{
	Use:   "action <report_id>",
	Short: "Act on a report",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		action, _ := cmd.Flags().GetString("action")
		if err := validate.OneOf(action, "review", "remove", "dismiss", "warn"); err != nil {
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
	reportsListCmd.Flags().String("type", "", "filter by target type (message|photo|user|event|minigame_answer|minigame_image|avatar|group_cover|event_description)")
	reportsListCmd.Flags().String("category", "", "filter by category (csam|credible_threat|ncii|harassment|hate|spam|impersonation|other)")
	reportsListCmd.Flags().Int("priority", 100, "filter by numeric priority (0 = most urgent)")
	reportsListCmd.Flags().Int("limit", 100, "page size (max 500)")
	reportsListCmd.Flags().Int("offset", 0, "page offset")

	reportsActionCmd.Flags().String("action", "", "action to take (review|remove|dismiss|warn) (required)")
	_ = reportsActionCmd.MarkFlagRequired("action")

	reportsCmd.AddCommand(reportsListCmd, reportsGetCmd, reportsMessageCmd, reportsClaimCmd, reportsActionCmd)
}

func reportsTableBuilder(data any) ([]string, [][]string) {
	reports := data.([]db.Report)
	headers := []string{"PRIORITY", "CATEGORY", "ID", "REPORTER", "TARGET_TYPE", "TARGET_ID", "REASON", "STATUS", "CREATED_AT"}
	rows := make([][]string, 0, len(reports))
	for _, r := range reports {
		reporter := ""
		if r.ReporterID != nil {
			reporter = *r.ReporterID
		}
		rows = append(rows, []string{
			fmt.Sprintf("%d", r.Priority),
			r.Category,
			r.ID,
			reporter,
			r.TargetType,
			r.TargetID,
			r.Reason,
			r.Status,
			fmtTimeVal(r.CreatedAt),
		})
	}
	return headers, rows
}
