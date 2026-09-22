package loadtest

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const maxRespBody = 8 << 20

// Client is a thin HTTP client for the Supabase gateway (Kong). It carries
// both the anon and service_role keys and lets callers pass a user JWT for
// RLS-scoped requests.
type Client struct {
	BaseURL    string
	AnonKey    string
	ServiceKey string
	HTTP       *http.Client
}

func NewClient(cfg *Config) *Client {
	transport := &http.Transport{
		MaxIdleConns:        500,
		MaxIdleConnsPerHost: 200,
		MaxConnsPerHost:     0,
		IdleConnTimeout:     90 * time.Second,
		ForceAttemptHTTP2:   true,
	}
	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	return &Client{
		BaseURL:    strings.TrimRight(cfg.URL, "/"),
		AnonKey:    cfg.AnonKey,
		ServiceKey: cfg.ServiceKey,
		HTTP:       &http.Client{Transport: transport, Timeout: timeout},
	}
}

// request performs one HTTP call and returns status + body. A non-2xx status
// yields an error that includes the status code and a body snippet, but the
// body is still returned for callers that need it.
func (c *Client) request(ctx context.Context, method, path, token string, body []byte, contentType string, extra map[string]string) (int, []byte, error) {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, reader)
	if err != nil {
		return 0, nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("apikey", c.AnonKey)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	for k, v := range extra {
		req.Header.Set(k, v)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("%s %s: %w", method, path, err)
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(io.LimitReader(resp.Body, maxRespBody))
	if err != nil {
		return resp.StatusCode, nil, fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode >= 400 {
		snippet := string(respBody)
		if len(snippet) > 300 {
			snippet = snippet[:300]
		}
		return resp.StatusCode, respBody, fmt.Errorf("supabase error %d: %s", resp.StatusCode, snippet)
	}
	return resp.StatusCode, respBody, nil
}

func (c *Client) doJSON(ctx context.Context, method, path, token string, payload any) (int, []byte, error) {
	var body []byte
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			return 0, nil, fmt.Errorf("marshal payload: %w", err)
		}
		body = b
	}
	return c.request(ctx, method, path, token, body, "application/json", nil)
}

// Health checks the auth health endpoint; used to fail fast on a bad URL.
func (c *Client) Health(ctx context.Context) error {
	_, _, err := c.request(ctx, http.MethodGet, "/auth/v1/health", c.AnonKey, nil, "", nil)
	return err
}

// AdminCreateUser creates a confirmed auth user via the GoTrue admin API.
func (c *Client) AdminCreateUser(ctx context.Context, id, email, password string) error {
	payload := map[string]any{
		"id":            id,
		"email":         email,
		"password":      password,
		"email_confirm": true,
	}
	_, _, err := c.doJSON(ctx, http.MethodPost, "/auth/v1/admin/users", c.ServiceKey, payload)
	return err
}

// PasswordLogin exchanges credentials for an access/refresh token pair.
func (c *Client) PasswordLogin(ctx context.Context, email, password string) (string, string, error) {
	_, body, err := c.doJSON(ctx, http.MethodPost, "/auth/v1/token?grant_type=password", c.AnonKey,
		map[string]string{"email": email, "password": password})
	if err != nil {
		return "", "", err
	}
	var out struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", "", fmt.Errorf("decode login response: %w", err)
	}
	if out.AccessToken == "" {
		return "", "", fmt.Errorf("login returned no access_token")
	}
	return out.AccessToken, out.RefreshToken, nil
}

// Refresh exchanges a refresh token for a fresh access token.
func (c *Client) Refresh(ctx context.Context, refreshToken string) (string, error) {
	_, body, err := c.doJSON(ctx, http.MethodPost, "/auth/v1/token?grant_type=refresh_token", c.AnonKey,
		map[string]string{"refresh_token": refreshToken})
	if err != nil {
		return "", err
	}
	var out struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", fmt.Errorf("decode refresh response: %w", err)
	}
	if out.AccessToken == "" {
		return "", fmt.Errorf("refresh returned no access_token")
	}
	return out.AccessToken, nil
}

// Get performs a REST GET with the given token (the anon key when token is the
// anon key). Returns the status code, body and an error on non-2xx.
func (c *Client) Get(ctx context.Context, path, token string) (int, []byte, error) {
	return c.request(ctx, http.MethodGet, path, token, nil, "", nil)
}

// Insert writes rows to a table, using Prefer: return=minimal.
func (c *Client) Insert(ctx context.Context, table string, row any, token string) error {
	body, err := json.Marshal(row)
	if err != nil {
		return fmt.Errorf("marshal row: %w", err)
	}
	_, _, err = c.request(ctx, http.MethodPost, "/rest/v1/"+table, token, body, "application/json",
		map[string]string{"Prefer": "return=minimal"})
	return err
}

// Update patches matching rows. filter is a raw PostgREST query string.
func (c *Client) Update(ctx context.Context, table, filter string, patch any, token string) error {
	body, err := json.Marshal(patch)
	if err != nil {
		return fmt.Errorf("marshal patch: %w", err)
	}
	_, _, err = c.request(ctx, http.MethodPatch, "/rest/v1/"+table+"?"+filter, token, body,
		"application/json", map[string]string{"Prefer": "return=minimal"})
	return err
}

// RPC calls a Postgres function via PostgREST.
func (c *Client) RPC(ctx context.Context, fn string, params map[string]any, token string) (json.RawMessage, error) {
	body, err := json.Marshal(params)
	if err != nil {
		return nil, fmt.Errorf("marshal params: %w", err)
	}
	_, resp, err := c.request(ctx, http.MethodPost, "/rest/v1/rpc/"+fn, token, body, "application/json", nil)
	if err != nil {
		return nil, err
	}
	return json.RawMessage(resp), nil
}

// StorageUpload stores object bytes at bucket/path.
func (c *Client) StorageUpload(ctx context.Context, bucket, path string, data []byte, contentType, token string) error {
	escaped := url.PathEscape(bucket) + "/" + escapePath(path)
	_, _, err := c.request(ctx, http.MethodPost, "/storage/v1/object/"+escaped, token, data, contentType, nil)
	return err
}

// escapePath escapes each path segment but keeps the separators, so storage
// object paths like "<uuid>/<name>.jpg" stay intact.
func escapePath(p string) string {
	parts := strings.Split(p, "/")
	for i, s := range parts {
		parts[i] = url.PathEscape(s)
	}
	return strings.Join(parts, "/")
}
