package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/samay-app/samay/internal/auth"
	"github.com/samay-app/samay/internal/db"
)

const (
	testJWTSecret = "test-jwt-secret"
	testAdminID   = "00000000-0000-4000-8000-0000000000aa"
	testUserID    = "11111111-1111-4111-8111-111111111111"
)

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

// withAdminLookup answers the admin_users resolution used by requireAdmin and
// delegates every other PostgREST call to next.
func withAdminLookup(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/rest/v1/admin_users") {
			w.Header().Set("Content-Type", "application/json")
			if strings.TrimPrefix(r.URL.Query().Get("id"), "eq.") == testAdminID {
				fmt.Fprintf(w, `[{"id":%q,"email":"admin@example.com","display_name":"Admin","role":"super_admin","created_at":"2026-01-01T00:00:00Z"}]`, testAdminID)
			} else {
				w.Write([]byte(`[]`))
			}
			return
		}
		next(w, r)
	}
}

func testVerifier(t *testing.T) *auth.Verifier {
	t.Helper()
	v, err := auth.NewVerifier(testJWTSecret)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	return v
}

// newTestRouter wires the production router with a stubbed DB client and the
// local test JWT verifier.
func newTestRouter(t *testing.T, handler http.HandlerFunc) *gin.Engine {
	t.Helper()
	gin.SetMode(gin.TestMode)
	dbClient = stubDBClient(t, withAdminLookup(handler))
	return newRouter(testVerifier(t))
}

