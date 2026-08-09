package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/samay-app/samay/internal/db"
)

const testAdminKey = "test-admin-key"

// stubDBClient returns a *db.DBClient backed by an httptest server, mirroring the
// internal/ops helpers_test pattern. The handler receives every PostgREST call.
func stubDBClient(t *testing.T, handler http.HandlerFunc) *db.DBClient {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	return &db.DBClient{BaseURL: srv.URL, ServiceKey: "test-key", HTTP: srv.Client()}
}

// jsonStub responds 200 with body to every request.
func jsonStub(body string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(body))
	}
}

// newTestRouter wires the production router with a stubbed DB client and a
// placeholder admin key.
func newTestRouter(t *testing.T, handler http.HandlerFunc) *gin.Engine {
	t.Helper()
	gin.SetMode(gin.TestMode)
	dbClient = stubDBClient(t, handler)
	return newRouter()
}

func doRequest(t *testing.T, r *gin.Engine, method, path string, auth string, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

func assertStatus(t *testing.T, w *httptest.ResponseRecorder, want int) {
	t.Helper()
	if w.Code != want {
		t.Errorf("expected status %d, got %d (body: %s)", want, w.Code, w.Body.String())
	}
}

func decodeJSON(t *testing.T, w *httptest.ResponseRecorder) map[string]interface{} {
	t.Helper()
	var body map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("expected JSON object body, got: %q", w.Body.String())
	}
	return body
}

func assertValidJSON(t *testing.T, w *httptest.ResponseRecorder) {
	t.Helper()
	if !json.Valid(w.Body.Bytes()) {
		t.Fatalf("expected valid JSON body, got: %q", w.Body.String())
	}
}

func TestHealthEndpoint_ReturnsOk(t *testing.T) {
	t.Setenv("ADMIN_API_KEY", testAdminKey)
	r := newTestRouter(t, jsonStub(`[{"key":"app.name"}]`))

	w := doRequest(t, r, http.MethodGet, "/api/v1/health", "", "")

	assertStatus(t, w, http.StatusOK)
	body := decodeJSON(t, w)
	if body["status"] != "ok" {
		t.Errorf("expected status ok, got %v", body["status"])
	}
	if body["db_connected"] != true {
		t.Errorf("expected db_connected true, got %v", body["db_connected"])
	}
	if _, ok := body["api_latency"]; !ok {
		t.Error("expected api_latency field")
	}
	if _, ok := body["version"]; !ok {
		t.Error("expected version field")
	}
}

func TestHealthEndpoint_DegradedWhenDBDown(t *testing.T) {
	t.Setenv("ADMIN_API_KEY", testAdminKey)
	r := newTestRouter(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("db down"))
	})

	w := doRequest(t, r, http.MethodGet, "/api/v1/health", "", "")

	assertStatus(t, w, http.StatusOK)
	body := decodeJSON(t, w)
	if body["status"] != "degraded" {
		t.Errorf("expected status degraded, got %v", body["status"])
	}
	if body["db_connected"] != false {
		t.Errorf("expected db_connected false, got %v", body["db_connected"])
	}
}

func TestAdminRoutes_RejectWithoutKey(t *testing.T) {
	t.Setenv("ADMIN_API_KEY", testAdminKey)
	r := newTestRouter(t, jsonStub(`[]`))

	cases := []struct {
		method string
		path   string
	}{
		{http.MethodGet, "/api/v1/admin/users"},
		{http.MethodGet, "/api/v1/admin/users/00000000-0000-0000-0000-000000000001"},
		{http.MethodPost, "/api/v1/admin/users/00000000-0000-0000-0000-000000000001/ban"},
		{http.MethodGet, "/api/v1/admin/events"},
		{http.MethodGet, "/api/v1/admin/groups"},
		{http.MethodGet, "/api/v1/admin/reports"},
		{http.MethodGet, "/api/v1/admin/config"},
		{http.MethodGet, "/api/v1/admin/subs"},
		{http.MethodGet, "/api/v1/admin/feature-requests"},
	}

	for _, tc := range cases {
		t.Run(tc.method+" "+tc.path, func(t *testing.T) {
			w := doRequest(t, r, tc.method, tc.path, "", "")
			assertStatus(t, w, http.StatusUnauthorized)
			body := decodeJSON(t, w)
			if body["error"] == nil {
				t.Error("expected error field in 401 body")
			}
		})
	}
}

