package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/samay-app/samay/internal/auth"
	"github.com/samay-app/samay/internal/ops"
	"github.com/samay-app/samay/internal/validate"
)

// apiBase is the versioned path prefix for all routes.
const apiBase = "/api/v1"

// Admin-surface resource limits. Admin traffic is human-paced, so both buckets
// are tight enough to stop a brute-force/flood while leaving normal console use
// unaffected.
const (
	maxAdminBodyBytes  = 128 << 10 // 128 KiB
	ipTokensPerSecond  = 1         // 60 req/min per source IP
	ipBurst            = 60
	adminTokensPerSec  = 0.5 // 30 req/min per admin
	adminBurst         = 30
	adminLookupTimeout = 5 * time.Second
)

// adminSubjectKey is the gin context key holding the verified JWT subject.
const adminSubjectKey = "admin_subject"

func newRouter(verifier *auth.Verifier) *gin.Engine {
	r := gin.New()
	r.HandleMethodNotAllowed = true
	// ClientIP drives the per-IP bucket. Default to the socket address; a
	// deployment behind a trusted proxy opts in with TRUSTED_PROXIES.
	if err := r.SetTrustedProxies(trustedProxies()); err != nil {
		log.Printf("invalid TRUSTED_PROXIES, falling back to socket addresses: %v", err)
		_ = r.SetTrustedProxies(nil)
	}
	r.Use(requestLogger(), recovery())
	r.NoRoute(notFound)
	r.NoMethod(notAllowed)

	r.GET(apiBase+"/health", healthHandler)

	ipLimiter := auth.NewRateLimiter(ipTokensPerSecond, ipBurst)
	adminLimiter := auth.NewRateLimiter(adminTokensPerSec, adminBurst)
	admin := r.Group(apiBase+"/admin",
		limitByIP(ipLimiter),
		bodyLimit(maxAdminBodyBytes),
		requireAdmin(verifier),
		limitByAdmin(adminLimiter),
	)
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
		admin.POST("/reports/:id/claim", claimReportHandler)

		// appeals
		admin.GET("/appeals", listAppealsHandler)
		admin.GET("/appeals/:id", getAppealHandler)
		admin.POST("/appeals/:id/decision", decideAppealHandler)

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
	// complete; the actual handlers land with the host/venue phases.
	r.Any(apiBase+"/host/*any", notImplemented)
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

// requireAdmin verifies the Supabase HS256 JWT and resolves its subject in
// admin_users. Bad/expired/wrong-audience tokens are 401; a valid token whose
// subject is not an admin is 403.
func requireAdmin(verifier *auth.Verifier) gin.HandlerFunc {
	return func(c *gin.Context) {
		token, ok := strings.CutPrefix(c.GetHeader("Authorization"), "Bearer ")
		if !ok || verifier == nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
			return
		}
		claims, err := verifier.Verify(token)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
			return
		}
		if err := validate.ParseUUID(claims.Subject); err != nil {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "forbidden"})
			return
		}

		ctx, cancel := context.WithTimeout(c.Request.Context(), adminLookupTimeout)
		defer cancel()
		if _, err := ops.GetAdmin(ctx, dbClient, claims.Subject); err != nil {
			if errors.Is(err, ops.ErrNotFound) {
				c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "forbidden"})
				return
			}
			log.Printf("admin identity lookup error: %v", err)
			c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
			return
		}
		c.Set(adminSubjectKey, claims.Subject)
		c.Next()
	}
}

// limitByIP caps requests per source address before any auth/DB work.
func limitByIP(limiter *auth.RateLimiter) gin.HandlerFunc {
	return rateLimit(limiter, func(c *gin.Context) string {
		return "ip:" + c.ClientIP()
	})
}

// limitByAdmin caps requests per verified admin subject.
func limitByAdmin(limiter *auth.RateLimiter) gin.HandlerFunc {
	return rateLimit(limiter, func(c *gin.Context) string {
		return "admin:" + c.GetString(adminSubjectKey)
	})
}

func rateLimit(limiter *auth.RateLimiter, key func(*gin.Context) string) gin.HandlerFunc {
	return func(c *gin.Context) {
		allowed, retryAfter := limiter.Allow(key(c))
		if !allowed {
			seconds := int(retryAfter / time.Second)
			if seconds < 1 {
				seconds = 1
			}
			c.Header("Retry-After", strconv.Itoa(seconds))
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{"error": "rate limit exceeded"})
			return
		}
		c.Next()
	}
}

