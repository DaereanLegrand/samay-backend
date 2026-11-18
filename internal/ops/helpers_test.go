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
	Body   string
}

func newTestClientWithLog(respBody string, statusCode int) (*db.DBClient, *httptest.Server, *[]requestLog) {
	log := &[]requestLog{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		buf, _ := io.ReadAll(r.Body)
		*log = append(*log, requestLog{
			Method: r.Method,
			Path:   r.URL.RequestURI(),
			Body:   string(buf),
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

// newRoutingClient serves per-table responses keyed by path prefix (e.g.
// "/rest/v1/events"); requests that match no route fail loudly with 500 so
// unexpected tables surface in tests.
func newRoutingClient(responses map[string]string) (*db.DBClient, *httptest.Server, *[]requestLog) {
	log := &[]requestLog{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		buf, _ := io.ReadAll(r.Body)
		*log = append(*log, requestLog{
			Method: r.Method,
			Path:   r.URL.RequestURI(),
			Body:   string(buf),
		})
		w.Header().Set("Content-Type", "application/json")
		body, ok := responses[r.URL.Path]
		if !ok {
			w.WriteHeader(http.StatusInternalServerError)
			w.Write([]byte(`{"error":"unexpected route"}`))
			return
		}
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(body))
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

func countRequests(log *[]requestLog, method, pathSubstr string) int {
	n := 0
	for _, r := range *log {
		if r.Method == method && strings.Contains(r.Path, pathSubstr) {
			n++
		}
	}
	return n
}

func lastRequest(log *[]requestLog) requestLog {
	return (*log)[len(*log)-1]
}

func firstRequestOf(log *[]requestLog, method, pathSubstr string) requestLog {
	for _, r := range *log {
		if r.Method == method && strings.Contains(r.Path, pathSubstr) {
			return r
		}
	}
	return requestLog{}
}