func TestAdminRoutes_RejectWrongKey(t *testing.T) {
	t.Setenv("ADMIN_API_KEY", testAdminKey)
	r := newTestRouter(t, jsonStub(`[]`))

	w := doRequest(t, r, http.MethodGet, "/api/v1/admin/users", "Bearer wrong-key", "")

	assertStatus(t, w, http.StatusUnauthorized)
}

func TestAdminRoutes_RejectWhenKeyUnset(t *testing.T) {
	t.Setenv("ADMIN_API_KEY", "")
	r := newTestRouter(t, jsonStub(`[]`))

	w := doRequest(t, r, http.MethodGet, "/api/v1/admin/users", "Bearer "+testAdminKey, "")

	assertStatus(t, w, http.StatusUnauthorized)
}

func TestAdminListEndpoints_Return200WithKey(t *testing.T) {
	t.Setenv("ADMIN_API_KEY", testAdminKey)
	// Non-empty arrays so the :id detail routes resolve (not-found mapping is
	// covered by TestAdminOpsNotFound_Returns404).
	r := newTestRouter(t, jsonStub(`[{"id":"x"}]`))

	cases := []struct {
		method string
		path   string
	}{
		{http.MethodGet, "/api/v1/admin/users"},
		{http.MethodGet, "/api/v1/admin/users/00000000-0000-0000-0000-000000000001"},
		{http.MethodGet, "/api/v1/admin/events"},
		{http.MethodGet, "/api/v1/admin/events/00000000-0000-0000-0000-000000000002"},
		{http.MethodGet, "/api/v1/admin/groups"},
		{http.MethodGet, "/api/v1/admin/groups/00000000-0000-0000-0000-000000000003"},
		{http.MethodGet, "/api/v1/admin/groups/00000000-0000-0000-0000-000000000003/members"},
		{http.MethodGet, "/api/v1/admin/reports"},
		{http.MethodGet, "/api/v1/admin/reports/00000000-0000-0000-0000-000000000004"},
		{http.MethodGet, "/api/v1/admin/users/00000000-0000-0000-0000-000000000001/ledger"},
		{http.MethodGet, "/api/v1/admin/groups/00000000-0000-0000-0000-000000000003/ledger"},
		{http.MethodGet, "/api/v1/admin/config"},
		{http.MethodGet, "/api/v1/admin/config/some.key"},
		{http.MethodGet, "/api/v1/admin/subs"},
		{http.MethodGet, "/api/v1/admin/subs/00000000-0000-0000-0000-000000000001"},
		{http.MethodGet, "/api/v1/admin/feature-requests"},
	}

	for _, tc := range cases {
		t.Run(tc.method+" "+tc.path, func(t *testing.T) {
			w := doRequest(t, r, tc.method, tc.path, "Bearer "+testAdminKey, "")
			assertStatus(t, w, http.StatusOK)
			assertValidJSON(t, w)
		})
	}
}

// mutationStub is a path-aware stub: SetConfig's internal GetConfig lookup must
// find a row (internal/ops/config.go:50 ignores the lookup error and derefs the
// nil result — pre-existing GO-04-class bug, owned by I-39).
func mutationStub() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.Contains(r.URL.Path, "app_config") {
			w.Write([]byte(`[{"key":"feature.flag","value":"false"}]`))
			return
		}
		w.Write([]byte(`[{"id":"x"}]`))
	}
}

