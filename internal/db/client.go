package db

import (
	"bytes"
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

func NewDBClient() *DBClient {
	return &DBClient{
		BaseURL:    os.Getenv("SUPABASE_URL"),
		ServiceKey: os.Getenv("SUPABASE_SERVICE_ROLE_KEY"),
		HTTP:       &http.Client{},
	}
}

func (c *DBClient) request(method, path string, body io.Reader) ([]byte, error) {
	req, err := http.NewRequest(method, c.BaseURL+path, body)
	if err != nil {
		return nil, fmt.Errorf("http request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.ServiceKey)
	req.Header.Set("Content-Type", "application/json")
	if method == "GET" {
		req.Header.Set("Accept", "application/json")
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("http do: %w", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)

	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("supabase error %d: %s", resp.StatusCode, string(respBody))
	}

	return respBody, nil
}

func (c *DBClient) Select(table, filter string, limit, offset int) ([]byte, error) {
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
	return c.request("GET", path, nil)
}

func (c *DBClient) Insert(table string, row interface{}) ([]byte, error) {
	b, err := json.Marshal(row)
	if err != nil {
		return nil, fmt.Errorf("json marshal: %w", err)
	}
	path := "/rest/v1/" + table + "?select=*"
	return c.request("POST", path, bytes.NewReader(b))
}

func (c *DBClient) Update(table, filter string, patch interface{}) ([]byte, error) {
	b, err := json.Marshal(patch)
	if err != nil {
		return nil, fmt.Errorf("json marshal: %w", err)
	}
	path := "/rest/v1/" + table + "?" + filter + "&select=*"
	return c.request("PATCH", path, bytes.NewReader(b))
}

func (c *DBClient) Delete(table, filter string) ([]byte, error) {
	path := "/rest/v1/" + table + "?" + filter
	return c.request("DELETE", path, nil)
}

func (c *DBClient) RPC(function string, params map[string]interface{}) ([]byte, error) {
	b, err := json.Marshal(params)
	if err != nil {
		return nil, fmt.Errorf("json marshal: %w", err)
	}
	path := "/rest/v1/rpc/" + function
	return c.request("POST", path, bytes.NewReader(b))
}


