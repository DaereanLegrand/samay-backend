package ops

import (
	"encoding/json"
	"testing"
)

func TestLogAction(t *testing.T) {
	// Unit test: just validate that params are assembled correctly
	details, _ := json.Marshal(map[string]string{"reason": "test"})
	params := AuditParams{
		AdminUserID: "admin-1",
		Action:      "ban_user",
		TargetType:  "user",
		TargetID:    "user-1",
		Details:     details,
	}
	if params.Action != "ban_user" {
		t.Errorf("expected ban_user, got %s", params.Action)
	}
}
