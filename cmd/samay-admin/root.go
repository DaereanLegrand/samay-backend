package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/joho/godotenv"
	"github.com/samay-app/samay/internal/db"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var envKeys = []string{"SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_ADMIN_USER_ID"}

var (
	jsonFlag     bool
	dbClient     *db.DBClient
	createClient = func() (*db.DBClient, error) {
		return db.NewDBClient(), nil
	}
)

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
	_ = godotenv.Load()
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

func oneOf(value string, allowed ...string) error {
	for _, a := range allowed {
		if value == a {
			return nil
		}
	}
	return fmt.Errorf("invalid value %q: must be one of %s", value, strings.Join(allowed, ", "))
}

func parseDate(s string) (time.Time, error) {
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		return time.Time{}, fmt.Errorf("invalid date %q: must be YYYY-MM-DD", s)
	}
	return t, nil
}

func parsePositiveInt(s string) (int, error) {
	n, err := strconv.Atoi(s)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("invalid amount %q: must be a positive integer", s)
	}
	return n, nil
}

func parseUUID(s string) error {
	if len(s) != 36 {
		return fmt.Errorf("invalid id %q: must be a UUID", s)
	}
	for i, r := range s {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if r != '-' {
				return fmt.Errorf("invalid id %q: must be a UUID", s)
			}
			continue
		}
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')) {
			return fmt.Errorf("invalid id %q: must be a UUID", s)
		}
	}
	return nil
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
