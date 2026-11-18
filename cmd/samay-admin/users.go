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

var usersCmd = &cobra.Command{
	Use:   "users",
	Short: "Manage users",
	Long:  "List, inspect, ban, delete, and audit users.",
}

var usersListCmd = &cobra.Command{
	Use:   "list",
	Short: "List users",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		search, _ := cmd.Flags().GetString("search")
		tier, _ := cmd.Flags().GetString("tier")
		if tier != "" {
			if err := validate.OneOf(tier, "free", "pro", "vip"); err != nil {
				return err
			}
		}
		banned, _ := cmd.Flags().GetBool("banned")
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.ListUsers(ctx, dbClient, ops.ListUsersParams{
			Search: search,
			Tier:   tier,
			Banned: banned,
		})
		if err != nil {
			return err
		}
		format.Output(data, jsonFlag, usersTableBuilder)
		return nil
	},
}

var usersGetCmd = &cobra.Command{
	Use:   "get <user_id>",
	Short: "Show a full user profile",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.GetUser(ctx, dbClient, args[0])
		if data != nil {
			format.RenderJSON(data)
		}
		if err != nil {
			return err
		}
		return nil
	},
}

var usersBanCmd = &cobra.Command{
	Use:   "ban <user_id>",
	Short: "Ban a user",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		reason, _ := cmd.Flags().GetString("reason")
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.BanUser(ctx, dbClient, args[0], reason, adminUserID()); err != nil {
			return err
		}
		fmt.Printf("user %s banned\n", args[0])
		return nil
	},
}

var usersUnbanCmd = &cobra.Command{
	Use:   "unban <user_id>",
	Short: "Unban a user",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.UnbanUser(ctx, dbClient, args[0], adminUserID()); err != nil {
			return err
		}
		fmt.Printf("user %s unbanned\n", args[0])
		return nil
	},
}

var usersLedgerCmd = &cobra.Command{
	Use:   "ledger <user_id>",
	Short: "Show a user's shard transaction history (read-only; the economy is retired)",
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

var usersDeleteCmd = &cobra.Command{
	Use:   "delete <user_id>",
	Short: "Hard-delete a user account (Q1: no restore)",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		confirm, _ := cmd.Flags().GetBool("confirm")
		if !confirm {
			return fmt.Errorf("refusing to delete user %s: pass --confirm to confirm", args[0])
		}
		if err := validate.ParseUUID(args[0]); err != nil {
			return err
		}
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.DeleteUser(ctx, dbClient, args[0], adminUserID()); err != nil {
			return err
		}
		fmt.Printf("user %s deleted\n", args[0])
		return nil
	},
}

func init() {
	usersListCmd.Flags().String("search", "", "filter by username substring")
	usersListCmd.Flags().String("tier", "", "filter by subscription tier (free|pro|vip)")
	usersListCmd.Flags().Bool("banned", false, "only banned users")

	usersBanCmd.Flags().String("reason", "", "ban reason (required)")
	_ = usersBanCmd.MarkFlagRequired("reason")

	usersLedgerCmd.Flags().Int("limit", 50, "maximum number of entries")

	usersDeleteCmd.Flags().Bool("confirm", false, "confirm the deletion (required)")
	_ = usersDeleteCmd.MarkFlagRequired("confirm")

	usersCmd.AddCommand(
		usersListCmd,
		usersGetCmd,
		usersBanCmd,
		usersUnbanCmd,
		usersLedgerCmd,
		usersDeleteCmd,
	)
}

func usersTableBuilder(data any) ([]string, [][]string) {
	users := data.([]db.User)
	headers := []string{"ID", "USERNAME", "TIER", "SHARDS", "PRESHARDS", "CREATED_AT", "BANNED"}
	rows := make([][]string, 0, len(users))
	for _, u := range users {
		uid := u.ID
		if len(uid) > 8 {
			uid = uid[:8]
		}
		rows = append(rows, []string{
			uid,
			deref(u.Username),
			u.SubscriptionTier,
			strconv.Itoa(u.PersonalShards),
			strconv.Itoa(u.Preshards),
			fmtTimeVal(u.CreatedAt),
			boolStr(u.BannedAt != nil, "yes", "no"),
		})
	}
	return headers, rows
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