func doRequest(t *testing.T, r *gin.Engine, method, path string, authz string, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if authz != "" {
		req.Header.Set("Authorization", authz)
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

func decodeJSON(t *testing.T, w *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var body map[string]any
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

func b64URL(data []byte) string {
	return base64.RawURLEncoding.EncodeToString(data)
}

func mintJWT(t *testing.T, claims map[string]any) string {
	t.Helper()
	header := map[string]any{"alg": "HS256", "typ": "JWT"}
	if len(claims) == 0 {
		claims = map[string]any{}
	}
	now := time.Now().Unix()
	if _, ok := claims["sub"]; !ok {
		claims["sub"] = testAdminID
	}
	if _, ok := claims["role"]; !ok {
		claims["role"] = "authenticated"
	}
	if _, ok := claims["aud"]; !ok {
		claims["aud"] = "authenticated"
	}
	if _, ok := claims["iat"]; !ok {
		claims["iat"] = now
	}
	if _, ok := claims["exp"]; !ok {
		claims["exp"] = now + 3600
	}

	headerJSON, _ := json.Marshal(header)
	payloadJSON, _ := json.Marshal(claims)
	signingInput := b64URL(headerJSON) + "." + b64URL(payloadJSON)
	mac := hmac.New(sha256.New, []byte(testJWTSecret))
	mac.Write([]byte(signingInput))
	return signingInput + "." + b64URL(mac.Sum(nil))
}

func adminBearer(t *testing.T) string {
	return "Bearer " + mintJWT(t, nil)
}

func TestHealthEndpoint_ReturnsOk(t *testing.T) {
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

func TestAdminRoutes_RejectWithoutToken(t *testing.T) {
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
		{http.MethodGet, "/api/v1/admin/appeals"},
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

func TestAdminRoutes_RejectInvalidTokens(t *testing.T) {
	r := newTestRouter(t, jsonStub(`[]`))
	now := time.Now().Unix()

	cases := []struct {
		name   string
		token  string
		status int
	}{
		{"garbage", "Bearer not-a-jwt", http.StatusUnauthorized},
		{"expired", "Bearer " + mintJWT(t, map[string]any{"exp": now - 60}), http.StatusUnauthorized},
		{"wrong audience", "Bearer " + mintJWT(t, map[string]any{"aud": "other"}), http.StatusUnauthorized},
		{"anon role", "Bearer " + mintJWT(t, map[string]any{"role": "anon"}), http.StatusUnauthorized},
		{"service role", "Bearer " + mintJWT(t, map[string]any{"role": "service_role"}), http.StatusUnauthorized},
		{"missing exp", "Bearer " + mintJWT(t, map[string]any{"exp": nil}), http.StatusUnauthorized},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := doRequest(t, r, http.MethodGet, "/api/v1/admin/config", tc.token, "")
			assertStatus(t, w, tc.status)
		})
	}
}

func TestAdminRoutes_RejectAlgNone(t *testing.T) {
	r := newTestRouter(t, jsonStub(`[]`))
	header := b64URL([]byte(`{"alg":"none","typ":"JWT"}`))
	payload := b64URL([]byte(fmt.Sprintf(`{"sub":%q,"role":"authenticated","aud":"authenticated","exp":%d}`, testAdminID, time.Now().Add(time.Hour).Unix())))

	w := doRequest(t, r, http.MethodGet, "/api/v1/admin/config", "Bearer "+header+"."+payload+".", "")

	assertStatus(t, w, http.StatusUnauthorized)
}

func TestAdminRoutes_RejectNonAdmin(t *testing.T) {
	r := newTestRouter(t, jsonStub(`[]`))
	token := mintJWT(t, map[string]any{"sub": testUserID})

	w := doRequest(t, r, http.MethodGet, "/api/v1/admin/config", "Bearer "+token, "")

	assertStatus(t, w, http.StatusForbidden)
}

func TestAdminRoutes_RejectNonUUIDSubject(t *testing.T) {
	r := newTestRouter(t, jsonStub(`[]`))
	token := mintJWT(t, map[string]any{"sub": "not-a-uuid"})

	w := doRequest(t, r, http.MethodGet, "/api/v1/admin/config", "Bearer "+token, "")

	assertStatus(t, w, http.StatusForbidden)
}

func TestAdminRoutes_RejectWhenVerifierMissing(t *testing.T) {
	gin.SetMode(gin.TestMode)
	dbClient = stubDBClient(t, withAdminLookup(jsonStub(`[]`)))
	r := newRouter(nil)

	w := doRequest(t, r, http.MethodGet, "/api/v1/admin/config", adminBearer(t), "")

	assertStatus(t, w, http.StatusUnauthorized)
}

func TestAdminListEndpoints_Return200WithAdminJWT(t *testing.T) {
	// Non-empty arrays so the :id detail routes resolve (not-found mapping is
	// covered by TestAdminOpsNotFound_Returns404).
	r := newTestRouter(t, jsonStub(`[{"id":"x"}]`))
	authz := adminBearer(t)

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
			w := doRequest(t, r, tc.method, tc.path, authz, "")
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

func TestAdminMutationEndpoints_Return200WithAdminJWT(t *testing.T) {
	r := newTestRouter(t, mutationStub())
	authz := adminBearer(t)

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
		{"/api/v1/admin/reports/00000000-0000-0000-0000-000000000004/claim", `{}`},
		{"/api/v1/admin/appeals/00000000-0000-0000-0000-000000000005/decision", `{"decision":"overturned","note":"ok"}`},
		{"/api/v1/admin/config/feature.flag", `{"value":"true"}`},
		{"/api/v1/admin/subs/00000000-0000-0000-0000-000000000001/override", `{"tier":"vip","expires":"2026-12-31","reason":"comp"}`},
		{"/api/v1/admin/subs/00000000-0000-0000-0000-000000000001/revoke", `{}`},
		{"/api/v1/admin/ranks/recalculate", `{}`},
	}

	for _, tc := range cases {
		t.Run(http.MethodPost+" "+tc.path, func(t *testing.T) {
			w := doRequest(t, r, http.MethodPost, tc.path, authz, tc.body)
			assertStatus(t, w, http.StatusOK)
			decodeJSON(t, w)
		})
	}
}

func TestAdminMutation_AuditUsesJWTSubject(t *testing.T) {
	var audit map[string]any
	handler := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.Contains(r.URL.Path, "admin_audit_log"):
			body, _ := io.ReadAll(r.Body)
			if err := json.Unmarshal(body, &audit); err != nil {
				t.Errorf("audit body is not JSON: %v", err)
			}
			w.Write([]byte(`[]`))
		case strings.Contains(r.URL.Path, "app_config"):
			w.Write([]byte(`[{"key":"feature.flag","value":"false"}]`))
		default:
			w.Write([]byte(`[{"id":"x"}]`))
		}
	}
	r := newTestRouter(t, handler)
	token := mintJWT(t, nil)

	w := doRequest(t, r, http.MethodPost, "/api/v1/admin/config/feature.flag", "Bearer "+token, `{"value":"false"}`)
	assertStatus(t, w, http.StatusOK)

	if got, _ := audit["admin_user_id"].(string); got != testAdminID {
		t.Fatalf("audit admin_user_id = %q, want JWT sub %q (row: %v)", got, testAdminID, audit)
	}
}

func TestAdminValidationErrors_Return400(t *testing.T) {
	r := newTestRouter(t, jsonStub(`[]`))
	authz := adminBearer(t)

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
		{"/api/v1/admin/appeals/00000000-0000-0000-0000-000000000005/decision", `{"decision":"nuke"}`},
		{"/api/v1/admin/users/not-a-uuid/delete", `{}`},
		{"/api/v1/admin/subs/00000000-0000-0000-0000-000000000001/override", `{"tier":"gold"}`},
		{"/api/v1/admin/config/feature.flag", `not-json`},
	}

	for _, tc := range cases {
		t.Run(tc.path+" "+tc.body, func(t *testing.T) {
			w := doRequest(t, r, http.MethodPost, tc.path, authz, tc.body)
			assertStatus(t, w, http.StatusBadRequest)
			decodeJSON(t, w)
		})
	}
}

func TestAdminOpsNotFound_Returns404(t *testing.T) {
	r := newTestRouter(t, jsonStub(`[]`))
	authz := adminBearer(t)

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
			w := doRequest(t, r, tc.method, tc.path, authz, "")
			assertStatus(t, w, http.StatusNotFound)
			decodeJSON(t, w)
		})
	}
}

