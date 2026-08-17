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

var eventsCmd = &cobra.Command{
	Use:   "events",
	Short: "Manage events",
	Long:  "List, inspect, feature, cancel, and distribute shards for events.",
}

var eventsListCmd = &cobra.Command{
	Use:   "list",
	Short: "List events",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		status, _ := cmd.Flags().GetString("status")
		if status != "" {
			if err := validate.OneOf(status, "draft", "upcoming", "live", "ended", "cancelled"); err != nil {
				return err
			}
		}
		eventType, _ := cmd.Flags().GetString("type")
		if eventType != "" {
			if err := validate.OneOf(eventType, "casual", "juerga", "tono"); err != nil {
				return err
			}
		}
		promotor, _ := cmd.Flags().GetString("promotor")
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.ListEvents(ctx, dbClient, ops.ListEventsParams{
			Status:   status,
			Type:     eventType,
			Promotor: promotor,
		})
		if err != nil {
			return err
		}
		format.Output(data, jsonFlag, eventsTableBuilder)
		return nil
	},
}

var eventsGetCmd = &cobra.Command{
	Use:   "get <event_id>",
	Short: "Show full event details",
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

var eventsFeatureCmd = &cobra.Command{
	Use:   "feature <event_id>",
	Short: "Feature an event",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		expiresStr, _ := cmd.Flags().GetString("expires")
		expiresAt, err := validate.ParseDate(expiresStr)
		if err != nil {
			return err
		}
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.FeatureEvent(ctx, dbClient, args[0], expiresAt, adminUserID()); err != nil {
			return err
		}
		fmt.Printf("event %s featured until %s\n", args[0], expiresAt.Format("2006-01-02"))
		return nil
	},
}

var eventsUnfeatureCmd = &cobra.Command{
	Use:   "unfeature <event_id>",
	Short: "Remove feature status from an event",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.UnfeatureEvent(ctx, dbClient, args[0], adminUserID()); err != nil {
			return err
		}
		fmt.Printf("event %s unfeatured\n", args[0])
		return nil
	},
}

var eventsRejectFeatureCmd = &cobra.Command{
	Use:   "reject-feature <event_id>",
	Short: "Reject a pending feature request for an event",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.RejectFeatureEvent(ctx, dbClient, args[0], adminUserID()); err != nil {
			return err
		}
		fmt.Printf("feature request for event %s rejected\n", args[0])
		return nil
	},
}

var eventsCancelCmd = &cobra.Command{
	Use:   "cancel <event_id>",
	Short: "Cancel an event and return contributed preshards",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		reason, _ := cmd.Flags().GetString("reason")
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.CancelEvent(ctx, dbClient, args[0], reason, adminUserID()); err != nil {
			return err
		}
		fmt.Printf("event %s cancelled\n", args[0])
		return nil
	},
}

var eventsDistributeShardsCmd = &cobra.Command{
	Use:   "distribute-shards <event_id>",
	Short: "Manually trigger shard distribution for an event",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		confirm, _ := cmd.Flags().GetBool("confirm")
		if !confirm {
			return fmt.Errorf("refusing to distribute shards for event %s: pass --confirm to confirm", args[0])
		}
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.DistributeShards(ctx, dbClient, args[0], adminUserID()); err != nil {
			return err
		}
		fmt.Printf("shard distribution triggered for event %s\n", args[0])
		return nil
	},
}

func init() {
	eventsListCmd.Flags().String("status", "", "filter by status (draft|upcoming|live|ended|cancelled)")
	eventsListCmd.Flags().String("type", "", "filter by type (casual|juerga|tono)")
	eventsListCmd.Flags().String("promotor", "", "filter by promotor user_id")

	eventsFeatureCmd.Flags().String("expires", "", "feature expiry date YYYY-MM-DD (required)")
	_ = eventsFeatureCmd.MarkFlagRequired("expires")

	eventsCancelCmd.Flags().String("reason", "", "cancellation reason (required)")
	_ = eventsCancelCmd.MarkFlagRequired("reason")

	eventsDistributeShardsCmd.Flags().Bool("confirm", false, "confirm the distribution (required)")
	_ = eventsDistributeShardsCmd.MarkFlagRequired("confirm")

	eventsCmd.AddCommand(
		eventsListCmd,
		eventsGetCmd,
		eventsFeatureCmd,
		eventsUnfeatureCmd,
		eventsRejectFeatureCmd,
		eventsCancelCmd,
		eventsDistributeShardsCmd,
	)
}

func eventsTableBuilder(data any) ([]string, [][]string) {
	events := data.([]db.Event)
	headers := []string{"ID", "NAME", "TYPE", "STATUS", "STARTS_AT", "PROMOTOR", "POOL", "FEATURED"}
	rows := make([][]string, 0, len(events))
	for _, e := range events {
		rows = append(rows, []string{
			e.ID,
			e.Name,
			e.Type,
			e.Status,
			fmtTimeVal(e.StartsAt),
			e.CreatedByUserID,
			strconv.Itoa(e.PreshardsPool),
			boolStr(e.Featured, "yes", "no"),
		})
	}
	return headers, rows
}
