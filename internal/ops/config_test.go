package ops

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/samay-app/samay/internal/db"
)

func TestListConfig_ReturnsRows(t *testing.T) {
	resp := `[{"key":"app.name","value":"Samay","description":"App name","default_value":"Samay"}]`
	client, srv, _ := newTestClientWithLog(resp, 200)
	defer srv.Close()

	rows, err := ListConfig(client)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	if rows[0].Key != "app.name" {
		t.Errorf("expected app.name, got %s", rows[0].Key)
	}
	if rows[0].Value != "Samay" {
		t.Errorf("expected Samay, got %s", rows[0].Value)
	}
}

func TestListConfig_InvalidJSON(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`bad data`, 200)
	defer srv.Close()

	_, err := ListConfig(client)

	if err == nil || !strings.Contains(err.Error(), "unmarshal") {
		t.Errorf("expected unmarshal error, got: %v", err)
	}
}

func TestGetConfig_ReturnsSingleRow(t *testing.T) {
	resp := `[{"key":"app.name","value":"Samay","description":"App name","default_value":"Samay"}]`
	client, srv, _ := newTestClientWithLog(resp, 200)
	defer srv.Close()

	row, err := GetConfig(client, "app.name")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if row.Key != "app.name" {
		t.Errorf("expected app.name, got %s", row.Key)
	}
}

func TestGetConfig_NotFound(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`[]`, 200)
	defer srv.Close()

	_, err := GetConfig(client, "nonexistent")

	if err == nil || !strings.Contains(err.Error(), "not found") {
		t.Errorf("expected 'not found' error, got: %v", err)
	}
}

func TestGetConfig_UsesKeyFilter(t *testing.T) {
	client, srv, log := newTestClientWithLog(`[{"key":"test.key","value":"x"}]`, 200)
	defer srv.Close()

	GetConfig(client, "test.key")

	req := (*log)[0]
	assertContains(t, req.Path, "/rest/v1/app_config")
	assertContains(t, req.Path, "key=eq.test.key")
}

func TestSetConfig_AuditsChange(t *testing.T) {
	getResp := `[{"key":"app.name","value":"Old","description":"","default_value":"Samay"}]`
	var calls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		calls++
		if strings.Contains(r.URL.Path, "app_config") && r.Method == "GET" {
			w.Write([]byte(getResp))
		} else {
			w.Write([]byte(`{}`))
		}
	}))
	defer srv.Close()
	client := &db.DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}

	err := SetConfig(client, "app.name", "New", "admin1")

	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if calls < 2 {
		t.Errorf("expected at least 2 requests (get + update), got %d", calls)
	}
}

func TestResetConfig_UsesDefaultValue(t *testing.T) {
	defaultVal := "Samay"
	description := "App name"
	configResp, _ := json.Marshal([]db.AppConfigRow{
		{Key: "app.name", Value: "Changed", Description: &description, DefaultValue: &defaultVal},
	})
	var updateCalled bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == "GET" {
			w.Write(configResp)
		} else {
			updateCalled = true
			w.Write([]byte(`{}`))
		}
	}))
	defer srv.Close()
	client := &db.DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}

	err := ResetConfig(client, "app.name", "admin1")

	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if !updateCalled {
		t.Error("expected PATCH request for config reset")
	}
}

func TestResetConfig_NoDefaultValue(t *testing.T) {
	resp, _ := json.Marshal([]db.AppConfigRow{
		{Key: "app.name", Value: "Samay", DefaultValue: nil},
	})
	client, srv, _ := newTestClientWithLog(string(resp), 200)
	defer srv.Close()

	err := ResetConfig(client, "app.name", "admin1")

	if err == nil || !strings.Contains(err.Error(), "no default value") {
		t.Errorf("expected 'no default value' error, got: %v", err)
	}
}

func TestGetConfig_SignupShards(t *testing.T) {
	resp := `[{"key":"economy.user_signup_shards","value":"256","description":"Signup shards","default_value":"256"}]`
	client, srv, _ := newTestClientWithLog(resp, 200)
	defer srv.Close()

	row, err := GetConfig(client, "economy.user_signup_shards")

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if row.Value != "256" {
		t.Errorf("expected 256, got %s", row.Value)
	}
}
