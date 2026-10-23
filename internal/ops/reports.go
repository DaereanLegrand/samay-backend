package ops

import (
	"context"
	"fmt"

	"github.com/samay-app/samay/internal/db"
)

const (
	defaultReportPageSize = 100
	maxReportPageSize     = 500
)

var reportCategories = []string{
	"csam", "credible_threat", "ncii", "harassment",
	"hate", "spam", "impersonation", "other",
}

type ListReportsParams struct {
	Status   string
	Type     string
	Category string
	Priority *int
	Limit    int
	Offset   int
}

func (p ListReportsParams) pageLimit() int {
	switch {
	case p.Limit <= 0:
		return defaultReportPageSize
	case p.Limit > maxReportPageSize:
		return maxReportPageSize
	default:
		return p.Limit
	}
}

func ListReports(ctx context.Context, client *db.DBClient, params ListReportsParams) ([]db.Report, error) {
	if params.Category != "" && !contains(reportCategories, params.Category) {
		return nil, fmt.Errorf("invalid category: %s: %w", params.Category, ErrInvalid)
	}
	qb := db.NewQueryBuilder().
		Select(
			"id", "reporter_id", "target_type", "target_id", "reason",
			"category", "priority", "status", "reviewed_at", "reviewed_by",
			"actioned_at", "actioned_by", "resolution_note", "reporter_outcome",
			"claimed_by", "claimed_at", "created_at", "updated_at",
		).
		Order("priority", true).
		Order("created_at", true).
		Limit(params.pageLimit()).
		Offset(max(params.Offset, 0))
	if params.Status != "" {
		qb.Eq("status", params.Status)
	}
	if params.Type != "" {
		qb.Eq("target_type", params.Type)
	}
	if params.Category != "" {
		qb.Eq("category", params.Category)
	}
	if params.Priority != nil {
		qb.Eq("priority", fmt.Sprintf("%d", *params.Priority))
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
	switch action {
	case "review", "remove", "dismiss", "warn":
	default:
		return fmt.Errorf("invalid action: %s: %w", action, ErrInvalid)
	}
	if _, err := client.RPC(ctx, "moderate_report", map[string]any{
		"p_report_id":     reportID,
		"p_action":        action,
		"p_admin_user_id": adminUserID,
	}); err != nil {
		return fmt.Errorf("action report: %w", err)
	}
	return nil
}

// ClaimReport records queue ownership and moves a pending report to reviewed.
func ClaimReport(ctx context.Context, client *db.DBClient, reportID, adminUserID string) error {
	if _, err := client.RPC(ctx, "claim_report", map[string]any{
		"p_report_id":     reportID,
		"p_admin_user_id": adminUserID,
	}); err != nil {
		return fmt.Errorf("claim report: %w", err)
	}
	return nil
}

// ListAppeals returns the owner-staffed appeal queue (oldest first so the SLA
// clock is respected).
func ListAppeals(ctx context.Context, client *db.DBClient, status string, limit, offset int) ([]db.Appeal, error) {
	if limit <= 0 {
		limit = defaultReportPageSize
	}
	if limit > maxReportPageSize {
		limit = maxReportPageSize
	}
	qb := db.NewQueryBuilder().
		Select(
			"id", "report_id", "appellant_id", "message", "status",
			"is_ban_appeal", "decision_note", "decided_by", "created_at",
			"decided_at", "updated_at",
		).
		Order("created_at", true).
		Limit(limit).
		Offset(max(offset, 0))
	if status != "" {
		qb.Eq("status", status)
	}
	return db.List[db.Appeal](ctx, client, "appeals", qb)
}

func GetAppeal(ctx context.Context, client *db.DBClient, appealID string) (*db.Appeal, error) {
	qb := db.NewQueryBuilder().Select("*")
	return db.GetByID[db.Appeal](ctx, client, "appeals", appealID, qb)
}

// DecideAppeal records the decision and, for an overturned ban appeal, lifts
// the ban through decide_appeal() server-side.
func DecideAppeal(ctx context.Context, client *db.DBClient, appealID, decision, note, adminUserID string) error {
	switch decision {
	case "upheld", "overturned", "closed":
	default:
		return fmt.Errorf("invalid decision: %s: %w", decision, ErrInvalid)
	}
	if _, err := client.RPC(ctx, "decide_appeal", map[string]any{
		"p_appeal_id":     appealID,
		"p_decision":      decision,
		"p_note":          note,
		"p_admin_user_id": adminUserID,
	}); err != nil {
		return fmt.Errorf("decide appeal: %w", err)
	}
	return nil
}

func contains(values []string, v string) bool {
	for _, candidate := range values {
		if candidate == v {
			return true
		}
	}
	return false
}
