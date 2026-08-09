package db

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestClient(t *testing.T, handler http.HandlerFunc) (*DBClient, *httptest.Server) {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	return &DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}, srv
}

type requestLog struct {
	Method string
	Path   string
	Body   string
}

func newTestClientWithLog(t *testing.T, respBody string, status int) (*DBClient, *httptest.Server, *[]requestLog) {
	t.Helper()
	log := &[]requestLog{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		buf, _ := io.ReadAll(r.Body)
		*log = append(*log, requestLog{
			Method: r.Method,
			Path:   r.URL.RequestURI(),
			Body:   string(buf),
		})
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		w.Write([]byte(respBody))
	}))
	t.Cleanup(srv.Close)
	return &DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}, srv, log
}

func TestListParsesJSON(t *testing.T) {
	client, _, _ := newTestClientWithLog(t, `[{"id":"u1","username":"alice"}]`, 200)

	rows, err := List[User](context.Background(), client, "users",
		NewQueryBuilder().Select("id", "username").Limit(10))

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	if rows[0].ID != "u1" {
		t.Errorf("expected id u1, got %s", rows[0].ID)
	}
	if rows[0].Username == nil || *rows[0].Username != "alice" {
		t.Errorf("expected username alice, got %v", rows[0].Username)
	}
}

func TestListBuildsSelectLimitOffset(t *testing.T) {
	client, _, log := newTestClientWithLog(t, `[]`, 200)

	_, err := List[User](context.Background(), client, "users",
		NewQueryBuilder().Select("id", "username").Eq("status", "active").Limit(10).Offset(5))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	req := (*log)[0]
	if req.Method != "GET" {
		t.Errorf("expected GET, got %s", req.Method)
	}
	for _, want := range []string{
		"/rest/v1/users",
		"select=id,username",
		"status=eq.active",
		"limit=10",
		"offset=5",
	} {
		if !strings.Contains(req.Path, want) {
			t.Errorf("path %q missing %q", req.Path, want)
		}
	}
}

