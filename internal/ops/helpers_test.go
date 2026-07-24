package ops

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/samay-app/samay/internal/db"
)

type requestLog struct {
	Method string
	Path   string
}

func newTestClientWithLog(respBody string, statusCode int) (*db.DBClient, *httptest.Server, *[]requestLog) {
	log := &[]requestLog{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		buf, _ := io.ReadAll(r.Body)
		_ = buf
		*log = append(*log, requestLog{
			Method: r.Method,
			Path:   r.URL.RequestURI(),
		})
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(statusCode)
		w.Write([]byte(respBody))
	}))
	c := &db.DBClient{
		BaseURL:    srv.URL,
		ServiceKey: "test-key",
		HTTP:       srv.Client(),
	}
	return c, srv, log
}

func assertContains(t *testing.T, s, substr string) {
	t.Helper()
	if !strings.Contains(s, substr) {
		t.Errorf("expected %q to contain %q", s, substr)
	}
}

func assertNotContains(t *testing.T, s, substr string) {
	t.Helper()
	if strings.Contains(s, substr) {
		t.Errorf("expected %q to NOT contain %q", s, substr)
	}
}
