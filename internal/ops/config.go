package ops

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/samay-app/samay/internal/db"
)

type ConfigRow struct {
	db.AppConfigRow
}

func ListConfig(ctx context.Context, client *db.DBClient) ([]ConfigRow, error) {
	qb := db.NewQueryBuilder().
		Select("key", "value", "description", "default_value", "updated_at").
		Limit(100)
	rows, err := db.List[db.AppConfigRow](ctx, client, "app_config", qb)
	if err != nil {
		return nil, err
	}
	out := make([]ConfigRow, len(rows))
	for i := range rows {
		out[i] = ConfigRow{AppConfigRow: rows[i]}
	}
	return out, nil
}

func GetConfig(ctx context.Context, client *db.DBClient, key string) (*ConfigRow, error) {
	qb := db.NewQueryBuilder().
		Select("key", "value", "description", "default_value", "updated_at").
		Eq("key", key)
	row, err := db.GetByID[db.AppConfigRow](ctx, client, "app_config", "", qb)
	if err != nil {
		return nil, err
	}
	return &ConfigRow{AppConfigRow: *row}, nil
}

func SetConfig(ctx context.Context, client *db.DBClient, key, value, adminUserID string) error {
	current, err := GetConfig(ctx, client, key)
	if err != nil {
		// The update below is authoritative; an unreadable previous value
		// must not fail the whole operation NOR panic the audit log (it
		// previously dereferenced nil current.Value). Report it and proceed.
		fmt.Fprintf(os.Stderr, "set config: could not read current value for %s: %v\n", key, err)
	}
	var before string
	if current != nil {
		before = current.Value
	}
	if _, err := client.Update(ctx, "app_config", "key=eq."+key, map[string]interface{}{
		"value": value,
	}); err != nil {
		return fmt.Errorf("set config: %w", err)
	}
	details, err := json.Marshal(map[string]string{
		"before": before,
		"after":  value,
	})
	if err != nil {
		return fmt.Errorf("set config: marshal audit details: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "config_set",
		TargetType:  "config",
		TargetID:    key,
		Details:     details,
	})
}

func ResetConfig(ctx context.Context, client *db.DBClient, key, adminUserID string) error {
	current, err := GetConfig(ctx, client, key)
	if err != nil {
		return err
	}
	if current.DefaultValue == nil {
		return fmt.Errorf("config key %s has no default value", key)
	}
	if _, err = client.Update(ctx, "app_config", "key=eq."+key, map[string]interface{}{
		"value": *current.DefaultValue,
	}); err != nil {
		return fmt.Errorf("reset config: %w", err)
	}
	details, err := json.Marshal(map[string]string{
		"before": current.Value,
		"after":  *current.DefaultValue,
	})
	if err != nil {
		return fmt.Errorf("reset config: marshal audit details: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "config_reset",
		TargetType:  "config",
		TargetID:    key,
		Details:     details,
	})
}
