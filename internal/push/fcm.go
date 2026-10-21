// Package push sends Samay notifications to device tokens over FCM HTTP v1.
//
// One send path covers both platforms: Android is delivered natively and iOS
// through APNs, which FCM brokers (the APNs key lives in the Firebase project,
// not in this code). The package has no third-party dependency: the OAuth2
// service-account JWT (RS256) is built and signed with the standard library.
package push

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	fcmScope            = "https://www.googleapis.com/auth/firebase.messaging"
	defaultTokenURI     = "https://oauth2.googleapis.com/token"
	fcmSendEndpointTmpl = "https://fcm.googleapis.com/v1/projects/%s/messages:send"
)

// ErrUnregistered reports an FCM token that is no longer valid (app uninstalled,
// token rotated, or the app cleared data). The worker prunes these rows.
var ErrUnregistered = errors.New("fcm: token unregistered")

type serviceAccount struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

// Generic copy keys sent instead of content. The client resolves them to
// localized placeholder text ("New activity in Samay") and then loads the real
// content from the in-app notification center once the user is authenticated.
const (
	GenericTitleKey = "push.generic.title"
	GenericBodyKey  = "push.generic.body"

	dataKeyNotificationID = "notification_id"
	dataKeyType           = "type"
	dataKeyTitleKey       = "titleKey"
	dataKeyBodyKey        = "bodyKey"
)

// allowedDataKeys is the complete set of keys that may reach FCM/APNs. Content
// (title, body, sender, location, wager, answers, prompts) is intentionally
// excluded: push is a wake-up signal, not a content channel.
var allowedDataKeys = map[string]struct{}{
	dataKeyNotificationID: {},
	dataKeyType:           {},
	dataKeyTitleKey:       {},
	dataKeyBodyKey:        {},
}

// Message is the platform-agnostic payload rendered into an FCM v1 message.
// It carries only an opaque notification id and type; text is never included.
type Message struct {
	NotificationID string
	Type           string
}

// data returns the allow-listed data map for FCM. It is built here rather than
// accepted from callers so raw notification content cannot leak into a push.
func (m Message) data() map[string]string {
	return map[string]string{
		dataKeyNotificationID: m.NotificationID,
		dataKeyType:           m.Type,
		dataKeyTitleKey:       GenericTitleKey,
		dataKeyBodyKey:        GenericBodyKey,
	}
}

// payload renders a data-only FCM v1 message. APNs gets a silent background
// push (content-available + mutable-content, no alert); Android uses high
// priority so the client wakes promptly.
func payload(token string, msg Message) ([]byte, error) {
	out := map[string]any{
		"message": map[string]any{
			"token": token,
			"data":  msg.data(),
			"android": map[string]any{
				"priority": "high",
			},
			"apns": map[string]any{
				"headers": map[string]string{
					"apns-priority":  "5",
					"apns-push-type": "background",
				},
				"payload": map[string]any{
					"aps": map[string]any{
						"content-available": 1,
						"mutable-content":   1,
					},
				},
			},
		},
	}
	body, err := json.Marshal(out)
	if err != nil {
		return nil, fmt.Errorf("marshal fcm payload: %w", err)
	}
	return body, nil
}

// FCMClient authenticates as the service account and sends FCM v1 messages.
// It is safe for concurrent use.
type FCMClient struct {
	projectID string
	email     string
	key       *rsa.PrivateKey
	tokenURI  string
	endpoint  string
	http      *http.Client

	mu          sync.Mutex
	cachedToken string
	tokenExpiry time.Time
}

// NewFCMClient loads a Google service-account JSON file and prepares the v1
// endpoint for its project.
func NewFCMClient(serviceAccountPath string) (*FCMClient, error) {
	raw, err := os.ReadFile(serviceAccountPath)
	if err != nil {
		return nil, fmt.Errorf("read service account: %w", err)
	}
	return NewFCMClientFromJSON(raw)
}

