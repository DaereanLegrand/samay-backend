package main

import (
	"fmt"
	"strconv"

	"github.com/samay-app/samay/internal/db"
	"github.com/samay-app/samay/internal/format"
	"github.com/samay-app/samay/internal/ops"
	"github.com/spf13/cobra"
)

var usersCmd = &cobra.Command{
	Use:   "users",
	Short: "Manage users",
	Long:  "List, inspect, ban, grant shards to, and delete users.",
}

var usersListCmd = &cobra.Command{
	Use:   "list",
	Short: "List users",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		search, _ := cmd.Flags().GetString("search")
		tier, _ := cmd.Flags().GetString("tier")
		if tier != "" {
			if err := oneOf(tier, "free", "pro", "vip"); err != nil {
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

var usersGrantShardsCmd = &cobra.Command{
	Use:   "grant-shards <user_id> <amount>",
	Short: "Grant personal shards to a user",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		confirm, _ := cmd.Flags().GetBool("confirm")
		if !confirm {
			return fmt.Errorf("refusing to grant shards: pass --confirm to confirm")
		}
		amount, err := parsePositiveInt(args[1])
		if err != nil {
			return err
		}
		reason, _ := cmd.Flags().GetString("reason")
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.GrantShards(ctx, dbClient, args[0], amount, reason, adminUserID()); err != nil {
			return err
		}
		fmt.Printf("granted %d shards to %s\n", amount, args[0])
		return nil
	},
}

var usersGrantPreshardsCmd = &cobra.Command{
	Use:   "grant-preshards <user_id> <amount>",
	Short: "Grant preshards to a user",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		confirm, _ := cmd.Flags().GetBool("confirm")
		if !confirm {
			return fmt.Errorf("refusing to grant preshards: pass --confirm to confirm")
		}
		amount, err := parsePositiveInt(args[1])
		if err != nil {
			return err
		}
		reason, _ := cmd.Flags().GetString("reason")
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.GrantPreshards(ctx, dbClient, args[0], amount, reason, adminUserID()); err != nil {
			return err
		}
		fmt.Printf("granted %d preshards to %s\n", amount, args[0])
		return nil
	},
}

var usersDeleteCmd = &cobra.Command{
	Use:   "delete <user_id>",
	Short: "Soft-delete a user account",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		confirm, _ := cmd.Flags().GetBool("confirm")
		if !confirm {
			return fmt.Errorf("refusing to delete user %s: pass --confirm to confirm", args[0])
		}
		if err := parseUUID(args[0]); err != nil {
			return err
		}
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.SoftDeleteUser(ctx, dbClient, args[0], adminUserID()); err != nil {
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

	usersGrantShardsCmd.Flags().String("reason", "admin_grant", "reason for the grant")
	usersGrantShardsCmd.Flags().Bool("confirm", false, "confirm the grant (required)")
	_ = usersGrantShardsCmd.MarkFlagRequired("confirm")

	usersGrantPreshardsCmd.Flags().String("reason", "admin_grant", "reason for the grant")
	usersGrantPreshardsCmd.Flags().Bool("confirm", false, "confirm the grant (required)")
	_ = usersGrantPreshardsCmd.MarkFlagRequired("confirm")

	usersDeleteCmd.Flags().Bool("confirm", false, "confirm the deletion (required)")
	_ = usersDeleteCmd.MarkFlagRequired("confirm")

	usersCmd.AddCommand(
		usersListCmd,
		usersGetCmd,
		usersBanCmd,
		usersUnbanCmd,
		usersGrantShardsCmd,
		usersGrantPreshardsCmd,
		usersDeleteCmd,
	)
}

func usersTableBuilder(data interface{}) ([]string, [][]string) {
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
