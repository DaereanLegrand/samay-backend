package ops

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/samay-app/samay/internal/db"
)

func TestGetSystemStats_QueriesUsers(t *testing.T) {
	usersResp := `[{"id":"u1"}]`
	eventsResp := `[]`
	var usersCalled, eventsCalled bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.Contains(r.URL.Path, "users") {
			usersCalled = true
			w.Write([]byte(usersResp))
		} else if strings.Contains(r.URL.Path, "events") {
			eventsCalled = true
			w.Write([]byte(eventsResp))
		} else {
			w.Write([]byte(`[]`))
		}
	}))
	defer srv.Close()
	client := &db.DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}

	stats, err := GetSystemStats(client)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !usersCalled {
		t.Error("expected users table query")
	}
	if !eventsCalled {
		t.Error("expected events table query")
	}
	if stats.RegisteredUsers != 1 {
		t.Errorf("expected 1 registered user, got %d", stats.RegisteredUsers)
	}
}

func TestGetSystemStats_CountsEvents(t *testing.T) {
	usersResp := `[]`
	eventsResp := `[{"id":"e1"},{"id":"e2"},{"id":"e3"}]`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.Contains(r.URL.Path, "users") {
			w.Write([]byte(usersResp))
		} else {
			w.Write([]byte(eventsResp))
		}
	}))
	defer srv.Close()
	client := &db.DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}

	stats, err := GetSystemStats(client)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if stats.TotalEvents != 3 {
		t.Errorf("expected 3 events, got %d", stats.TotalEvents)
	}
}

func TestHealthCheck_ReturnsOk(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`[{"key":"app.name"}]`, 200)
	defer srv.Close()

	health, err := HealthCheck(client)

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if health.Status != "ok" {
		t.Errorf("expected ok, got %s", health.Status)
	}
	if health.DBConnected != true {
		t.Errorf("expected DBConnected=true, got %v", health.DBConnected)
	}
}

func TestHealthCheck_DegradedOnError(t *testing.T) {
	client, srv, _ := newTestClientWithLog(`error`, 500)
	defer srv.Close()

	health, err := HealthCheck(client)

	if err != nil {
		t.Fatalf("HealthCheck should not error even on DB failure: %v", err)
	}
	if health.Status != "degraded" {
		t.Errorf("expected degraded, got %s", health.Status)
	}
	if health.DBConnected != false {
		t.Errorf("expected DBConnected=false, got %v", health.DBConnected)
	}
	if health.APILatency == "" {
		t.Error("expected APILatency to be set")
	}
}

func TestCheckHTTP_ValidURL(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()

	err := CheckHTTP(srv.URL)

	if err != nil {
		t.Errorf("expected no error for valid URL, got: %v", err)
	}
}

func TestCheckHTTP_404URL(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(404)
	}))
	defer srv.Close()

	err := CheckHTTP(srv.URL)

	if err == nil {
		t.Error("expected error for 404")
	}
}

func TestCheckHTTP_Unreachable(t *testing.T) {
	err := CheckHTTP("http://127.0.0.1:1")

	if err == nil {
		t.Error("expected error for unreachable URL")
	}
}
