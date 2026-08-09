package main

import (
	"strconv"

	"github.com/samay-app/samay/internal/db"
	"github.com/samay-app/samay/internal/format"
	"github.com/samay-app/samay/internal/ops"
	"github.com/spf13/cobra"
)

var groupsCmd = &cobra.Command{
	Use:   "groups",
	Short: "Inspect groups",
	Long:  "List groups, show group details, and list group members.",
}

var groupsListCmd = &cobra.Command{
	Use:   "list",
	Short: "List groups",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		tier, _ := cmd.Flags().GetString("tier")
		if tier != "" {
			if err := oneOf(tier, "micro", "small", "medium", "large"); err != nil {
				return err
			}
		}
		bracket, _ := cmd.Flags().GetString("bracket")
		if bracket != "" {
			if err := oneOf(bracket, "b0_20", "b20_40", "b40_60", "b60_80", "b80_90", "b90_100"); err != nil {
				return err
			}
		}
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.ListGroups(ctx, dbClient, ops.ListGroupsParams{
			SizeTier: tier,
			Bracket:  bracket,
		})
		if err != nil {
			return err
		}
		format.Output(data, jsonFlag, groupsTableBuilder)
		return nil
	},
}

var groupsGetCmd = &cobra.Command{
	Use:   "get <group_id>",
	Short: "Show group details",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.GetGroup(ctx, dbClient, args[0])
		if err != nil {
			return err
		}
		format.RenderJSON(data)
		return nil
	},
}

var groupsMembersCmd = &cobra.Command{
	Use:   "members <group_id>",
	Short: "List group members",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.ListGroupMembers(ctx, dbClient, args[0])
		if err != nil {
			return err
		}
		format.Output(data, jsonFlag, groupMembersTableBuilder)
		return nil
	},
}

func init() {
	groupsListCmd.Flags().String("tier", "", "filter by size tier (micro|small|medium|large)")
	groupsListCmd.Flags().String("bracket", "", "filter by rank bracket (b0_20|b20_40|b40_60|b60_80|b80_90|b90_100)")

	groupsCmd.AddCommand(groupsListCmd, groupsGetCmd, groupsMembersCmd)
}

func groupsTableBuilder(data interface{}) ([]string, [][]string) {
	groups := data.([]db.Group)
	headers := []string{"ID", "NAME", "SIZE_TIER", "BRACKET", "SHARDS", "CREATED_AT"}
	rows := make([][]string, 0, len(groups))
	for _, g := range groups {
		rows = append(rows, []string{
			g.ID,
			g.Name,
			deref(g.SizeTier),
			deref(g.RankBracket),
			strconv.Itoa(g.GroupShards),
			fmtTimeVal(g.CreatedAt),
		})
	}
	return headers, rows
}

func groupMembersTableBuilder(data interface{}) ([]string, [][]string) {
	members := data.([]db.GroupMember)
	headers := []string{"ID", "USER_ID", "ROLE", "STATUS", "JOINED_AT"}
	rows := make([][]string, 0, len(members))
	for _, m := range members {
		rows = append(rows, []string{
			m.ID,
			m.UserID,
			m.Role,
			m.Status,
			fmtTimeVal(m.JoinedAt),
		})
	}
	return headers, rows
}