// bodyLimit rejects oversized admin requests up front and wraps the reader so a
// chunked body cannot bypass the cap. bindJSON maps the reader error to 413.
func bodyLimit(max int64) gin.HandlerFunc {
	return func(c *gin.Context) {
		if c.Request.ContentLength > max {
			c.AbortWithStatusJSON(http.StatusRequestEntityTooLarge, gin.H{"error": "request body too large"})
			return
		}
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, max)
		c.Next()
	}
}

// adminIdentity returns the verified audit actor for the current request.
func adminIdentity(c *gin.Context) string {
	return c.GetString(adminSubjectKey)
}

func trustedProxies() []string {
	raw := strings.TrimSpace(os.Getenv("TRUSTED_PROXIES"))
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
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

// opsCtx derives the context for internal/ops calls from the request context
// (client disconnect cancels in-flight DB work) with a 30s cap. The cancel is
// released as soon as the request context ends via context.AfterFunc.
func opsCtx(c *gin.Context) context.Context {
	requestCtx := c.Request.Context()
	ctx, cancel := context.WithTimeout(requestCtx, 30*time.Second)
	context.AfterFunc(requestCtx, cancel)
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

// bindJSON decodes the request body into dst or aborts with 400 (413 when the
// body exceeded the admin cap).
func bindJSON(c *gin.Context, dst any) bool {
	if err := c.ShouldBindJSON(dst); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			c.AbortWithStatusJSON(http.StatusRequestEntityTooLarge, gin.H{"error": "request body too large"})
			return false
		}
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

func queryIntDefault(c *gin.Context, key string, def int) (int, error) {
	raw := c.Query(key)
	if raw == "" {
		return def, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("invalid %s %q: must be a non-negative integer", key, raw)
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

type appealDecisionRequest struct {
	Decision string `json:"decision"`
	Note     string `json:"note"`
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
	health, err := ops.HealthCheck(opsCtx(c), dbClient)
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
	data, err := ops.ListUsers(opsCtx(c), dbClient, ops.ListUsersParams{
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
	data, err := ops.GetUser(opsCtx(c), dbClient, c.Param("id"))
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
	if err := ops.BanUser(opsCtx(c), dbClient, c.Param("id"), req.Reason, adminIdentity(c)); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func unbanUserHandler(c *gin.Context) {
	if err := ops.UnbanUser(opsCtx(c), dbClient, c.Param("id"), adminIdentity(c)); err != nil {
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
	if err := ops.GrantShards(opsCtx(c), dbClient, c.Param("id"), req.Amount, reason, adminIdentity(c)); err != nil {
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
	if err := ops.GrantPreshards(opsCtx(c), dbClient, c.Param("id"), req.Amount, reason, adminIdentity(c)); err != nil {
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
	if err := ops.SoftDeleteUser(opsCtx(c), dbClient, id, adminIdentity(c)); err != nil {
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
	data, err := ops.GetShardLedger(opsCtx(c), dbClient, c.Param("id"), limit)
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
	data, err := ops.ListEvents(opsCtx(c), dbClient, ops.ListEventsParams{
		Status: status,
		Type:   eventType,
		Host:   c.Query("host"),
	})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func getEventHandler(c *gin.Context) {
	data, err := ops.GetEvent(opsCtx(c), dbClient, c.Param("id"))
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
	if err := ops.FeatureEvent(opsCtx(c), dbClient, c.Param("id"), expiresAt, adminIdentity(c)); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func unfeatureEventHandler(c *gin.Context) {
	if err := ops.UnfeatureEvent(opsCtx(c), dbClient, c.Param("id"), adminIdentity(c)); err != nil {
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
	if err := ops.CancelEvent(opsCtx(c), dbClient, c.Param("id"), req.Reason, adminIdentity(c)); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func distributeShardsHandler(c *gin.Context) {
	if err := ops.DistributeShards(opsCtx(c), dbClient, c.Param("id"), adminIdentity(c)); err != nil {
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
	data, err := ops.ListGroups(opsCtx(c), dbClient, ops.ListGroupsParams{
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
	data, err := ops.GetGroup(opsCtx(c), dbClient, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func groupMembersHandler(c *gin.Context) {
	data, err := ops.ListGroupMembers(opsCtx(c), dbClient, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func groupLedgerHandler(c *gin.Context) {
	data, err := ops.GetGroupShardLedger(opsCtx(c), dbClient, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

// ── handlers: reports ─────────────────────────────────────────────────────────

var reportCategories = []string{
	"csam", "credible_threat", "ncii", "harassment",
	"hate", "spam", "impersonation", "other",
}

var reportTargetTypes = []string{
	"message", "photo", "user", "event", "minigame_answer",
	"minigame_image", "avatar", "group_cover", "event_description",
}

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
		if err := validate.OneOf(targetType, reportTargetTypes...); err != nil {
			writeError(c, err)
			return
		}
	}
	category := c.Query("category")
	if category != "" {
		if err := validate.OneOf(category, reportCategories...); err != nil {
			writeError(c, err)
			return
		}
	}
	limit, err := queryIntDefault(c, "limit", 100)
	if err != nil {
		writeError(c, err)
		return
	}
	offset, err := queryIntDefault(c, "offset", 0)
	if err != nil {
		writeError(c, err)
		return
	}
	var priority *int
	if raw := c.Query("priority"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 0 {
			writeError(c, fmt.Errorf("invalid priority %q: must be a non-negative integer", raw))
			return
		}
		priority = &n
	}
	data, err := ops.ListReports(opsCtx(c), dbClient, ops.ListReportsParams{
		Status:   status,
		Type:     targetType,
		Category: category,
		Priority: priority,
		Limit:    limit,
		Offset:   offset,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func getReportHandler(c *gin.Context) {
	data, err := ops.GetReport(opsCtx(c), dbClient, c.Param("id"))
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
	if err := validate.OneOf(req.Action, "review", "remove", "dismiss", "warn"); err != nil {
		writeError(c, err)
		return
	}
	if err := ops.ActionReport(opsCtx(c), dbClient, c.Param("id"), req.Action, adminIdentity(c)); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func claimReportHandler(c *gin.Context) {
	if err := ops.ClaimReport(opsCtx(c), dbClient, c.Param("id"), adminIdentity(c)); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func listAppealsHandler(c *gin.Context) {
	status := c.Query("status")
	if status != "" {
		if err := validate.OneOf(status, "open", "reviewing", "upheld", "overturned", "closed"); err != nil {
			writeError(c, err)
			return
		}
	}
	limit, err := queryIntDefault(c, "limit", 100)
	if err != nil {
		writeError(c, err)
		return
	}
	offset, err := queryIntDefault(c, "offset", 0)
	if err != nil {
		writeError(c, err)
		return
	}
	data, err := ops.ListAppeals(opsCtx(c), dbClient, status, limit, offset)
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func getAppealHandler(c *gin.Context) {
	data, err := ops.GetAppeal(opsCtx(c), dbClient, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func decideAppealHandler(c *gin.Context) {
	var req appealDecisionRequest
	if !bindJSON(c, &req) {
		return
	}
	if err := validate.OneOf(req.Decision, "upheld", "overturned", "closed"); err != nil {
		writeError(c, err)
		return
	}
	if err := ops.DecideAppeal(opsCtx(c), dbClient, c.Param("id"), req.Decision, req.Note, adminIdentity(c)); err != nil {
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
	if err := ops.RecalculateRanks(opsCtx(c), dbClient, req.Tier); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

// ── handlers: config ──────────────────────────────────────────────────────────

func listConfigHandler(c *gin.Context) {
	data, err := ops.ListConfig(opsCtx(c), dbClient)
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func getConfigHandler(c *gin.Context) {
	data, err := ops.GetConfig(opsCtx(c), dbClient, c.Param("key"))
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
	if err := ops.SetConfig(opsCtx(c), dbClient, c.Param("key"), req.Value, adminIdentity(c)); err != nil {
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
	data, err := ops.ListSubs(opsCtx(c), dbClient, ops.ListSubsParams{Tier: tier})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}

func getSubHandler(c *gin.Context) {
	data, err := ops.GetSub(opsCtx(c), dbClient, c.Param("id"))
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
	if err := ops.OverrideSub(opsCtx(c), dbClient, c.Param("id"), req.Tier, adminIdentity(c), expiresAt, req.Reason); err != nil {
		writeError(c, err)
		return
	}
	ok(c)
}

func revokeOverrideHandler(c *gin.Context) {
	if err := ops.RevokeOverride(opsCtx(c), dbClient, c.Param("id"), adminIdentity(c)); err != nil {
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
	data, err := ops.ListFeatureRequests(opsCtx(c), dbClient, ops.ListFeatureRequestsParams{Status: status})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, data)
}