// NewFCMClientFromJSON builds the client from an in-memory service-account JSON
// document (used when the credential is injected inline, e.g. base64 in the
// compose env, rather than as a mounted file).
func NewFCMClientFromJSON(raw []byte) (*FCMClient, error) {
	var sa serviceAccount
	if err := json.Unmarshal(raw, &sa); err != nil {
		return nil, fmt.Errorf("parse service account: %w", err)
	}
	if sa.ProjectID == "" || sa.ClientEmail == "" || sa.PrivateKey == "" {
		return nil, fmt.Errorf("service account missing project_id/client_email/private_key")
	}
	key, err := parseRSAPrivateKey(sa.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("parse private key: %w", err)
	}
	tokenURI := sa.TokenURI
	if tokenURI == "" {
		tokenURI = defaultTokenURI
	}
	return &FCMClient{
		projectID: sa.ProjectID,
		email:     sa.ClientEmail,
		key:       key,
		tokenURI:  tokenURI,
		endpoint:  fmt.Sprintf(fcmSendEndpointTmpl, sa.ProjectID),
		http:      &http.Client{Timeout: 15 * time.Second},
	}, nil
}

// Send delivers one message to one device token.
func (c *FCMClient) Send(ctx context.Context, token string, msg Message) error {
	access, err := c.accessToken(ctx)
	if err != nil {
		return err
	}

	body, err := payload(token, msg)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build fcm request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("fcm send: %w", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	if resp.StatusCode >= 400 {
		if isUnregistered(respBody) {
			return ErrUnregistered
		}
		return fmt.Errorf("fcm status %d: %s", resp.StatusCode, string(respBody))
	}
	return nil
}

// accessToken returns a cached bearer token, minting a new one when needed.
func (c *FCMClient) accessToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cachedToken != "" && time.Now().Before(c.tokenExpiry) {
		return c.cachedToken, nil
	}

	assertion, err := c.signedAssertion()
	if err != nil {
		return "", err
	}
	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {assertion},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.tokenURI,
		strings.NewReader(form.Encode()))
	if err != nil {
		return "", fmt.Errorf("build token request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := c.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("token exchange: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("token exchange status %d: %s", resp.StatusCode, string(body))
	}
	var tok struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &tok); err != nil {
		return "", fmt.Errorf("parse token response: %w", err)
	}
	if tok.AccessToken == "" {
		return "", fmt.Errorf("token exchange returned empty access_token")
	}
	ttl := time.Duration(tok.ExpiresIn) * time.Second
	if ttl <= 0 {
		ttl = time.Hour
	}
	c.cachedToken = tok.AccessToken
	// Refresh a minute early to avoid edge expiry.
	c.tokenExpiry = time.Now().Add(ttl - time.Minute)
	return c.cachedToken, nil
}

// signedAssertion builds and RS256-signs the JWT bearer assertion.
func (c *FCMClient) signedAssertion() (string, error) {
	now := time.Now()
	header := base64URL(mustJSON(map[string]string{"alg": "RS256", "typ": "JWT"}))
	claims := base64URL(mustJSON(map[string]any{
		"iss":   c.email,
		"scope": fcmScope,
		"aud":   c.tokenURI,
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	}))
	signingInput := header + "." + claims

	digest := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, c.key, crypto.SHA256, digest[:])
	if err != nil {
		return "", fmt.Errorf("sign assertion: %w", err)
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

func parseRSAPrivateKey(pemKey string) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(pemKey))
	if block == nil {
		return nil, fmt.Errorf("no PEM block")
	}
	if key, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		rsaKey, ok := key.(*rsa.PrivateKey)
		if !ok {
			return nil, fmt.Errorf("PKCS8 key is not RSA")
		}
		return rsaKey, nil
	}
	return x509.ParsePKCS1PrivateKey(block.Bytes)
}

func isUnregistered(body []byte) bool {
	s := string(body)
	return strings.Contains(s, "UNREGISTERED") ||
		strings.Contains(s, "NOT_FOUND") ||
		strings.Contains(s, "registration-token-not-registered")
}

func base64URL(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}