func TestListEscapesFilterValues(t *testing.T) {
	client, _, log := newTestClientWithLog(t, `[]`, 200)

	_, err := List[User](context.Background(), client, "users",
		NewQueryBuilder().Eq("username", "a&b=c d"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	req := (*log)[0]
	if !strings.Contains(req.Path, "username=eq.a%26b%3Dc%20d") {
		t.Errorf("expected escaped filter in path, got %q", req.Path)
	}
	if strings.Contains(req.Path, "a&b") {
		t.Errorf("raw ampersand leaked into path: %q", req.Path)
	}
}

func TestListInvalidJSON(t *testing.T) {
	client, _, _ := newTestClientWithLog(t, `not json`, 200)

	_, err := List[User](context.Background(), client, "users", NewQueryBuilder())
	if err == nil || !strings.Contains(err.Error(), "unmarshal") {
		t.Errorf("expected unmarshal error, got: %v", err)
	}
}

func TestGetByIDBuildsFilter(t *testing.T) {
	client, _, log := newTestClientWithLog(t, `[{"id":"u1","username":"bob"}]`, 200)

	row, err := GetByID[User](context.Background(), client, "users", "u1",
		NewQueryBuilder().Select("id", "username"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if row.ID != "u1" {
		t.Errorf("expected id u1, got %s", row.ID)
	}

	req := (*log)[0]
	for _, want := range []string{"id=eq.u1", "limit=1", "select=id,username"} {
		if !strings.Contains(req.Path, want) {
			t.Errorf("path %q missing %q", req.Path, want)
		}
	}
}

func TestGetByIDCombinesExtraFilters(t *testing.T) {
	client, _, log := newTestClientWithLog(t, `[{"id":"u1"}]`, 200)

	_, err := GetByID[User](context.Background(), client, "users", "u1",
		NewQueryBuilder().Eq("revoked", "false"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	req := (*log)[0]
	if !strings.Contains(req.Path, "revoked=eq.false") || !strings.Contains(req.Path, "id=eq.u1") {
		t.Errorf("expected both filters in path, got %q", req.Path)
	}
}

func TestGetByIDWithIdentityFilterInBuilder(t *testing.T) {
	client, _, log := newTestClientWithLog(t, `[{"key":"app.name","value":"Samay"}]`, 200)

	row, err := GetByID[AppConfigRow](context.Background(), client, "app_config", "",
		NewQueryBuilder().Eq("key", "app.name"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if row.Key != "app.name" {
		t.Errorf("expected app.name, got %s", row.Key)
	}

	req := (*log)[0]
	if !strings.Contains(req.Path, "key=eq.app.name") {
		t.Errorf("expected key filter in path, got %q", req.Path)
	}
}

func TestGetByIDNotFound(t *testing.T) {
	client, _, _ := newTestClientWithLog(t, `[]`, 200)

	_, err := GetByID[User](context.Background(), client, "users", "nope", NewQueryBuilder())
	if err == nil || !strings.Contains(err.Error(), "not found") {
		t.Errorf("expected not found error, got: %v", err)
	}
}

func TestInsertMarshalsBodyAndReturnsCreated(t *testing.T) {
	client, _, log := newTestClientWithLog(t, `{"id":"c1","key":"x","value":"y"}`, 201)
	row := AppConfigRow{Key: "x", Value: "y"}

	created, err := Insert[AppConfigRow](context.Background(), client, "app_config", row,
		NewQueryBuilder().Select("key", "value"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if created.Key != "x" || created.Value != "y" {
		t.Errorf("expected created row x/y, got %+v", created)
	}

	req := (*log)[0]
	if req.Method != "POST" {
		t.Errorf("expected POST, got %s", req.Method)
	}
	if !strings.Contains(req.Path, "/rest/v1/app_config") {
		t.Errorf("expected insert path, got %q", req.Path)
	}
	if !strings.Contains(req.Path, "select=key,value") {
		t.Errorf("expected select param from builder, got %q", req.Path)
	}
	var body map[string]string
	if err := json.Unmarshal([]byte(req.Body), &body); err != nil {
		t.Fatalf("body not valid JSON: %q: %v", req.Body, err)
	}
	if body["key"] != "x" || body["value"] != "y" {
		t.Errorf("expected marshaled body key=x value=y, got %v", body)
	}
}

func TestUpdateBuildsPathAndBody(t *testing.T) {
	client, _, log := newTestClientWithLog(t, `{}`, 200)

	err := Update(context.Background(), client, "users",
		NewQueryBuilder().Eq("id", "u1"), map[string]any{"banned_at": "now()"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	req := (*log)[0]
	if req.Method != "PATCH" {
		t.Errorf("expected PATCH, got %s", req.Method)
	}
	if !strings.Contains(req.Path, "/rest/v1/users") || !strings.Contains(req.Path, "id=eq.u1") {
		t.Errorf("expected update path with filter, got %q", req.Path)
	}
	var body map[string]any
	if err := json.Unmarshal([]byte(req.Body), &body); err != nil {
		t.Fatalf("body not valid JSON: %q: %v", req.Body, err)
	}
	if body["banned_at"] != "now()" {
		t.Errorf("expected patch body, got %v", body)
	}
}

func TestUpdateRefusesWithoutFilter(t *testing.T) {
	client, _, _ := newTestClientWithLog(t, `{}`, 200)

	err := Update(context.Background(), client, "users", NewQueryBuilder(), map[string]any{"x": "y"})
	if err == nil || !strings.Contains(err.Error(), "no filter") {
		t.Errorf("expected no-filter refusal, got: %v", err)
	}
}

func TestDeleteBuildsPath(t *testing.T) {
	client, _, log := newTestClientWithLog(t, `[]`, 200)

	err := Delete(context.Background(), client, "users", NewQueryBuilder().Eq("id", "u1"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	req := (*log)[0]
	if req.Method != "DELETE" {
		t.Errorf("expected DELETE, got %s", req.Method)
	}
	if !strings.Contains(req.Path, "/rest/v1/users") || !strings.Contains(req.Path, "id=eq.u1") {
		t.Errorf("expected delete path with filter, got %q", req.Path)
	}
}

func TestDeleteRefusesWithoutFilter(t *testing.T) {
	client, _, _ := newTestClientWithLog(t, `[]`, 200)

	err := Delete(context.Background(), client, "users", NewQueryBuilder())
	if err == nil || !strings.Contains(err.Error(), "no filter") {
		t.Errorf("expected no-filter refusal, got: %v", err)
	}
}
