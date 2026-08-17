package main

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"log"
	"net/http"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/samay-app/samay/internal/ops"
	"github.com/samay-app/samay/internal/validate"
	"github.com/spf13/viper"
)

// adminAPIKeyEnv is the placeholder admin gate. Real auth (Supabase JWKS
// verification + admin_users role check on the JWT subject) is S-06/M-21 scope;
// this env var only proves the surface before auth lands. Fails closed when unset.
const adminAPIKeyEnv = "ADMIN_API_KEY"

// apiBase is the versioned path prefix for all routes.
const apiBase = "/api/v1"

func newRouter() *gin.Engine {
	r := gin.New()
	r.HandleMethodNotAllowed = true
	r.Use(requestLogger(), recovery())
	r.NoRoute(notFound)
	r.NoMethod(notAllowed)

	r.GET(apiBase+"/health", healthHandler)

	admin := r.Group(apiBase+"/admin", requireAdmin())
	{
		// users
		admin.GET("/users", listUsersHandler)
		admin.GET("/users/:id", getUserHandler)
		admin.POST("/users/:id/ban", banUserHandler)
		admin.POST("/users/:id/unban", unbanUserHandler)
		admin.POST("/users/:id/grant-shards", grantShardsHandler)
		admin.POST("/users/:id/grant-preshards", grantPreshardsHandler)
		admin.POST("/users/:id/delete", deleteUserHandler)
		admin.GET("/users/:id/ledger", userLedgerHandler)

		// events
		admin.GET("/events", listEventsHandler)
		admin.GET("/events/:id", getEventHandler)
		admin.POST("/events/:id/feature", featureEventHandler)
		admin.POST("/events/:id/unfeature", unfeatureEventHandler)
		admin.POST("/events/:id/cancel", cancelEventHandler)
		admin.POST("/events/:id/distribute-shards", distributeShardsHandler)

		// groups
		admin.GET("/groups", listGroupsHandler)
		admin.GET("/groups/:id", getGroupHandler)
		admin.GET("/groups/:id/members", groupMembersHandler)
		admin.GET("/groups/:id/ledger", groupLedgerHandler)

		// reports
		admin.GET("/reports", listReportsHandler)
		admin.GET("/reports/:id", getReportHandler)
		admin.POST("/reports/:id/action", actionReportHandler)

		// shards
		admin.POST("/ranks/recalculate", recalculateRanksHandler)

		// config
		admin.GET("/config", listConfigHandler)
		admin.GET("/config/:key", getConfigHandler)
		admin.POST("/config/:key", setConfigHandler)

		// subs
		admin.GET("/subs", listSubsHandler)
		admin.GET("/subs/:id", getSubHandler)
		admin.POST("/subs/:id/override", overrideSubHandler)
		admin.POST("/subs/:id/revoke", revokeOverrideHandler)

		// feature requests
		admin.GET("/feature-requests", listFeatureRequestsHandler)
	}

	// Post-MVP namespaces (spec §2/§3): the surface exists so the API contract is
	// complete; the actual handlers land with the promotor/venue phases.
	r.Any(apiBase+"/promotor/*any", notImplemented)
	r.Any(apiBase+"/venue/*any", notImplemented)

	return r
}

// ── middleware ────────────────────────────────────────────────────────────────

// requestLogger logs method, path and status per request. Deliberately no query
// string, headers or body — no PII, no secrets.
func requestLogger() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		log.Printf("%s %s -> %d (%s)", c.Request.Method, c.Request.URL.Path, c.Writer.Status(), time.Since(start).Round(time.Millisecond))
	}
}

// recovery converts panics into generic JSON 500s and logs the stack server-side.
func recovery() gin.HandlerFunc {
	return func(c *gin.Context) {
		defer func() {
			if rec := recover(); rec != nil {
				log.Printf("panic: %v\n%s", rec, debug.Stack())
				c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
			}
		}()
		c.Next()
	}
}

// requireAdmin is the placeholder admin gate. It compares the Authorization
// bearer token against ADMIN_API_KEY using a constant-time compare. JWT/JWKS
// verification (S-06) and admin_users role resolution (M-21) replace this body.
func requireAdmin() gin.HandlerFunc {
	expected := viper.GetString(adminAPIKeyEnv)
	if expected == "" {
		log.Printf("WARNING: %s unset — admin routes fail closed (401). Set a placeholder key for local testing; real JWT auth lands with S-06/M-21.", adminAPIKeyEnv)
	}
	return func(c *gin.Context) {
		token, ok := strings.CutPrefix(c.GetHeader("Authorization"), "Bearer ")
		if !ok || expected == "" || subtle.ConstantTimeCompare([]byte(token), []byte(expected)) != 1 {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
			return
		}
		c.Next()
	}
}

