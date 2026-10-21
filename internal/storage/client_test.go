package storage

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDeleteObjectSendsServiceRoleCredentials(t *testing.T) {
	var gotMethod, gotPath, gotAuth, gotAPIKey string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.EscapedPath()
		gotAuth = r.Header.Get("Authorization")
		gotAPIKey = r.Header.Get("apikey")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"message":"Successfully deleted"}`))
	}))
	defer srv.Close()

	c := &Client{BaseURL: srv.URL, ServiceKey: "svc-key", HTTP: srv.Client()}
	if err := c.DeleteObject(context.Background(), "events", "e1/photos/a b.jpg"); err != nil {
		t.Fatalf("DeleteObject: %v", err)
	}
	if gotMethod != http.MethodDelete {
		t.Fatalf("method = %q", gotMethod)
	}
	if gotPath != "/storage/v1/object/events/e1/photos/a%20b.jpg" {
		t.Fatalf("path = %q", gotPath)
	}
	if gotAuth != "Bearer svc-key" {
		t.Fatalf("authorization = %q", gotAuth)
	}
	if gotAPIKey != "svc-key" {
		t.Fatalf("apikey = %q", gotAPIKey)
	}
}

func TestDeleteObjectTreatsMissingObjectAsSuccess(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
	}{
		{"nosuchkey", http.StatusBadRequest, `{"error":"NoSuchKey"}`},
		{"not_found", http.StatusNotFound, `{"statusCode":"404","error":"not_found","message":"Object not found"}`},
		{"object not found", http.StatusBadRequest, `{"message":"Object not found"}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/storage/v1/bucket/") {
					w.WriteHeader(http.StatusOK)
					_, _ = w.Write([]byte(`{"id":"events"}`))
					return
				}
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()
			c := &Client{BaseURL: srv.URL, ServiceKey: "k", HTTP: srv.Client()}
			if err := c.DeleteObject(context.Background(), "events", "e1/x.jpg"); err != nil {
				t.Fatalf("expected success, got %v", err)
			}
		})
	}
}

func TestDeleteObjectMissingBucketIsNotSuccess(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/storage/v1/bucket/") {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"statusCode":"404","error":"Bucket not found","message":"Bucket not found"}`))
			return
		}
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"statusCode":"404","error":"NoSuchKey","message":"Object not found"}`))
	}))
	defer srv.Close()
	c := &Client{BaseURL: srv.URL, ServiceKey: "k", HTTP: srv.Client()}
	err := c.DeleteObject(context.Background(), "safety-missing-bucket", "x.bin")
	if err == nil || !strings.Contains(err.Error(), "bucket not found") {
		t.Fatalf("expected bucket error, got %v", err)
	}
}

func TestDeleteObjectNeverTreatsMissingBucketAsSuccess(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
	}{
		{"nosuchbucket", http.StatusBadRequest, `{"error":"NoSuchBucket","message":"Bucket not found"}`},
		{"bucket not found", http.StatusNotFound, `{"message":"Bucket not found"}`},
		{"bucket_not_found", http.StatusBadRequest, `{"error":"bucket_not_found"}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()
			c := &Client{BaseURL: srv.URL, ServiceKey: "k", HTTP: srv.Client()}
			err := c.DeleteObject(context.Background(), "events", "e1/x.jpg")
			if err == nil || !strings.Contains(err.Error(), "bucket not found") {
				t.Fatalf("expected bucket error, got %v", err)
			}
		})
	}
}

func TestDeleteObjectSurfacesServerErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"message":"boom"}`))
	}))
	defer srv.Close()
	c := &Client{BaseURL: srv.URL, ServiceKey: "k", HTTP: srv.Client()}
	err := c.DeleteObject(context.Background(), "events", "e1/x.jpg")
	if err == nil || !strings.Contains(err.Error(), "500") {
		t.Fatalf("expected server error, got %v", err)
	}
}

func TestValidateObjectRef(t *testing.T) {
	bad := []struct{ bucket, object string }{
		{"", "a.jpg"},
		{"events", ""},
		{"../events", "a.jpg"},
		{"events", "/a.jpg"},
		{"events", "a/../b.jpg"},
		{"events", "a//b.jpg"},
		{"events", "a\nb.jpg"},
		{"bad bucket", "a.jpg"},
	}
	for _, tc := range bad {
		if err := validateObjectRef(tc.bucket, tc.object); err == nil {
			t.Errorf("validateObjectRef(%q, %q) = nil, want error", tc.bucket, tc.object)
		}
	}
	good := []struct{ bucket, object string }{
		{"events", "e1/a.jpg"},
		{"minigame_images", "s/1/x.bin"},
		{"avatars", "user-id/avatar.png"},
	}
	for _, tc := range good {
		if err := validateObjectRef(tc.bucket, tc.object); err != nil {
			t.Errorf("validateObjectRef(%q, %q) = %v", tc.bucket, tc.object, err)
		}
	}
}
