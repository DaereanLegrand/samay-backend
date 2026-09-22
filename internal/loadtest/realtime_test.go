package loadtest

import (
	"context"
	"encoding/json"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

type phxFrame struct {
	Topic   string          `json:"topic"`
	Event   string          `json:"event"`
	Payload json.RawMessage `json:"payload"`
	Ref     *string         `json:"ref"`
}

func readFrame(ctx context.Context, c *websocket.Conn) (phxFrame, error) {
	var f phxFrame
	err := wsjson.Read(ctx, c, &f)
	return f, err
}

func writeFrame(ctx context.Context, c *websocket.Conn, f phxFrame) error {
	return wsjson.Write(ctx, c, f)
}

func TestRealtimeJoinAndReceive(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/realtime/v1/websocket" {
			t.Errorf("path = %q", r.URL.Path)
		}
		if r.URL.Query().Get("apikey") != "ANON" {
			t.Errorf("apikey = %q", r.URL.Query().Get("apikey"))
		}
		if r.URL.Query().Get("vsn") != "1.0.0" {
			t.Errorf("vsn = %q", r.URL.Query().Get("vsn"))
		}
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer conn.CloseNow()
		ctx := r.Context()
		f, err := readFrame(ctx, conn)
		if err != nil {
			return
		}
		if f.Event != "phx_join" || f.Topic != "realtime:messages:c1" {
			t.Errorf("join frame = %+v", f)
		}
		var payload struct {
			Config struct {
				PostgresChanges []struct {
					Event string `json:"event"`
					Table string `json:"table"`
				} `json:"postgres_changes"`
			} `json:"config"`
			AccessToken string `json:"access_token"`
		}
		if err := json.Unmarshal(f.Payload, &payload); err != nil {
			t.Errorf("join payload: %v", err)
		}
		if payload.AccessToken != "USER_JWT" {
			t.Errorf("access_token = %q", payload.AccessToken)
		}
		if len(payload.Config.PostgresChanges) != 1 || payload.Config.PostgresChanges[0].Table != "messages" {
			t.Errorf("filters = %+v", payload.Config.PostgresChanges)
		}
		ref := ""
		if f.Ref != nil {
			ref = *f.Ref
		}
		_ = writeFrame(ctx, conn, phxFrame{Topic: f.Topic, Event: "phx_reply", Ref: &ref, Payload: json.RawMessage(`{"status":"ok","response":{}}`)})
		_ = writeFrame(ctx, conn, phxFrame{
			Topic: f.Topic, Event: "postgres_changes",
			Payload: json.RawMessage(`{"data":{"type":"INSERT","table":"messages","schema":"public","record":{"id":"m1","content":"ct"}}}`),
		})
		time.Sleep(150 * time.Millisecond)
	}))
	defer srv.Close()

	cfg := &Config{URL: srv.URL, AnonKey: "ANON", Timeout: 10}
	rt, err := DialRealtime(context.Background(), cfg, "USER_JWT")
	if err != nil {
		t.Fatalf("DialRealtime: %v", err)
	}
	defer rt.Close()

	if err := rt.Join(context.Background(), "messages:c1", []ChangeFilter{{Event: "*", Table: "messages"}}); err != nil {
		t.Fatalf("Join: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	msg, err := rt.Next(ctx)
	if err != nil {
		t.Fatalf("Next: %v", err)
	}
	if msg.Topic != "realtime:messages:c1" || msg.Event != "postgres_changes" {
		t.Fatalf("msg = %+v", msg)
	}
	var data struct {
		Data struct {
			Record map[string]any `json:"record"`
		} `json:"data"`
	}
	if err := json.Unmarshal(msg.Payload, &data); err != nil {
		t.Fatalf("payload: %v", err)
	}
	if data.Data.Record["id"] != "m1" {
		t.Errorf("record = %v", data.Data.Record)
	}
}

func TestRealtimeJoinError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer conn.CloseNow()
		ctx := r.Context()
		f, err := readFrame(ctx, conn)
		if err != nil {
			return
		}
		ref := ""
		if f.Ref != nil {
			ref = *f.Ref
		}
		_ = writeFrame(ctx, conn, phxFrame{Topic: f.Topic, Event: "phx_reply", Ref: &ref, Payload: json.RawMessage(`{"status":"error","response":{"reason":"unauthorized"}}`)})
		time.Sleep(150 * time.Millisecond)
	}))
	defer srv.Close()

	cfg := &Config{URL: srv.URL, AnonKey: "ANON", Timeout: 10}
	rt, err := DialRealtime(context.Background(), cfg, "USER_JWT")
	if err != nil {
		t.Fatalf("DialRealtime: %v", err)
	}
	defer rt.Close()
	err = rt.Join(context.Background(), "messages:c1", []ChangeFilter{{Event: "*", Table: "messages"}})
	if err == nil {
		t.Fatal("want join error, got nil")
	}
	if !strings.Contains(err.Error(), "unauthorized") {
		t.Errorf("error = %q", err)
	}
}

