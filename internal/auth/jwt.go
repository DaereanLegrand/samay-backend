// Package auth verifies Supabase-issued HS256 JWTs for the admin surface.
package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
)

// Token errors are deliberately coarse: callers return a single 401 body and
// must not leak which claim failed.
var (
	ErrInvalidToken = errors.New("invalid token")
	ErrExpiredToken = errors.New("expired token")
)

// RequiredAudience is the Supabase audience for authenticated end users.
const RequiredAudience = "authenticated"

// RequiredRole is the Supabase role for authenticated end users.
const RequiredRole = "authenticated"

// Claims is the verified subset of a Supabase JWT.
type Claims struct {
	Subject   string
	Role      string
	Audience  []string
	ExpiresAt time.Time
}

// Verifier validates HS256 tokens signed with the stack's JWT secret.
type Verifier struct {
	secret []byte
	now    func() time.Time
}

// NewVerifier builds a verifier from a non-empty secret.
func NewVerifier(secret string) (*Verifier, error) {
	if strings.TrimSpace(secret) == "" {
		return nil, errors.New("jwt secret is empty")
	}
	return &Verifier{secret: []byte(secret), now: time.Now}, nil
}

// NewVerifierFromEnv reads SUPABASE_JWT_SECRET and falls back to JWT_SECRET
// (the local self-hosted stack uses the latter).
func NewVerifierFromEnv() (*Verifier, error) {
	secret := strings.TrimSpace(os.Getenv("SUPABASE_JWT_SECRET"))
	if secret == "" {
		secret = strings.TrimSpace(os.Getenv("JWT_SECRET"))
	}
	if secret == "" {
		return nil, errors.New("SUPABASE_JWT_SECRET or JWT_SECRET must be set")
	}
	return NewVerifier(secret)
}

// Verify checks the signature using constant-time comparison and enforces the
// admin-surface claim contract: exp present and in the future, sub present,
// aud=authenticated, role=authenticated.
func (v *Verifier) Verify(token string) (*Claims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
		return nil, ErrInvalidToken
	}

	headerJSON, err := decodeSegment(parts[0])
	if err != nil {
		return nil, ErrInvalidToken
	}
	var header struct {
		Alg string `json:"alg"`
	}
	if err := json.Unmarshal(headerJSON, &header); err != nil {
		return nil, ErrInvalidToken
	}
	if header.Alg != "HS256" {
		return nil, ErrInvalidToken
	}

	signature, err := decodeSegment(parts[2])
	if err != nil {
		return nil, ErrInvalidToken
	}
	mac := hmac.New(sha256.New, v.secret)
	mac.Write([]byte(parts[0] + "." + parts[1]))
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return nil, ErrInvalidToken
	}

	payloadJSON, err := decodeSegment(parts[1])
	if err != nil {
		return nil, ErrInvalidToken
	}
	var payload struct {
		Subject   string          `json:"sub"`
		Role      string          `json:"role"`
		Audience  json.RawMessage `json:"aud"`
		ExpiresAt *json.Number    `json:"exp"`
	}
	if err := json.Unmarshal(payloadJSON, &payload); err != nil {
		return nil, ErrInvalidToken
	}
	if payload.Subject == "" || payload.Role != RequiredRole {
		return nil, ErrInvalidToken
	}
	if payload.ExpiresAt == nil {
		return nil, ErrInvalidToken
	}
	exp, err := payload.ExpiresAt.Int64()
	if err != nil {
		return nil, ErrInvalidToken
	}
	expiresAt := time.Unix(exp, 0)
	if !expiresAt.After(v.now()) {
		return nil, ErrExpiredToken
	}

	audience, err := parseAudience(payload.Audience)
	if err != nil || !contains(audience, RequiredAudience) {
		return nil, ErrInvalidToken
	}

	return &Claims{
		Subject:   payload.Subject,
		Role:      payload.Role,
		Audience:  audience,
		ExpiresAt: expiresAt,
	}, nil
}

func decodeSegment(segment string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(strings.TrimRight(segment, "="))
}

func parseAudience(raw json.RawMessage) ([]string, error) {
	if len(raw) == 0 {
		return nil, errors.New("missing aud")
	}
	var single string
	if err := json.Unmarshal(raw, &single); err == nil {
		if single == "" {
			return nil, errors.New("empty aud")
		}
		return []string{single}, nil
	}
	var many []string
	if err := json.Unmarshal(raw, &many); err != nil {
		return nil, fmt.Errorf("invalid aud: %w", err)
	}
	return many, nil
}

func contains(values []string, want string) bool {
	for _, v := range values {
		if v == want {
			return true
		}
	}
	return false
}
