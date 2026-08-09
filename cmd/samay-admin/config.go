package main

import (
	"fmt"

	"github.com/samay-app/samay/internal/format"
	"github.com/samay-app/samay/internal/ops"
	"github.com/spf13/cobra"
)

var configCmd = &cobra.Command{
	Use:   "config",
	Short: "Manage runtime configuration",
	Long:  "Read and write keys in the app_config store.",
}

var configListCmd = &cobra.Command{
	Use:   "list",
	Short: "List all config keys",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.ListConfig(ctx, dbClient)
		if err != nil {
			return err
		}
		format.Output(data, jsonFlag, configTableBuilder)
		return nil
	},
}

var configGetCmd = &cobra.Command{
	Use:   "get <key>",
	Short: "Show a single config key",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		data, err := ops.GetConfig(ctx, dbClient, args[0])
		if err != nil {
			return err
		}
		format.RenderJSON(data)
		return nil
	},
}

var configSetCmd = &cobra.Command{
	Use:   "set <key> <value>",
	Short: "Update a config key",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		confirm, _ := cmd.Flags().GetBool("confirm")
		if !confirm {
			return fmt.Errorf("refusing to set config %s: pass --confirm to confirm", args[0])
		}
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.SetConfig(ctx, dbClient, args[0], args[1], adminUserID()); err != nil {
			return err
		}
		fmt.Printf("config %s set to %q\n", args[0], args[1])
		return nil
	},
}

var configResetCmd = &cobra.Command{
	Use:   "reset <key>",
	Short: "Revert a config key to its default value",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := rootCtx()
		defer cancel()
		if err := ops.ResetConfig(ctx, dbClient, args[0], adminUserID()); err != nil {
			return err
		}
		fmt.Printf("config %s reset to default\n", args[0])
		return nil
	},
}

func init() {
	configSetCmd.Flags().Bool("confirm", false, "confirm the update (required)")
	_ = configSetCmd.MarkFlagRequired("confirm")

	configCmd.AddCommand(configListCmd, configGetCmd, configSetCmd, configResetCmd)
}

func configTableBuilder(data interface{}) ([]string, [][]string) {
	rows := data.([]ops.ConfigRow)
	headers := []string{"KEY", "VALUE", "DEFAULT", "DESCRIPTION", "UPDATED_AT"}
	out := make([][]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, []string{
			r.Key,
			r.Value,
			deref(r.DefaultValue),
			deref(r.Description),
			fmtTimeVal(r.UpdatedAt),
		})
	}
	return headers, out
}
