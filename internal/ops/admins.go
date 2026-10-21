package ops

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/samay-app/samay/internal/db"
	"github.com/samay-app/samay/internal/validate"
)

// AdminUser is a row from admin_users. Only the identity fields are needed to
// authorize a JWT subject and to resolve the operator behind the broken-glass
// CLI.
type AdminUser struct {
	ID          string    `json:"id"`
	Email       string    `json:"email"`
	DisplayName string    `json:"display_name"`
	Role        string    `json:"role"`
	CreatedAt   time.Time `json:"created_at"`
}

// GetAdmin resolves an admin_users row by id. A valid authenticated user that
// is absent from this table is not an admin; callers map ErrNotFound to 403.
func GetAdmin(ctx context.Context, client *db.DBClient, id string) (*AdminUser, error) {
	if err := validate.ParseUUID(id); err != nil {
		return nil, fmt.Errorf("get admin: %w", err)
	}
	body, err := client.Select(ctx, "admin_users", "id,email,display_name,role,created_at&id=eq."+id, 1, 0)
	if err != nil {
		return nil, fmt.Errorf("get admin: %w", err)
	}
	var rows []AdminUser
	if err := json.Unmarshal(body, &rows); err != nil {
		return nil, fmt.Errorf("get admin: unmarshal: %w", err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("get admin: %s: %w", id, ErrNotFound)
	}
	return &rows[0], nil
}