func TestAdminOpsError_ReturnsGeneric500(t *testing.T) {
	r := newTestRouter(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("supabase exploded"))
	})

	w := doRequest(t, r, http.MethodGet, "/api/v1/admin/users", adminBearer(t), "")

	assertStatus(t, w, http.StatusInternalServerError)
	body := decodeJSON(t, w)
	if body["error"] != "internal error" {
		t.Errorf("expected generic internal error, got %v", body["error"])
	}
	if strings.Contains(w.Body.String(), "supabase") {
		t.Error("500 response must not leak internals")
	}
}

func TestAdminOversizedBody_Returns413(t *testing.T) {
	r := newTestRouter(t, jsonStub(`[]`))
	body := strings.Repeat("a", maxAdminBodyBytes+1)

	w := doRequest(t, r, http.MethodPost, "/api/v1/admin/config/feature.flag", adminBearer(t), body)

	assertStatus(t, w, http.StatusRequestEntityTooLarge)
}

func TestAdminChunkedOversizedBody_Returns413(t *testing.T) {
	r := newTestRouter(t, jsonStub(`[]`))
	body := `{"value":"` + strings.Repeat("a", maxAdminBodyBytes) + `"}`
	req := httptest.NewRequest(http.MethodPost, "/api/v1/admin/config/feature.flag", io.NopCloser(strings.NewReader(body)))
	req.ContentLength = -1
	req.Header.Set("Authorization", adminBearer(t))
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	assertStatus(t, w, http.StatusRequestEntityTooLarge)
}

func TestAdminRateLimit_PerIPReturns429(t *testing.T) {
	r := newTestRouter(t, jsonStub(`[]`))

	for i := 0; i <= ipBurst; i++ {
		w := doRequest(t, r, http.MethodGet, "/api/v1/admin/config", "", "")
		if i < ipBurst {
			assertStatus(t, w, http.StatusUnauthorized)
			continue
		}
		assertStatus(t, w, http.StatusTooManyRequests)
		if w.Header().Get("Retry-After") == "" {
			t.Error("429 must carry Retry-After")
		}
	}
}

func TestAdminRateLimit_PerAdminReturns429(t *testing.T) {
	r := newTestRouter(t, jsonStub(`[]`))
	authz := adminBearer(t)

	for i := 0; i <= adminBurst; i++ {
		w := doRequest(t, r, http.MethodGet, "/api/v1/admin/config", authz, "")
		if i < adminBurst {
			assertStatus(t, w, http.StatusOK)
			continue
		}
		assertStatus(t, w, http.StatusTooManyRequests)
		if w.Header().Get("Retry-After") == "" {
			t.Error("429 must carry Retry-After")
		}
	}
}

func TestHostAndVenueNamespaces_Return501(t *testing.T) {
	r := newTestRouter(t, jsonStub(`[]`))

	cases := []struct {
		method string
		path   string
	}{
		{http.MethodGet, "/api/v1/host/events"},
		{http.MethodPost, "/api/v1/host/events"},
		{http.MethodGet, "/api/v1/host/paid-events/00000000-0000-0000-0000-000000000005"},
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
	r := newTestRouter(t, jsonStub(`[]`))

	w := doRequest(t, r, http.MethodGet, "/api/v1/nope", "", "")

	assertStatus(t, w, http.StatusNotFound)
	body := decodeJSON(t, w)
	if body["error"] != "not found" {
		t.Errorf("expected not found error, got %v", body["error"])
	}
}

func TestUnregisteredMethod_Returns405JSON(t *testing.T) {
	r := newTestRouter(t, jsonStub(`[]`))

	w := doRequest(t, r, http.MethodDelete, "/api/v1/admin/users", adminBearer(t), "")

	assertStatus(t, w, http.StatusMethodNotAllowed)
	decodeJSON(t, w)
}

func TestPanic_ReturnsGeneric500JSON(t *testing.T) {
	gin.SetMode(gin.TestMode)
	dbClient = stubDBClient(t, withAdminLookup(jsonStub(`[]`)))
	r := newRouter(testVerifier(t))
	panicRoute := r.Group("/api/v1/admin")
	panicRoute.GET("/panic-test", func(c *gin.Context) {
		panic("boom")
	})

	w := doRequest(t, r, http.MethodGet, "/api/v1/admin/panic-test", adminBearer(t), "")

	assertStatus(t, w, http.StatusInternalServerError)
	body := decodeJSON(t, w)
	if body["error"] != "internal error" {
		t.Errorf("expected generic internal error, got %v", body["error"])
	}
}

// opsCtx must derive from the request context (a client disconnect cancels
// in-flight DB work) while applying the 30s cap.
func TestOpsCtx_DerivesFromRequestWithTimeout(t *testing.T) {
	gin.SetMode(gin.TestMode)
	reqCtx, reqCancel := context.WithCancel(context.Background())
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/", nil).WithContext(reqCtx)

	ctx := opsCtx(c)

	deadline, ok := ctx.Deadline()
	if !ok {
		t.Fatal("opsCtx context has no deadline (30s cap missing)")
	}
	if remaining := time.Until(deadline); remaining <= 0 || remaining > 31*time.Second {
		t.Fatalf("opsCtx deadline out of range: %s", remaining)
	}

	reqCancel()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("opsCtx context did not cancel when the request context cancelled")
	}
}