func TestRealtimePhaseTerminates(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/realtime/") {
			conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
			if err != nil {
				return
			}
			defer conn.CloseNow()
			ctx := r.Context()
			for {
				f, err := readFrame(ctx, conn)
				if err != nil {
					return
				}
				switch f.Event {
				case "phx_join", "heartbeat":
					ref := ""
					if f.Ref != nil {
						ref = *f.Ref
					}
					topic := f.Topic
					if f.Event == "heartbeat" {
						topic = "phoenix"
					}
					if err := writeFrame(ctx, conn, phxFrame{Topic: topic, Event: "phx_reply", Ref: &ref, Payload: json.RawMessage(`{"status":"ok","response":{}}`)}); err != nil {
						return
					}
				}
			}
		}
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	cfg := &Config{URL: srv.URL, AnonKey: "ANON", ServiceKey: "SVC", Duration: time.Second, Realtime: 3, Seed: 7, Timeout: 5 * time.Second}
	ds := &Dataset{
		Users: []*Identity{
			{Index: 0, ID: "11111111-1111-4111-8111-111111111111", Token: "t1"},
			{Index: 1, ID: "22222222-2222-4222-8222-222222222222", Token: "t2"},
		},
		Chats: []string{"33333333-3333-4333-8333-333333333333"},
		Edges: [][2]int{{0, 1}},
	}
	done := make(chan RealtimeResult, 1)
	go func() {
		done <- RunRealtime(context.Background(), cfg, NewClient(cfg), ds, rand.New(rand.NewSource(1)), func(string, ...any) {})
	}()
	select {
	case res := <-done:
		if res.Clients != 3 {
			t.Errorf("clients = %d, want 3", res.Clients)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("RunRealtime did not terminate within 10s (goroutine leak)")
	}
}

func TestRealtimeHeartbeat(t *testing.T) {
	seen := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer conn.CloseNow()
		ctx := r.Context()
		f, err := readFrame(ctx, conn)
		if err != nil {
			return
		}
		seen <- f.Topic + "/" + f.Event
		ref := ""
		if f.Ref != nil {
			ref = *f.Ref
		}
		_ = writeFrame(ctx, conn, phxFrame{Topic: "phoenix", Event: "phx_reply", Ref: &ref, Payload: json.RawMessage(`{"status":"ok","response":{}}`)})
		time.Sleep(150 * time.Millisecond)
	}))
	defer srv.Close()

	cfg := &Config{URL: srv.URL, AnonKey: "ANON", Timeout: 10}
	rt, err := DialRealtime(context.Background(), cfg, "USER_JWT")
	if err != nil {
		t.Fatalf("DialRealtime: %v", err)
	}
	defer rt.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := rt.Heartbeat(ctx); err != nil {
		t.Fatalf("Heartbeat: %v", err)
	}
	select {
	case got := <-seen:
		if got != "phoenix/heartbeat" {
			t.Errorf("heartbeat topic/event = %q", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("server never saw heartbeat")
	}
}
