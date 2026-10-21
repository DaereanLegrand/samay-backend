package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

const (
	objectPathPrefix = "/storage/v1/object/"
	maxErrorBody     = 8 << 10
)

var ErrInvalidObject = errors.New("storage: invalid object reference")

type Client struct {
	BaseURL    string
	ServiceKey string
	HTTP       *http.Client
}

func NewClient() (*Client, error) {
	baseURL := strings.TrimSpace(os.Getenv("SUPABASE_URL"))
	serviceKey := strings.TrimSpace(os.Getenv("SUPABASE_SERVICE_ROLE_KEY"))
	if baseURL == "" || serviceKey == "" {
		return nil, fmt.Errorf("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set")
	}
	return &Client{
		BaseURL:    baseURL,
		ServiceKey: serviceKey,
		HTTP:       &http.Client{Timeout: 30 * time.Second},
	}, nil
}

func (c *Client) DeleteObject(ctx context.Context, bucket, object string) error {
	if err := validateObjectRef(bucket, object); err != nil {
		return err
	}

	endpoint := strings.TrimRight(c.BaseURL, "/") + objectPathPrefix +
		url.PathEscape(bucket) + "/" + escapeObjectPath(object)

	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, endpoint, nil)
	if err != nil {
		return fmt.Errorf("storage delete: request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.ServiceKey)
	req.Header.Set("apikey", c.ServiceKey)
	req.Header.Set("Accept", "application/json")

	client := c.HTTP
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("storage delete %s/%s: %w", bucket, object, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxErrorBody))
	if err != nil {
		return fmt.Errorf("storage delete %s/%s: read response: %w", bucket, object, err)
	}

	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return nil
	case isMissingBucket(body):
		return fmt.Errorf("storage delete %s/%s: bucket not found: %s", bucket, object, strings.TrimSpace(string(body)))
	case isMissingObject(body):
		if err := c.bucketExists(ctx, bucket); err != nil {
			return fmt.Errorf("storage delete %s/%s: %w", bucket, object, err)
		}
		return nil
	default:
		return fmt.Errorf("storage delete %s/%s: status %d: %s", bucket, object, resp.StatusCode, strings.TrimSpace(string(body)))
	}
}

func (c *Client) bucketExists(ctx context.Context, bucket string) error {
	endpoint := strings.TrimRight(c.BaseURL, "/") + "/storage/v1/bucket/" + url.PathEscape(bucket)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return fmt.Errorf("bucket check: request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.ServiceKey)
	req.Header.Set("apikey", c.ServiceKey)
	req.Header.Set("Accept", "application/json")

	client := c.HTTP
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("bucket check: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, maxErrorBody))
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	if isMissingBucket(body) {
		return fmt.Errorf("bucket not found: %s", strings.TrimSpace(string(body)))
	}
	return fmt.Errorf("bucket check status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
}

func validateObjectRef(bucket, object string) error {
	if bucket == "" || object == "" {
		return fmt.Errorf("%w: bucket and object are required", ErrInvalidObject)
	}
	if len(bucket) > 64 || len(object) > 1024 {
		return fmt.Errorf("%w: bucket/object too long", ErrInvalidObject)
	}
	for _, r := range bucket {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case r == '.', r == '_', r == '-':
		default:
			return fmt.Errorf("%w: bad bucket character %q", ErrInvalidObject, r)
		}
	}
	if bucket == "." || bucket == ".." || strings.Contains(bucket, "..") {
		return fmt.Errorf("%w: bad bucket %q", ErrInvalidObject, bucket)
	}

	if strings.HasPrefix(object, "/") {
		return fmt.Errorf("%w: object must be relative", ErrInvalidObject)
	}
	for _, seg := range strings.Split(object, "/") {
		if seg == "" || seg == "." || seg == ".." {
			return fmt.Errorf("%w: bad object segment %q", ErrInvalidObject, seg)
		}
	}
	for _, r := range object {
		if r == 0 || r < 0x20 || r == 0x7f {
			return fmt.Errorf("%w: control character in object", ErrInvalidObject)
		}
	}
	return nil
}

func escapeObjectPath(object string) string {
	segments := strings.Split(object, "/")
	for i, seg := range segments {
		segments[i] = url.PathEscape(seg)
	}
	return strings.Join(segments, "/")
}

func isMissingBucket(body []byte) bool {
	s := strings.ToLower(string(body))
	return strings.Contains(s, "nosuchbucket") ||
		strings.Contains(s, "bucket not found") ||
		strings.Contains(s, "bucket_not_found")
}

func isMissingObject(body []byte) bool {
	s := strings.ToLower(string(body))
	return strings.Contains(s, "nosuchkey") ||
		strings.Contains(s, "not_found") ||
		strings.Contains(s, "object not found") ||
		strings.Contains(s, "not found")
}
