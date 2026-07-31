package main

import (
	"strconv"

	"github.com/samay-app/samay/internal/db"
	"github.com/samay-app/samay/internal/format"
	"github.com/samay-app/samay/internal/ops"
	"github.com/spf13/cobra"
)

var featureRequestsCmd = &cobra.Command{
	Use:   "feature-requests",
	Short: "Inspect feature requests",
	Long:  "List feature requests submitted by promotors.",
}

var featureRequestsListCmd = &cobra.Command{
	Use:   "list",
	Short: "List feature requests",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		status, _ := cmd.Flags().GetString("status")
		if status != "" {
			if err := oneOf(status, "pending", "approved", "rejected"); err != nil {
				return err
			}
		}
		data, err := ops.ListFeatureRequests(dbClient, ops.ListFeatureRequestsParams{Status: status})
		if err != nil {
			return err
		}
		format.Output(data, jsonFlag, featureRequestsTableBuilder)
		return nil
	},
}

func init() {
	featureRequestsListCmd.Flags().String("status", "", "filter by status (pending|approved|rejected)")
	featureRequestsCmd.AddCommand(featureRequestsListCmd)
}

func featureRequestsTableBuilder(data interface{}) ([]string, [][]string) {
	requests := data.([]db.FeatureRequest)
	headers := []string{"ID", "EVENT_ID", "REQUESTER", "DURATION_DAYS", "STATUS", "CREATED_AT"}
	rows := make([][]string, 0, len(requests))
	for _, r := range requests {
		rows = append(rows, []string{
			r.ID,
			r.EventID,
			r.RequestedByUserID,
			strconv.Itoa(r.DesiredDurationDays),
			r.Status,
			fmtTimeVal(r.CreatedAt),
		})
	}
	return headers, rows
}
