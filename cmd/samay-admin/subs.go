package main

import (
	"fmt"

	"github.com/samay-app/samay/internal/db"
	"github.com/samay-app/samay/internal/format"
	"github.com/samay-app/samay/internal/ops"
	"github.com/spf13/cobra"
)

var subsCmd = &cobra.Command{
	Use:   "subs",
	Short: "Manage subscriptions",
	Long:  "List subscriptions and manage subscription overrides.",
}

var subsListCmd = &cobra.Command{
	Use:   "list",
	Short: "List subscriptions",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		tier, _ := cmd.Flags().GetString("tier")
		if tier != "" {
			if err := oneOf(tier, "free", "pro", "vip"); err != nil {
				return err
			}
		}
		expiringWithin, _ := cmd.Flags().GetInt("expiring-within")
		if expiringWithin < 0 {
			return fmt.Errorf("invalid --expiring-within %d: must be a non-negative integer", expiringWithin)
		}
		data, err := ops.ListSubs(dbClient, ops.ListSubsParams{
			Tier:           tier,
			ExpiringWithin: expiringWithin,
		})
		if err != nil {
			return err
		}
		format.Output(data, jsonFlag, subsTableBuilder)
		return nil
	},
}

var subsGetCmd = &cobra.Command{
	Use:   "get <user_id>",
	Short: "Show a user's subscription status",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, err := ops.GetSub(dbClient, args[0])
		if err != nil {
			return err
		}
		format.RenderJSON(data)
		return nil
	},
}

var subsOverrideCmd = &cobra.Command{
	Use:   "override <user_id>",
	Short: "Apply a subscription tier override",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		tier, _ := cmd.Flags().GetString("tier")
		if err := oneOf(tier, "pro", "vip"); err != nil {
			return err
		}
		expiresStr, _ := cmd.Flags().GetString("expires")
		expiresAt, err := parseDate(expiresStr)
		if err != nil {
			return err
		}
		reason, _ := cmd.Flags().GetString("reason")
		if err := ops.OverrideSub(dbClient, args[0], tier, adminUserID(), expiresAt, reason); err != nil {
			return err
		}
		fmt.Printf("override %s applied to %s until %s\n", tier, args[0], expiresAt.Format("2006-01-02"))
		return nil
	},
}

var subsRevokeCmd = &cobra.Command{
	Use:   "revoke <user_id>",
	Short: "Revoke all active overrides for a user",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		if err := ops.RevokeOverride(dbClient, args[0], adminUserID()); err != nil {
			return err
		}
		fmt.Printf("overrides revoked for %s\n", args[0])
		return nil
	},
}

func init() {
	subsListCmd.Flags().String("tier", "", "filter by tier (free|pro|vip)")
	subsListCmd.Flags().Int("expiring-within", 0, "only subscriptions expiring within N days")

	subsOverrideCmd.Flags().String("tier", "", "override tier (pro|vip) (required)")
	_ = subsOverrideCmd.MarkFlagRequired("tier")
	subsOverrideCmd.Flags().String("expires", "", "override expiry date YYYY-MM-DD (required)")
	_ = subsOverrideCmd.MarkFlagRequired("expires")
	subsOverrideCmd.Flags().String("reason", "", "reason for the override")

	subsCmd.AddCommand(subsListCmd, subsGetCmd, subsOverrideCmd, subsRevokeCmd)
}

func subsTableBuilder(data interface{}) ([]string, [][]string) {
	users := data.([]db.User)
	headers := []string{"ID", "USERNAME", "TIER", "EXPIRES_AT", "CREATED_AT"}
	rows := make([][]string, 0, len(users))
	for _, u := range users {
		rows = append(rows, []string{
			u.ID,
			deref(u.Username),
			u.SubscriptionTier,
			fmtTime(u.SubscriptionExpiresAt),
			fmtTimeVal(u.CreatedAt),
		})
	}
	return headers, rows
}
