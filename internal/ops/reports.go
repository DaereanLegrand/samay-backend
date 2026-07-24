package ops

import (
	"encoding/json"
	"fmt"

	"github.com/samay-app/samay/internal/db"
)

type ListReportsParams struct {
	Status string
	Type   string
}

func ListReports(client *db.DBClient, params ListReportsParams) ([]db.Report, error) {
	q := "id,reporter_id,target_type,target_id,reason,status,created_at"
	if params.Status != "" {
		q += "&status=eq." + params.Status
	}
	if params.Type != "" {
		q += "&target_type=eq." + params.Type
	}
	body, err := client.Select("reports", q, 100, 0)
	if err != nil {
		return nil, fmt.Errorf("list reports: %w", err)
	}
	var reports []db.Report
	if err := json.Unmarshal(body, &reports); err != nil {
		return nil, fmt.Errorf("unmarshal reports: %w", err)
	}
	return reports, nil
}

func GetReport(client *db.DBClient, reportID string) (*db.Report, error) {
	body, err := client.Select("reports", "*&id=eq."+reportID, 1, 0)
	if err != nil {
		return nil, fmt.Errorf("get report: %w", err)
	}
	var reports []db.Report
	if err := json.Unmarshal(body, &reports); err != nil {
		return nil, fmt.Errorf("unmarshal report: %w", err)
	}
	if len(reports) == 0 {
		return nil, fmt.Errorf("report not found: %s", reportID)
	}
	return &reports[0], nil
}

func ActionReport(client *db.DBClient, reportID, action, adminUserID string) error {
	var status string
	switch action {
	case "remove":
		status = "actioned"
	case "dismiss":
		status = "dismissed"
	case "warn":
		status = "actioned"
	default:
		return fmt.Errorf("invalid action: %s", action)
	}
	_, err := client.Update("reports", "id=eq."+reportID, map[string]interface{}{
		"status": status,
	})
	if err != nil {
		return fmt.Errorf("action report: %w", err)
	}
	return LogAction(client, AuditParams{
		AdminUserID: adminUserID,
		Action:      "report_" + action,
		TargetType:  "report",
		TargetID:    reportID,
	})
}
