package db

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
)

type DBClient struct {
	BaseURL    string
	ServiceKey string
	HTTP       *http.Client
}

func NewDBClient() (*DBClient, error) {
	baseURL := strings.TrimSpace(os.Getenv("SUPABASE_URL"))
	serviceKey := strings.TrimSpace(os.Getenv("SUPABASE_SERVICE_ROLE_KEY"))
	if baseURL == "" || serviceKey == "" {
		return nil, fmt.Errorf("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set")
	}
	return &DBClient{
		BaseURL:    baseURL,
		ServiceKey: serviceKey,
		HTTP:       &http.Client{},
	}, nil
}

func (c *DBClient) request(ctx context.Context, method, path string, body io.Reader) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, body)
	if err != nil {
		return nil, fmt.Errorf("http request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.ServiceKey)
	// Kong's `key-auth` on /rest/v1/ reads the `apikey` header (Supabase
	// convention); Bearer alone yields 401 "No API key found in request".
	req.Header.Set("apikey", c.ServiceKey)
	req.Header.Set("Content-Type", "application/json")
	if method == "GET" {
		req.Header.Set("Accept", "application/json")
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("http do: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 10<<20))
	if err != nil {
		return nil, fmt.Errorf("read response body: %w", err)
	}

	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("supabase error %d: %s", resp.StatusCode, string(respBody))
	}

	return respBody, nil
}

// TODO(GO-FIX): Migrate all callers to use QueryBuilder for filter construction
// to prevent potential injection via raw string concatenation. See audit M9.
func (c *DBClient) Select(ctx context.Context, table, filter string, limit, offset int) ([]byte, error) {
	path := "/rest/v1/" + table
	var params []string

	if filter != "" {
		parts := strings.SplitN(filter, "&", 2)
		params = append(params, "select="+parts[0])
		if len(parts) > 1 {
			params = append(params, parts[1])
		}
	}
	if limit > 0 {
		params = append(params, fmt.Sprintf("limit=%d", limit))
	}
	if offset > 0 {
		params = append(params, fmt.Sprintf("offset=%d", offset))
	}

	if len(params) > 0 {
		path += "?" + strings.Join(params, "&")
	}
	return c.request(ctx, "GET", path, nil)
}

func (c *DBClient) Insert(ctx context.Context, table string, row any) ([]byte, error) {
	b, err := json.Marshal(row)
	if err != nil {
		return nil, fmt.Errorf("json marshal: %w", err)
	}
	path := "/rest/v1/" + table + "?select=*"
	return c.request(ctx, "POST", path, bytes.NewReader(b))
}

// TODO(GO-FIX): Migrate all callers to use QueryBuilder for filter construction
// to prevent potential injection via raw string concatenation. See audit M9.
func (c *DBClient) Update(ctx context.Context, table, filter string, patch any) ([]byte, error) {
	b, err := json.Marshal(patch)
	if err != nil {
		return nil, fmt.Errorf("json marshal: %w", err)
	}
	path := "/rest/v1/" + table + "?" + filter + "&select=*"
	return c.request(ctx, "PATCH", path, bytes.NewReader(b))
}

// TODO(GO-FIX): Migrate all callers to use QueryBuilder for filter construction
// to prevent potential injection via raw string concatenation. See audit M9.
func (c *DBClient) Delete(ctx context.Context, table, filter string) ([]byte, error) {
	path := "/rest/v1/" + table + "?" + filter
	return c.request(ctx, "DELETE", path, nil)
}

func (c *DBClient) RPC(ctx context.Context, function string, params map[string]any) ([]byte, error) {
	b, err := json.Marshal(params)
	if err != nil {
		return nil, fmt.Errorf("json marshal: %w", err)
	}
	path := "/rest/v1/rpc/" + function
	return c.request(ctx, "POST", path, bytes.NewReader(b))
}
