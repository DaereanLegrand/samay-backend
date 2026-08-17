package main

import (
	"fmt"
	"strconv"

	"github.com/samay-app/samay/internal/db"
	"github.com/samay-app/samay/internal/format"
	"github.com/samay-app/samay/internal/ops"
	"github.com/samay-app/samay/internal/validate"
	"github.com/spf13/cobra"
)

var shardsCmd = &cobra.Command{
	Use:   "shards",
	Short: "Inspect and manage the shard economy",
	Long:  "Recalculate ranks and inspect shard ledgers.",
}

var shardsRecalculateRanksCmd = &cobra.Command{
	Use:   "recalculate-ranks",
	Short: "Manually trigger the daily rank recalculation",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		tier, _ := cmd.Flags().GetString("tier")
		if tier != "" {
			if err := validate.OneOf(tier, "micro", "small", "medium", "large"); err != nil {
				return err
			}
		}
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.RecalculateRanks(ctx, dbClient, tier); err != nil {
			return err
		}
		return nil
	},
}

var shardsLedgerCmd = &cobra.Command{
	Use:   "ledger <user_id>",
	Short: "Show a user's shard transaction history",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		limit, _ := cmd.Flags().GetInt("limit")
		if limit <= 0 {
			return fmt.Errorf("invalid --limit %d: must be a positive integer", limit)
		}
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.GetShardLedger(ctx, dbClient, args[0], limit)
		if err != nil {
			return err
		}
		format.Output(data, jsonFlag, shardLedgerTableBuilder)
		return nil
	},
}

var shardsGroupLedgerCmd = &cobra.Command{
	Use:   "group-ledger <group_id>",
	Short: "Show all shard contributions to a group",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.GetGroupShardLedger(ctx, dbClient, args[0])
		if err != nil {
			return err
		}
		format.Output(data, jsonFlag, groupShardLedgerTableBuilder)
		return nil
	},
}

var shardsEventSummaryCmd = &cobra.Command{
	Use:   "event-summary <event_id>",
	Short: "Show the shard distribution summary for an event",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.GetEvent(ctx, dbClient, args[0])
		if data != nil {
			format.RenderJSON(data)
		}
		if err != nil {
			return err
		}
		return nil
	},
}

func init() {
	shardsRecalculateRanksCmd.Flags().String("tier", "", "limit to a size tier (micro|small|medium|large)")

	shardsLedgerCmd.Flags().Int("limit", 50, "maximum number of entries")

	shardsCmd.AddCommand(
		shardsRecalculateRanksCmd,
		shardsLedgerCmd,
		shardsGroupLedgerCmd,
		shardsEventSummaryCmd,
	)
}

func shardLedgerTableBuilder(data any) ([]string, [][]string) {
	entries := data.([]db.ShardLedgerEntry)
	headers := []string{"ID", "DELTA", "REASON", "REFERENCE", "CREATED_AT"}
	rows := make([][]string, 0, len(entries))
	for _, e := range entries {
		rows = append(rows, []string{
			e.ID,
			strconv.Itoa(e.Delta),
			e.Reason,
			deref(e.ReferenceID),
			fmtTimeVal(e.CreatedAt),
		})
	}
	return headers, rows
}

func groupShardLedgerTableBuilder(data any) ([]string, [][]string) {
	entries := data.([]db.GroupShardContribution)
	headers := []string{"ID", "USER_ID", "SHARDS", "CONTRIBUTED_AT", "EXPIRES_AT"}
	rows := make([][]string, 0, len(entries))
	for _, e := range entries {
		rows = append(rows, []string{
			e.ID,
			e.UserID,
			strconv.Itoa(e.ShardsContributed),
			fmtTimeVal(e.ContributedAt),
			fmtTimeVal(e.ExpiresAt),
		})
	}
	return headers, rows
}
