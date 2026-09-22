package loadtest

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func newTestClient(t *testing.T, h http.Handler) (*Client, *httptest.Server) {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return NewClient(&Config{URL: srv.URL, AnonKey: "ANON", ServiceKey: "SERVICE", Timeout: 10 * time.Second}), srv
}

func TestAdminCreateUser(t *testing.T) {
	var gotPath, gotAuth, gotBody string
	c, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":"id-1"}`)
	}))

	if err := c.AdminCreateUser(context.Background(), "id-1", "a@b.c", "pw"); err != nil {
		t.Fatalf("AdminCreateUser: %v", err)
	}
	if gotPath != "/auth/v1/admin/users" {
		t.Errorf("path = %q", gotPath)
	}
	if gotAuth != "Bearer SERVICE" {
		t.Errorf("auth = %q", gotAuth)
	}
	var body map[string]any
	if err := json.Unmarshal([]byte(gotBody), &body); err != nil {
		t.Fatalf("body: %v", err)
	}
	if body["email"] != "a@b.c" || body["email_confirm"] != true || body["id"] != "id-1" {
		t.Errorf("body = %v", body)
	}
}

func TestPasswordLogin(t *testing.T) {
	var path, apikey string
	c, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.Path + "?" + r.URL.RawQuery
		apikey = r.Header.Get("apikey")
		fmt.Fprint(w, `{"access_token":"AT","refresh_token":"RT"}`)
	}))
	access, refresh, err := c.PasswordLogin(context.Background(), "a@b.c", "pw")
	if err != nil {
		t.Fatalf("PasswordLogin: %v", err)
	}
	if access != "AT" || refresh != "RT" {
		t.Errorf("tokens = %q/%q", access, refresh)
	}
	if path != "/auth/v1/token?grant_type=password" {
		t.Errorf("path = %q", path)
	}
	if apikey != "ANON" {
		t.Errorf("apikey = %q", apikey)
	}
}

func TestRefresh(t *testing.T) {
	c, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("grant_type") != "refresh_token" {
			t.Errorf("grant_type = %q", r.URL.Query().Get("grant_type"))
		}
		fmt.Fprint(w, `{"access_token":"AT2"}`)
	}))
	access, err := c.Refresh(context.Background(), "RT")
	if err != nil {
		t.Fatalf("Refresh: %v", err)
	}
	if access != "AT2" {
		t.Errorf("access = %q", access)
	}
}

func TestGetSendsKeys(t *testing.T) {
	var apikey, auth string
	c, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		apikey = r.Header.Get("apikey")
		auth = r.Header.Get("Authorization")
		fmt.Fprint(w, `[{"id":1}]`)
	}))
	status, body, err := c.Get(context.Background(), "/rest/v1/events?select=id", "JWT")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if status != 200 || string(body) != `[{"id":1}]` {
		t.Errorf("status/body = %d/%s", status, body)
	}
	if apikey != "ANON" || auth != "Bearer JWT" {
		t.Errorf("headers = %q/%q", apikey, auth)
	}
}

func TestInsertPreferMinimal(t *testing.T) {
	var prefer, body string
	c, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		prefer = r.Header.Get("Prefer")
		b, _ := io.ReadAll(r.Body)
		body = string(b)
		w.WriteHeader(http.StatusCreated)
	}))
	if err := c.Insert(context.Background(), "friendships", map[string]any{"requester_id": "x"}, "JWT"); err != nil {
		t.Fatalf("Insert: %v", err)
	}
	if prefer != "return=minimal" {
		t.Errorf("Prefer = %q", prefer)
	}
	if body != `{"requester_id":"x"}` {
		t.Errorf("body = %q", body)
	}
}

func TestRPC(t *testing.T) {
	var path, body string
	c, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.Path
		b, _ := io.ReadAll(r.Body)
		body = string(b)
		fmt.Fprint(w, `{"status":"ok"}`)
	}))
	out, err := c.RPC(context.Background(), "create_direct_chat", map[string]any{"p_peer_id": "p"}, "JWT")
	if err != nil {
		t.Fatalf("RPC: %v", err)
	}
	if path != "/rest/v1/rpc/create_direct_chat" {
		t.Errorf("path = %q", path)
	}
	if body != `{"p_peer_id":"p"}` {
		t.Errorf("body = %q", body)
	}
	var decoded map[string]string
	if err := json.Unmarshal(out, &decoded); err != nil || decoded["status"] != "ok" {
		t.Errorf("out = %s (%v)", out, err)
	}
}

func TestStorageUpload(t *testing.T) {
	var path, ctype, auth string
	var data []byte
	c, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.Path
		ctype = r.Header.Get("Content-Type")
		auth = r.Header.Get("Authorization")
		data, _ = io.ReadAll(r.Body)
		fmt.Fprint(w, `{"Key":"k"}`)
	}))
	if err := c.StorageUpload(context.Background(), "avatars", "u1/a.jpg", []byte("jpegdata"), "image/jpeg", "JWT"); err != nil {
		t.Fatalf("StorageUpload: %v", err)
	}
	if path != "/storage/v1/object/avatars/u1/a.jpg" {
		t.Errorf("path = %q", path)
	}
	if ctype != "image/jpeg" || auth != "Bearer JWT" {
		t.Errorf("headers = %q/%q", ctype, auth)
	}
	if string(data) != "jpegdata" {
		t.Errorf("data = %q", data)
	}
}

func TestErrorIncludesStatus(t *testing.T) {
	c, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"message":"nope"}`, http.StatusBadRequest)
	}))
	_, _, err := c.Get(context.Background(), "/rest/v1/x", "JWT")
	if err == nil {
		t.Fatal("want error, got nil")
	}
	if got := fmt.Sprint(err); !strings.Contains(got, "400") || !strings.Contains(got, "nope") {
		t.Errorf("error = %q", got)
	}
}
