package ops

import (
	"context"
	"fmt"

	"github.com/samay-app/samay/internal/db"
)

type ListReportsParams struct {
	Status string
	Type   string
}

func ListReports(ctx context.Context, client *db.DBClient, params ListReportsParams) ([]db.Report, error) {
	qb := db.NewQueryBuilder().
		Select("id", "reporter_id", "target_type", "target_id", "reason", "status", "created_at").
		Limit(100)
	if params.Status != "" {
		qb.Eq("status", params.Status)
	}
	if params.Type != "" {
		qb.Eq("target_type", params.Type)
	}
	return db.List[db.Report](ctx, client, "reports", qb)
}

func GetReport(ctx context.Context, client *db.DBClient, reportID string) (*db.Report, error) {
	qb := db.NewQueryBuilder().Select("*")
	return db.GetByID[db.Report](ctx, client, "reports", reportID, qb)
}

// GetMessageReport returns the moderator-readable snapshot for a message
// report (226_chat_moderation). The plaintext is the exact content the
// reporter chose to disclose (end-to-end-encryption reporting exception).
func GetMessageReport(ctx context.Context, client *db.DBClient, reportID string) (*db.MessageReport, error) {
	qb := db.NewQueryBuilder().Select("*").Eq("report_id", reportID).Limit(1)
	rows, err := db.List[db.MessageReport](ctx, client, "message_reports", qb)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("message report not found: %s", reportID)
	}
	return &rows[0], nil
}

func ActionReport(ctx context.Context, client *db.DBClient, reportID, action, adminUserID string) error {
	var status string
	switch action {
	case "remove":
		status = "actioned"
	case "dismiss":
		status = "dismissed"
	case "warn":
		status = "actioned"
	default:
		return fmt.Errorf("invalid action: %s: %w", action, ErrInvalid)
	}
	_, err := client.Update(ctx, "reports", "id=eq."+reportID, map[string]any{
		"status": status,
	})
	if err != nil {
		return fmt.Errorf("action report: %w", err)
	}
	return LogAction(ctx, client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "report_" + action,
		TargetType:  "report",
		TargetID:    reportID,
	})
}
