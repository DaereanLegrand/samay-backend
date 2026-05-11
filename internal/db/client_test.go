package db

import (
	"testing"
)

func TestNewDBClient(t *testing.T) {
	t.Setenv("SUPABASE_URL", "http://localhost:54386")
	t.Setenv("SUPABASE_SERVICE_ROLE_KEY", "test-key")

	c := NewDBClient()
	if c.BaseURL != "http://localhost:54386" {
		t.Errorf("expected http://localhost:54386, got %s", c.BaseURL)
	}
	if c.ServiceKey != "test-key" {
		t.Errorf("expected test-key, got %s", c.ServiceKey)
	}
}