func TestAdminMutationEndpoints_Return200WithKey(t *testing.T) {
	t.Setenv("ADMIN_API_KEY", testAdminKey)
	r := newTestRouter(t, mutationStub())

	cases := []struct {
		path string
		body string
	}{
		{"/api/v1/admin/users/00000000-0000-0000-0000-000000000001/ban", `{"reason":"spam"}`},
		{"/api/v1/admin/users/00000000-0000-0000-0000-000000000001/unban", `{}`},
		{"/api/v1/admin/users/00000000-0000-0000-0000-000000000001/grant-shards", `{"amount":100,"reason":"admin_grant"}`},
		{"/api/v1/admin/users/00000000-0000-0000-0000-000000000001/grant-preshards", `{"amount":50,"reason":"admin_grant"}`},
		{"/api/v1/admin/users/00000000-0000-0000-0000-000000000001/delete", `{}`},
		{"/api/v1/admin/events/00000000-0000-0000-0000-000000000002/feature", `{"expires":"2026-09-01"}`},
		{"/api/v1/admin/events/00000000-0000-0000-0000-000000000002/unfeature", `{}`},
		{"/api/v1/admin/events/00000000-0000-0000-0000-000000000002/cancel", `{"reason":"postponed"}`},
		{"/api/v1/admin/events/00000000-0000-0000-0000-000000000002/distribute-shards", `{}`},
		{"/api/v1/admin/reports/00000000-0000-0000-0000-000000000004/action", `{"action":"remove"}`},
		{"/api/v1/admin/config/feature.flag", `{"value":"true"}`},
		{"/api/v1/admin/subs/00000000-0000-0000-0000-000000000001/override", `{"tier":"vip","expires":"2026-12-31","reason":"comp"}`},
		{"/api/v1/admin/subs/00000000-0000-0000-0000-000000000001/revoke", `{}`},
		{"/api/v1/admin/ranks/recalculate", `{}`},
	}

	for _, tc := range cases {
		t.Run(http.MethodPost+" "+tc.path, func(t *testing.T) {
			w := doRequest(t, r, http.MethodPost, tc.path, "Bearer "+testAdminKey, tc.body)
			assertStatus(t, w, http.StatusOK)
			decodeJSON(t, w)
		})
	}
}

func TestAdminValidationErrors_Return400(t *testing.T) {
	t.Setenv("ADMIN_API_KEY", testAdminKey)
	r := newTestRouter(t, jsonStub(`[]`))

	cases := []struct {
		path string
		body string
	}{
		{"/api/v1/admin/users/00000000-0000-0000-0000-000000000001/grant-shards", `{"amount":0}`},
		{"/api/v1/admin/users/00000000-0000-0000-0000-000000000001/grant-shards", `{"amount":"lots"}`},
		{"/api/v1/admin/events/00000000-0000-0000-0000-000000000002/feature", `{}`},
		{"/api/v1/admin/events/00000000-0000-0000-0000-000000000002/cancel", `{}`},
		{"/api/v1/admin/users/00000000-0000-0000-0000-000000000001/ban", `{}`},
		{"/api/v1/admin/reports/00000000-0000-0000-0000-000000000004/action", `{"action":"nuke"}`},
		{"/api/v1/admin/users/not-a-uuid/delete", `{}`},
		{"/api/v1/admin/subs/00000000-0000-0000-0000-000000000001/override", `{"tier":"gold"}`},
		{"/api/v1/admin/config/feature.flag", `not-json`},
	}

	for _, tc := range cases {
		t.Run(tc.path+" "+tc.body, func(t *testing.T) {
			w := doRequest(t, r, http.MethodPost, tc.path, "Bearer "+testAdminKey, tc.body)
			assertStatus(t, w, http.StatusBadRequest)
			decodeJSON(t, w)
		})
	}
}

