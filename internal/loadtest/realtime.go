package loadtest

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// ChangeFilter is one Postgres-changes subscription filter in a join payload.
type ChangeFilter struct {
	Event  string `json:"event"`
	Schema string `json:"schema"`
	Table  string `json:"table"`
}

// Message is one decoded Phoenix frame from the Realtime socket.
type Message struct {
	Topic   string
	Event   string
	Payload json.RawMessage
	Ref     *string
}

// RealtimeClient speaks the Supabase Realtime (Phoenix channels v1) protocol
// over a websocket. A client is intended to be driven from a single goroutine
// (Join, then Next in a loop, with periodic Heartbeat), though calls are
// mutex-guarded.
type RealtimeClient struct {
	conn   *websocket.Conn
	token  string
	mu     sync.Mutex
	ref    int64
	queued []Message
}

// DialRealtime connects to the realtime gateway as the given user token.
func DialRealtime(ctx context.Context, cfg *Config, token string) (*RealtimeClient, error) {
	url := cfg.RealtimeURL()
	if url == "" {
		return nil, fmt.Errorf("could not derive realtime URL from %q", cfg.URL)
	}
	dialCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	opts := &websocket.DialOptions{HTTPHeader: map[string][]string{"apikey": {cfg.AnonKey}}}
	conn, _, err := websocket.Dial(dialCtx, url, opts)
	if err != nil {
		return nil, fmt.Errorf("dial realtime: %w", err)
	}
	conn.SetReadLimit(16 << 20)
	return &RealtimeClient{conn: conn, token: token}, nil
}

func (c *RealtimeClient) nextRef() string {
	c.ref++
	return fmt.Sprintf("%d", c.ref)
}

func (c *RealtimeClient) write(ctx context.Context, topic, event string, payload any, ref string) error {
	frame := map[string]any{"topic": topic, "event": event, "payload": payload}
	if ref != "" {
		frame["ref"] = ref
	} else {
		frame["ref"] = nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return wsjson.Write(ctx, c.conn, frame)
}

func (c *RealtimeClient) readFrame(ctx context.Context) (Message, error) {
	var f struct {
		Topic   string          `json:"topic"`
		Event   string          `json:"event"`
		Payload json.RawMessage `json:"payload"`
		Ref     *string         `json:"ref"`
	}
	if err := wsjson.Read(ctx, c.conn, &f); err != nil {
		return Message{}, err
	}
	return Message{Topic: f.Topic, Event: f.Event, Payload: f.Payload, Ref: f.Ref}, nil
}

// Join subscribes to channel (without the "realtime:" prefix) with the given
// postgres_changes filters and waits for the server acknowledgement.
func (c *RealtimeClient) Join(ctx context.Context, channel string, filters []ChangeFilter) error {
	topic := "realtime:" + channel
	if filters == nil {
		filters = []ChangeFilter{}
	}
	payload := map[string]any{
		"config": map[string]any{
			"broadcast":        map[string]any{"self": false},
			"presence":         map[string]any{"key": ""},
			"postgres_changes": filters,
			"private":          false,
		},
		"access_token": c.token,
	}
	ref := c.nextRef()
	if err := c.write(ctx, topic, "phx_join", payload, ref); err != nil {
		return err
	}
	for {
		msg, err := c.readFrame(ctx)
		if err != nil {
			return fmt.Errorf("join %s: %w", channel, err)
		}
		if msg.Event == "phx_reply" && msg.Ref != nil && *msg.Ref == ref {
			var reply struct {
				Status   string          `json:"status"`
				Response json.RawMessage `json:"response"`
			}
			_ = json.Unmarshal(msg.Payload, &reply)
			if reply.Status != "ok" {
				return fmt.Errorf("join %s declined: %s", channel, string(reply.Response))
			}
			return nil
		}
		c.queued = append(c.queued, msg)
	}
}

// Next returns the next inbound message, buffering any frames read while
// awaiting a join/heartbeat reply.
func (c *RealtimeClient) Next(ctx context.Context) (Message, error) {
	if len(c.queued) > 0 {
		msg := c.queued[0]
		c.queued = c.queued[1:]
		return msg, nil
	}
	return c.readFrame(ctx)
}

// Heartbeat sends a Phoenix heartbeat and waits for its acknowledgement.
func (c *RealtimeClient) Heartbeat(ctx context.Context) error {
	ref := c.nextRef()
	if err := c.write(ctx, "phoenix", "heartbeat", map[string]any{}, ref); err != nil {
		return err
	}
	for {
		msg, err := c.readFrame(ctx)
		if err != nil {
			return fmt.Errorf("heartbeat: %w", err)
		}
		if msg.Event == "phx_reply" && msg.Ref != nil && *msg.Ref == ref {
			return nil
		}
		c.queued = append(c.queued, msg)
	}
}

// Close closes the underlying websocket.
func (c *RealtimeClient) Close() error {
	return c.conn.Close(websocket.StatusNormalClosure, "")
}
