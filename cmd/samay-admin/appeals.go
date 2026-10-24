package main

import (
	"fmt"

	"github.com/samay-app/samay/internal/db"
	"github.com/samay-app/samay/internal/format"
	"github.com/samay-app/samay/internal/ops"
	"github.com/samay-app/samay/internal/validate"
	"github.com/spf13/cobra"
)

var appealsCmd = &cobra.Command{
	Use:   "appeals",
	Short: "Review user appeals",
	Long:  "List, inspect and decide user appeals (ban appeals are owner-staffed).",
}

var appealsListCmd = &cobra.Command{
	Use:   "list",
	Short: "List appeals",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		status, _ := cmd.Flags().GetString("status")
		if status != "" {
			if err := validate.OneOf(status, "open", "reviewing", "upheld", "overturned", "closed"); err != nil {
				return err
			}
		}
		limit, _ := cmd.Flags().GetInt("limit")
		offset, _ := cmd.Flags().GetInt("offset")
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.ListAppeals(ctx, dbClient, status, limit, offset)
		if err != nil {
			return err
		}
		format.Output(data, jsonFlag, appealsTableBuilder)
		return nil
	},
}

var appealsGetCmd = &cobra.Command{
	Use:   "get <appeal_id>",
	Short: "Show an appeal",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.GetAppeal(ctx, dbClient, args[0])
		if err != nil {
			return err
		}
		format.RenderJSON(data)
		return nil
	},
}

var appealsDecideCmd = &cobra.Command{
	Use:   "decide <appeal_id>",
	Short: "Decide an appeal",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		decision, _ := cmd.Flags().GetString("decision")
		if err := validate.OneOf(decision, "upheld", "overturned", "closed"); err != nil {
			return err
		}
		note, _ := cmd.Flags().GetString("note")
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.DecideAppeal(ctx, dbClient, args[0], decision, note, adminUserID()); err != nil {
			return err
		}
		fmt.Printf("appeal %s decided: %s\n", args[0], decision)
		return nil
	},
}

func init() {
	appealsListCmd.Flags().String("status", "", "filter by status (open|reviewing|upheld|overturned|closed)")
	appealsListCmd.Flags().Int("limit", 100, "page size (max 500)")
	appealsListCmd.Flags().Int("offset", 0, "page offset")

	appealsDecideCmd.Flags().String("decision", "", "decision (upheld|overturned|closed) (required)")
	appealsDecideCmd.Flags().String("note", "", "decision note (stored in the audit log)")
	_ = appealsDecideCmd.MarkFlagRequired("decision")

	appealsCmd.AddCommand(appealsListCmd, appealsGetCmd, appealsDecideCmd)
}

func appealsTableBuilder(data any) ([]string, [][]string) {
	appeals := data.([]db.Appeal)
	headers := []string{"ID", "REPORT", "APPELLANT", "BAN", "STATUS", "CREATED_AT"}
	rows := make([][]string, 0, len(appeals))
	for _, a := range appeals {
		report := ""
		if a.ReportID != nil {
			report = *a.ReportID
		}
		appellant := ""
		if a.AppellantID != nil {
			appellant = *a.AppellantID
		}
		rows = append(rows, []string{
			a.ID,
			report,
			appellant,
			fmt.Sprintf("%t", a.IsBanAppeal),
			a.Status,
			fmtTimeVal(a.CreatedAt),
		})
	}
	return headers, rows
}
