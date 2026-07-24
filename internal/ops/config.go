package ops

import (
	"encoding/json"
	"fmt"

	"github.com/samay-app/samay/internal/db"
)

type ConfigRow struct {
	db.AppConfigRow
}

func ListConfig(client *db.DBClient) ([]ConfigRow, error) {
	body, err := client.Select("app_config", "key,value,description,default_value,updated_at", 100, 0)
	if err != nil {
		return nil, fmt.Errorf("list config: %w", err)
	}
	var rows []ConfigRow
	if err := json.Unmarshal(body, &rows); err != nil {
		return nil, fmt.Errorf("unmarshal config: %w", err)
	}
	return rows, nil
}

func GetConfig(client *db.DBClient, key string) (*ConfigRow, error) {
	body, err := client.Select("app_config", "key,value,description,default_value,updated_at&key=eq."+key, 1, 0)
	if err != nil {
		return nil, fmt.Errorf("get config: %w", err)
	}
	var rows []ConfigRow
	if err := json.Unmarshal(body, &rows); err != nil {
		return nil, fmt.Errorf("unmarshal config: %w", err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("config key not found: %s", key)
	}
	return &rows[0], nil
}

func SetConfig(client *db.DBClient, key, value, adminUserID string) error {
	current, _ := GetConfig(client, key)
	_, err := client.Update("app_config", "key=eq."+key, map[string]interface{}{
		"value": value,
	})
	if err != nil {
		return fmt.Errorf("set config: %w", err)
	}
	details, _ := json.Marshal(map[string]string{
		"before": current.Value,
		"after":  value,
	})
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "config_set",
		TargetType:  "config",
		TargetID:    key,
		Details:     details,
	})
}

func ResetConfig(client *db.DBClient, key, adminUserID string) error {
	current, err := GetConfig(client, key)
	if err != nil {
		return err
	}
	if current.DefaultValue == nil {
		return fmt.Errorf("config key %s has no default value", key)
	}
	_, err = client.Update("app_config", "key=eq."+key, map[string]interface{}{
		"value": *current.DefaultValue,
	})
	if err != nil {
		return fmt.Errorf("reset config: %w", err)
	}
	details, _ := json.Marshal(map[string]string{
		"before": current.Value,
		"after":  *current.DefaultValue,
	})
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "config_reset",
		TargetType:  "config",
		TargetID:    key,
		Details:     details,
	})
}