func TestAdminOpsNotFound_Returns404(t *testing.T) {
	t.Setenv("ADMIN_API_KEY", testAdminKey)
	r := newTestRouter(t, jsonStub(`[]`))

	cases := []struct {
		method string
		path   string
	}{
		{http.MethodGet, "/api/v1/admin/users/00000000-0000-0000-0000-000000000001"},
		{http.MethodGet, "/api/v1/admin/events/00000000-0000-0000-0000-000000000002"},
		{http.MethodGet, "/api/v1/admin/groups/00000000-0000-0000-0000-000000000003"},
		{http.MethodGet, "/api/v1/admin/reports/00000000-0000-0000-0000-000000000004"},
		{http.MethodGet, "/api/v1/admin/config/missing.key"},
		{http.MethodGet, "/api/v1/admin/subs/00000000-0000-0000-0000-000000000001"},
	}

	for _, tc := range cases {
		t.Run(tc.method+" "+tc.path, func(t *testing.T) {
			w := doRequest(t, r, tc.method, tc.path, "Bearer "+testAdminKey, "")
			assertStatus(t, w, http.StatusNotFound)
			decodeJSON(t, w)
		})
	}
}

func TestAdminOpsError_ReturnsGeneric500(t *testing.T) {
	t.Setenv("ADMIN_API_KEY", testAdminKey)
	r := newTestRouter(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("supabase exploded"))
	})

	w := doRequest(t, r, http.MethodGet, "/api/v1/admin/users", "Bearer "+testAdminKey, "")

	assertStatus(t, w, http.StatusInternalServerError)
	body := decodeJSON(t, w)
	if body["error"] != "internal error" {
		t.Errorf("expected generic internal error, got %v", body["error"])
	}
	if strings.Contains(w.Body.String(), "supabase") {
		t.Error("500 response must not leak internals")
	}
}

func TestPromotorAndVenueNamespaces_Return501(t *testing.T) {
	t.Setenv("ADMIN_API_KEY", testAdminKey)
	r := newTestRouter(t, jsonStub(`[]`))

	cases := []struct {
		method string
		path   string
	}{
		{http.MethodGet, "/api/v1/promotor/events"},
		{http.MethodPost, "/api/v1/promotor/events"},
		{http.MethodGet, "/api/v1/promotor/paid-events/00000000-0000-0000-0000-000000000005"},
		{http.MethodGet, "/api/v1/venue/profile"},
		{http.MethodPost, "/api/v1/venue/checkin"},
	}

	for _, tc := range cases {
		t.Run(tc.method+" "+tc.path, func(t *testing.T) {
			w := doRequest(t, r, tc.method, tc.path, "", "")
			assertStatus(t, w, http.StatusNotImplemented)
			body := decodeJSON(t, w)
			if body["error"] == nil {
				t.Error("expected error field in 501 body")
			}
		})
	}
}

func TestUnknownRoute_Returns404JSON(t *testing.T) {
	t.Setenv("ADMIN_API_KEY", testAdminKey)
	r := newTestRouter(t, jsonStub(`[]`))

	w := doRequest(t, r, http.MethodGet, "/api/v1/nope", "", "")

	assertStatus(t, w, http.StatusNotFound)
	body := decodeJSON(t, w)
	if body["error"] != "not found" {
		t.Errorf("expected not found error, got %v", body["error"])
	}
}

func TestUnregisteredMethod_Returns405JSON(t *testing.T) {
	t.Setenv("ADMIN_API_KEY", testAdminKey)
	r := newTestRouter(t, jsonStub(`[]`))

	w := doRequest(t, r, http.MethodDelete, "/api/v1/admin/users", "Bearer "+testAdminKey, "")

	assertStatus(t, w, http.StatusMethodNotAllowed)
	decodeJSON(t, w)
}

func TestPanic_ReturnsGeneric500JSON(t *testing.T) {
	t.Setenv("ADMIN_API_KEY", testAdminKey)
	gin.SetMode(gin.TestMode)
	dbClient = stubDBClient(t, jsonStub(`[]`))
	r := newRouter()
	panicRoute := r.Group("/api/v1/admin")
	panicRoute.GET("/panic-test", func(c *gin.Context) {
		panic("boom")
	})

	w := doRequest(t, r, http.MethodGet, "/api/v1/admin/panic-test", "Bearer "+testAdminKey, "")

	assertStatus(t, w, http.StatusInternalServerError)
	body := decodeJSON(t, w)
	if body["error"] != "internal error" {
		t.Errorf("expected generic internal error, got %v", body["error"])
	}
}