func notFound(c *gin.Context) {
	c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
}

func notAllowed(c *gin.Context) {
	c.JSON(http.StatusMethodNotAllowed, gin.H{"error": "method not allowed"})
}

func notImplemented(c *gin.Context) {
	c.JSON(http.StatusNotImplemented, gin.H{"error": "not implemented"})
}

// ── response/error helpers ────────────────────────────────────────────────────

// opsCtx returns the context passed to internal/ops calls. The ops layer threads
// ctx through the DB client (I-39/I-40 migration); handlers use a background
// context today — S-06/M-21 may switch this to the request context.
func opsCtx() context.Context {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	_ = cancel // timeout fires if handler doesn't finish; no leak since background
	return ctx
}

// writeError maps ops errors to JSON responses: validation → 400, not-found →
// 404, anything else → 500 with a generic body (internals stay server-side).
func writeError(c *gin.Context, err error) {
	status := http.StatusInternalServerError
	msg := err.Error()
	switch {
	case errors.Is(err, ops.ErrNotFound):
		status = http.StatusNotFound
	case errors.Is(err, ops.ErrInvalid):
		status = http.StatusBadRequest
	case errors.Is(err, ops.ErrUnauthorized):
		status = http.StatusUnauthorized
	case strings.Contains(msg, "not found"):
		status = http.StatusNotFound
	case strings.Contains(msg, "invalid"):
		status = http.StatusBadRequest
	}
	if status == http.StatusInternalServerError {
		log.Printf("api error: %v", err)
		msg = "internal error"
	}
	c.JSON(status, gin.H{"error": msg})
}

// bindJSON decodes the request body into dst or aborts with 400.
func bindJSON(c *gin.Context, dst any) bool {
	if err := c.ShouldBindJSON(dst); err != nil {
		writeError(c, fmt.Errorf("invalid request body: %w", err))
		return false
	}
	return true
}

func ok(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// queryLimit parses the ?limit= query param, defaulting to 50.
func queryLimit(c *gin.Context) (int, error) {
	raw := c.Query("limit")
	if raw == "" {
		return 50, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("invalid limit %q: must be a positive integer", raw)
	}
	return n, nil
}

func queryBool(c *gin.Context, key string) (bool, error) {
	raw := c.Query(key)
	if raw == "" {
		return false, nil
	}
	b, err := strconv.ParseBool(raw)
	if err != nil {
		return false, fmt.Errorf("invalid %s %q: must be true or false", key, raw)
	}
	return b, nil
}

// ── request bodies ─────────────────────────────────────────────────────────────

type grantRequest struct {
	Amount int    `json:"amount"`
	Reason string `json:"reason"`
}

type featureRequest struct {
	Expires string `json:"expires"`
}

type cancelRequest struct {
	Reason string `json:"reason"`
}

type banRequest struct {
	Reason string `json:"reason"`
}

type reportActionRequest struct {
	Action string `json:"action"`
}

type setConfigRequest struct {
	Value string `json:"value"`
}

type overrideRequest struct {
	Tier    string `json:"tier"`
	Expires string `json:"expires"`
	Reason  string `json:"reason"`
}

type recalcRequest struct {
	Tier string `json:"tier"`
}

// ── handlers: health ──────────────────────────────────────────────────────────

func healthHandler(c *gin.Context) {
	health, err := ops.HealthCheck(opsCtx(), dbClient)
	if err != nil {
		log.Printf("health check error: %v", err)
		status, latency := "degraded", "0s"
		if health != nil {
			status, latency = health.Status, health.APILatency
		}
		c.JSON(http.StatusOK, gin.H{
			"status":       status,
			"api_latency":  latency,
			"db_connected": false,
			"version":      serverVersion,
		})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"status":       health.Status,
		"api_latency":  health.APILatency,
		"db_connected": health.DBConnected,
		"version":      serverVersion,
	})
}

// ── handlers: users ───────────────────────────────────────────────────────────

