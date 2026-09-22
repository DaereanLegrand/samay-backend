package loadtest

import (
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// uuidFor derives a stable, RFC-4122-shaped UUID from the given parts. Used so
// a given run-id always produces the same object ids (re-runs are inspectable)
// without pulling a UUID dependency.
func uuidFor(parts ...string) string {
	sum := sha1.Sum([]byte(strings.Join(parts, ":")))
	b := sum[:16]
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant 10
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// mintJWT signs an HS256 JWT for a user, mirroring the claims GoTrue issues
// (aud/role/sub/email). Only used when a target JWT secret is supplied.
func mintJWT(secret, sub, email string, ttl time.Duration) (string, error) {
	now := time.Now()
	header := map[string]any{"alg": "HS256", "typ": "JWT"}
	claims := map[string]any{
		"aud":        "authenticated",
		"role":       "authenticated",
		"sub":        sub,
		"email":      email,
		"iat":        now.Unix(),
		"exp":        now.Add(ttl).Unix(),
		"session_id": uuidFor("session", sub, fmt.Sprint(now.Unix())),
	}
	return signHS256(secret, header, claims)
}

func signHS256(secret string, header, claims map[string]any) (string, error) {
	hb, err := json.Marshal(header)
	if err != nil {
		return "", fmt.Errorf("marshal jwt header: %w", err)
	}
	cb, err := json.Marshal(claims)
	if err != nil {
		return "", fmt.Errorf("marshal jwt claims: %w", err)
	}
	enc := func(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }
	signingInput := enc(hb) + "." + enc(cb)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(signingInput))
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

// publicURL builds the public storage URL for an object in a public bucket.
func publicURL(baseURL, bucket, path string) string {
	return strings.TrimRight(baseURL, "/") + "/storage/v1/object/public/" + bucket + "/" + path
}
