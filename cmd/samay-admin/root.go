package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/joho/godotenv"
	"github.com/samay-app/samay/internal/db"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var envKeys = []string{"SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_ADMIN_USER_ID"}

// commandTimeout caps every command's total runtime so a hung Supabase
// request cannot stall the CLI forever.
const commandTimeout = 30 * time.Second

var (
	jsonFlag     bool
	dbClient     *db.DBClient
	createClient = func() (*db.DBClient, error) {
		return db.NewDBClient()
	}
)

// rootCtx returns the context every command passes down to ops/db calls:
// a 30s deadline that is also cancelled on SIGINT/SIGTERM, so an operator
// can always interrupt a hung command.
func rootCtx() (context.Context, context.CancelFunc) {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	ctx, cancel := context.WithTimeout(ctx, commandTimeout)
	return ctx, func() {
		stop()
		cancel()
	}
}

var rootCmd = &cobra.Command{
	Use:          "samay",
	Short:        "Samay admin CLI",
	Long:         "Samay admin CLI — operational tool for Samay administrators.\nConnects to the Supabase backend via the service_role key.\nCommands are thin wrappers over internal/ops business logic.",
	Version:      "1.2.0",
	SilenceUsage: true,
	PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
		return initClient()
	},
}

func init() {
	cobra.OnInitialize(initConfig)
	rootCmd.PersistentFlags().BoolVar(&jsonFlag, "json", false, "output raw JSON instead of tables")
	rootCmd.AddCommand(
		usersCmd,
		eventsCmd,
		groupsCmd,
		reportsCmd,
		shardsCmd,
		configCmd,
		subsCmd,
		systemCmd,
		featureRequestsCmd,
	)
}

func initConfig() {
	_ = godotenv.Load("supabase/.env")
	for _, key := range envKeys {
		_ = viper.BindEnv(key)
	}
}

func validateEnv() error {
	var missing []string
	for _, key := range envKeys {
		if viper.GetString(key) == "" {
			missing = append(missing, key)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing required environment variable(s): %s", strings.Join(missing, ", "))
	}
	return nil
}

func initClient() error {
	if err := validateEnv(); err != nil {
		return err
	}
	client, err := createClient()
	if err != nil {
		return fmt.Errorf("initialize database client: %w", err)
	}
	dbClient = client
	return nil
}

func adminUserID() string {
	return viper.GetString("SUPABASE_ADMIN_USER_ID")
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func fmtTime(t *time.Time) string {
	if t == nil {
		return ""
	}
	return t.Format(time.RFC3339)
}

func fmtTimeVal(t time.Time) string {
	return t.Format(time.RFC3339)
}

func boolStr(b bool, yes, no string) string {
	if b {
		return yes
	}
	return no
}
