package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"testing"
	"time"
)

func b64(data []byte) string {
	return base64.RawURLEncoding.EncodeToString(data)
}

func sign(t *testing.T, secret string, claims map[string]any) string {
	t.Helper()
	headerJSON, _ := json.Marshal(map[string]any{"alg": "HS256", "typ": "JWT"})
	payloadJSON, _ := json.Marshal(claims)
	input := b64(headerJSON) + "." + b64(payloadJSON)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(input))
	return input + "." + b64(mac.Sum(nil))
}

func validClaims() map[string]any {
	now := time.Now().Unix()
	return map[string]any{
		"sub":  "00000000-0000-4000-8000-000000000001",
		"role": "authenticated",
		"aud":  "authenticated",
		"iat":  now,
		"exp":  now + 3600,
	}
}

func TestVerify_ValidToken(t *testing.T) {
	v, err := NewVerifier("secret")
	if err != nil {
		t.Fatal(err)
	}
	claims, err := v.Verify(sign(t, "secret", validClaims()))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if claims.Subject != "00000000-0000-4000-8000-000000000001" {
		t.Errorf("subject = %q", claims.Subject)
	}
	if claims.Role != RequiredRole {
		t.Errorf("role = %q", claims.Role)
	}
}

func TestVerify_AcceptsAudienceArray(t *testing.T) {
	v, _ := NewVerifier("secret")
	claims := validClaims()
	claims["aud"] = []string{"other", "authenticated"}
	if _, err := v.Verify(sign(t, "secret", claims)); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestVerify_RejectsInvalidTokens(t *testing.T) {
	v, _ := NewVerifier("secret")
	now := time.Now().Unix()

	cases := []struct {
		name   string
		token  string
		claims map[string]any
	}{
		{"expired", "", map[string]any{"exp": now - 1}},
		{"missing exp", "", map[string]any{"exp": nil}},
		{"wrong audience", "", map[string]any{"aud": "other"}},
		{"missing audience", "", map[string]any{"aud": nil}},
		{"anon role", "", map[string]any{"role": "anon"}},
		{"service role", "", map[string]any{"role": "service_role"}},
		{"missing sub", "", map[string]any{"sub": ""}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			claims := validClaims()
			for k, val := range tc.claims {
				claims[k] = val
			}
			if _, err := v.Verify(sign(t, "secret", claims)); err == nil {
				t.Fatal("expected token to be rejected")
			}
		})
	}
}

func TestVerify_RejectsBadSignature(t *testing.T) {
	v, _ := NewVerifier("secret")
	token := sign(t, "other-secret", validClaims())
	if _, err := v.Verify(token); err == nil {
		t.Fatal("expected signature mismatch to be rejected")
	}
}

func TestVerify_RejectsNoneAlgorithm(t *testing.T) {
	v, _ := NewVerifier("secret")
	header := b64([]byte(`{"alg":"none","typ":"JWT"}`))
	payload := b64([]byte(`{"sub":"x","role":"authenticated","aud":"authenticated","exp":9999999999}`))
	if _, err := v.Verify(header + "." + payload + "."); err == nil {
		t.Fatal("expected alg=none to be rejected")
	}
}

func TestVerify_RejectsMalformed(t *testing.T) {
	v, _ := NewVerifier("secret")
	for _, token := range []string{"", "a", "a.b", "a.b.c.d", "..", "!!!.???.$$$"} {
		if _, err := v.Verify(token); err == nil {
			t.Errorf("expected %q to be rejected", token)
		}
	}
}

func TestNewVerifier_RejectsEmptySecret(t *testing.T) {
	if _, err := NewVerifier("  "); err == nil {
		t.Fatal("expected empty secret to be rejected")
	}
}