func listUsersHandler(c *gin.Context) {
	tier := c.Query("tier")
	if tier != "" {
		if err := validate.OneOf(tier, "free", "pro", "vip"); err != nil {
			writeError(c, err)
			return
		}
	}
	banned, err := queryBool(c, "banned")
	if err != nil {
		writeError(c, err)
		return
	}
	data, err := ops.ListUsers(opsCtx(), dbClient, ops.ListUsersParams{
		Search: c.Query("search"),
		Tier:   tier,
		Banned: banned,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func getUserHandler(c *gin.Context) {
	data, err := ops.GetUser(opsCtx(), dbClient, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func banUserHandler(c *gin.Context) {
	var req banRequest
	if !bindJSON(c, &req) {
		return
	}
	if req.Reason == "" {
		writeError(c, fmt.Errorf("invalid request: reason is required"))
		return
	}
	if err := ops.BanUser(opsCtx(), dbClient, c.Param("id"), req.Reason, adminIdentity()); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func unbanUserHandler(c *gin.Context) {
	if err := ops.UnbanUser(opsCtx(), dbClient, c.Param("id"), adminIdentity()); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func grantShardsHandler(c *gin.Context) {
	var req grantRequest
	if !bindJSON(c, &req) {
		return
	}
	if req.Amount <= 0 {
		writeError(c, fmt.Errorf("invalid amount %d: must be a positive integer", req.Amount))
		return
	}
	reason := req.Reason
	if reason == "" {
		reason = "admin_grant"
	}
	if err := ops.GrantShards(opsCtx(), dbClient, c.Param("id"), req.Amount, reason, adminIdentity()); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func grantPreshardsHandler(c *gin.Context) {
	var req grantRequest
	if !bindJSON(c, &req) {
		return
	}
	if req.Amount <= 0 {
		writeError(c, fmt.Errorf("invalid amount %d: must be a positive integer", req.Amount))
		return
	}
	reason := req.Reason
	if reason == "" {
		reason = "admin_grant"
	}
	if err := ops.GrantPreshards(opsCtx(), dbClient, c.Param("id"), req.Amount, reason, adminIdentity()); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func deleteUserHandler(c *gin.Context) {
	id := c.Param("id")
	if err := validate.ParseUUID(id); err != nil {
		writeError(c, err)
		return
	}
	if err := ops.SoftDeleteUser(opsCtx(), dbClient, id, adminIdentity()); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func userLedgerHandler(c *gin.Context) {
	limit, err := queryLimit(c)
	if err != nil {
		writeError(c, err)
		return
	}
	data, err := ops.GetShardLedger(opsCtx(), dbClient, c.Param("id"), limit)
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

// ── handlers: events ──────────────────────────────────────────────────────────

func listEventsHandler(c *gin.Context) {
	status := c.Query("status")
	if status != "" {
		if err := validate.OneOf(status, "draft", "upcoming", "live", "ended", "cancelled"); err != nil {
			writeError(c, err)
			return
		}
	}
	eventType := c.Query("type")
	if eventType != "" {
		if err := validate.OneOf(eventType, "casual", "juerga", "tono"); err != nil {
			writeError(c, err)
			return
		}
	}
	data, err := ops.ListEvents(opsCtx(), dbClient, ops.ListEventsParams{
		Status:   status,
		Type:     eventType,
		Promotor: c.Query("promotor"),
	})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func getEventHandler(c *gin.Context) {
	data, err := ops.GetEvent(opsCtx(), dbClient, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func featureEventHandler(c *gin.Context) {
	var req featureRequest
	if !bindJSON(c, &req) {
		return
	}
	expiresAt, err := validate.ParseDate(req.Expires)
	if err != nil {
		writeError(c, err)
		return
	}
	if err := ops.FeatureEvent(opsCtx(), dbClient, c.Param("id"), expiresAt, adminIdentity()); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func unfeatureEventHandler(c *gin.Context) {
	if err := ops.UnfeatureEvent(opsCtx(), dbClient, c.Param("id"), adminIdentity()); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func cancelEventHandler(c *gin.Context) {
	var req cancelRequest
	if !bindJSON(c, &req) {
		return
	}
	if req.Reason == "" {
		writeError(c, fmt.Errorf("invalid request: reason is required"))
		return
	}
	if err := ops.CancelEvent(opsCtx(), dbClient, c.Param("id"), req.Reason, adminIdentity()); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func distributeShardsHandler(c *gin.Context) {
	if err := ops.DistributeShards(opsCtx(), dbClient, c.Param("id"), adminIdentity()); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

// ── handlers: groups ──────────────────────────────────────────────────────────

func listGroupsHandler(c *gin.Context) {
	tier := c.Query("tier")
	if tier != "" {
		if err := validate.OneOf(tier, "micro", "small", "medium", "large"); err != nil {
			writeError(c, err)
			return
		}
	}
	bracket := c.Query("bracket")
	if bracket != "" {
		if err := validate.OneOf(bracket, "b0_20", "b20_40", "b40_60", "b60_80", "b80_90", "b90_100"); err != nil {
			writeError(c, err)
			return
		}
	}
	data, err := ops.ListGroups(opsCtx(), dbClient, ops.ListGroupsParams{
		SizeTier: tier,
		Bracket:  bracket,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func getGroupHandler(c *gin.Context) {
	data, err := ops.GetGroup(opsCtx(), dbClient, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func groupMembersHandler(c *gin.Context) {
	data, err := ops.ListGroupMembers(opsCtx(), dbClient, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func groupLedgerHandler(c *gin.Context) {
	data, err := ops.GetGroupShardLedger(opsCtx(), dbClient, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

// ── handlers: reports ─────────────────────────────────────────────────────────

func listReportsHandler(c *gin.Context) {
	status := c.Query("status")
	if status != "" {
		if err := validate.OneOf(status, "pending", "reviewed", "actioned", "dismissed"); err != nil {
			writeError(c, err)
			return
		}
	}
	targetType := c.Query("type")
	if targetType != "" {
		if err := validate.OneOf(targetType, "message", "photo", "user", "event"); err != nil {
			writeError(c, err)
			return
		}
	}
	data, err := ops.ListReports(opsCtx(), dbClient, ops.ListReportsParams{
		Status: status,
		Type:   targetType,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func getReportHandler(c *gin.Context) {
	data, err := ops.GetReport(opsCtx(), dbClient, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func actionReportHandler(c *gin.Context) {
	var req reportActionRequest
	if !bindJSON(c, &req) {
		return
	}
	if err := validate.OneOf(req.Action, "remove", "dismiss", "warn"); err != nil {
		writeError(c, err)
		return
	}
	if err := ops.ActionReport(opsCtx(), dbClient, c.Param("id"), req.Action, adminIdentity()); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

// ── handlers: shards ──────────────────────────────────────────────────────────

func recalculateRanksHandler(c *gin.Context) {
	var req recalcRequest
	if !bindJSON(c, &req) {
		return
	}
	if req.Tier != "" {
		if err := validate.OneOf(req.Tier, "micro", "small", "medium", "large"); err != nil {
			writeError(c, err)
			return
		}
	}
	if err := ops.RecalculateRanks(opsCtx(), dbClient, req.Tier); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

// ── handlers: config ──────────────────────────────────────────────────────────

func listConfigHandler(c *gin.Context) {
	data, err := ops.ListConfig(opsCtx(), dbClient)
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func getConfigHandler(c *gin.Context) {
	data, err := ops.GetConfig(opsCtx(), dbClient, c.Param("key"))
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func setConfigHandler(c *gin.Context) {
	var req setConfigRequest
	if !bindJSON(c, &req) {
		return
	}
	if err := ops.SetConfig(opsCtx(), dbClient, c.Param("key"), req.Value, adminIdentity()); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

// ── handlers: subs ────────────────────────────────────────────────────────────

func listSubsHandler(c *gin.Context) {
	tier := c.Query("tier")
	if tier != "" {
		if err := validate.OneOf(tier, "free", "pro", "vip"); err != nil {
			writeError(c, err)
			return
		}
	}
	data, err := ops.ListSubs(opsCtx(), dbClient, ops.ListSubsParams{Tier: tier})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func getSubHandler(c *gin.Context) {
	data, err := ops.GetSub(opsCtx(), dbClient, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func overrideSubHandler(c *gin.Context) {
	var req overrideRequest
	if !bindJSON(c, &req) {
		return
	}
	if err := validate.OneOf(req.Tier, "pro", "vip"); err != nil {
		writeError(c, err)
		return
	}
	expiresAt, err := validate.ParseDate(req.Expires)
	if err != nil {
		writeError(c, err)
		return
	}
	if err := ops.OverrideSub(opsCtx(), dbClient, c.Param("id"), req.Tier, adminIdentity(), expiresAt, req.Reason); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func revokeOverrideHandler(c *gin.Context) {
	if err := ops.RevokeOverride(opsCtx(), dbClient, c.Param("id"), adminIdentity()); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

// ── handlers: feature requests ────────────────────────────────────────────────

func listFeatureRequestsHandler(c *gin.Context) {
	status := c.Query("status")
	if status != "" {
		if err := validate.OneOf(status, "pending", "approved", "rejected"); err != nil {
			writeError(c, err)
			return
		}
	}
	data, err := ops.ListFeatureRequests(opsCtx(), dbClient, ops.ListFeatureRequestsParams{Status: status})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}
