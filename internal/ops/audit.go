package ops

import (
	"encoding/json"

	"github.com/samay-app/samay/internal/db"
)

type AuditParams struct {
	AdminUserID string
	Action      string
	TargetType  string
	TargetID    string
	Details     json.RawMessage
}

func LogAction(client *db.DBClient, params AuditParams) error {
	_, err := client.Insert("admin_audit_log", map[string]interface{}{
		"admin_user_id": params.AdminUserID,
		"action":        params.Action,
		"target_type":   params.TargetType,
		"target_id":     params.TargetID,
		"details":       params.Details,
	})
	return err
}
