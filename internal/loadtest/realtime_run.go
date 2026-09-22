package loadtest

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand"
	"strconv"
	"sync"
	"time"
)

// RealtimeResult summarizes the realtime phase.
type RealtimeResult struct {
	Clients  int           `json:"clients"`
	Stats    RealtimeStats `json:"stats"`
	Delivery LatencyStats  `json:"delivery"`
	Errors   []string      `json:"errors"`
}

// outbox correlates a write timestamp with the realtime delivery of that row.
type outbox struct{ m sync.Map }

func (o *outbox) mark(key string) { o.m.Store(key, time.Now()) }

func (o *outbox) take(key string) (time.Duration, bool) {
	v, ok := o.m.LoadAndDelete(key)
	if !ok {
		return 0, false
	}
	return time.Since(v.(time.Time)), true
}

type subscription struct {
	token   string
	channel string
	filters []ChangeFilter
}

// RunRealtime drives cfg.Realtime websocket subscribers while a small set of
// generators produce activity, measuring join success and delivery latency.
func RunRealtime(ctx context.Context, cfg *Config, c *Client, ds *Dataset, rng *rand.Rand, logf func(string, ...any)) RealtimeResult {
	res := RealtimeResult{}
	subs := buildSubscriptions(cfg, ds, rng)
	if len(subs) == 0 {
		logf("realtime: no subscriptions available (seed first)")
		return res
	}
	if len(subs) < cfg.Realtime {
		logf("realtime: only %d distinct subscriptions for %d clients", len(subs), cfg.Realtime)
	}
	res.Clients = cfg.Realtime

	// The phase runs for cfg.Duration; derive a cancellable context so every
	// subscriber/generator stops when the window closes (otherwise wg.Wait
	// would block on the still-subscribed sockets forever).
	rctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var counter RealtimeCounter
	var hist LatencyHistogram
	box := &outbox{}
	var errMu sync.Mutex
	addErr := func(err error) {
		if err == nil {
			return
		}
		errMu.Lock()
		defer errMu.Unlock()
		if len(res.Errors) < 30 {
			res.Errors = append(res.Errors, err.Error())
		}
	}

	var wg sync.WaitGroup
	for i := 0; i < cfg.Realtime; i++ {
		sub := subs[i%len(subs)]
		wg.Add(1)
		go func(sub subscription) {
			defer wg.Done()
			runSubscriber(rctx, cfg, sub, &counter, &hist, box, addErr)
		}(sub)
	}

	// Activity generators: writes that should produce realtime events.
	genCount := 3
	if cfg.Duration < 10*time.Second {
		genCount = 1
	}
	for g := 0; g < genCount; g++ {
		wg.Add(1)
		go func(seed int64) {
			defer wg.Done()
			runGenerator(rctx, cfg, c, ds, rand.New(rand.NewSource(seed)), box, logf)
		}(cfg.Seed + int64(g)*104729)
	}

	select {
	case <-ctx.Done():
	case <-time.After(cfg.Duration):
	}
	cancel()
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		addErr(fmt.Errorf("realtime shutdown timed out"))
	}

	res.Stats = counter.Snapshot()
	res.Delivery = hist.Stats()
	return res
}

func buildSubscriptions(cfg *Config, ds *Dataset, rng *rand.Rand) []subscription {
	var subs []subscription
	// Chat message channels (the richest realtime surface): subscribe as a
	// participant so RLS delivers the inserts.
	for i, cid := range ds.Chats {
		if i >= len(ds.Edges) {
			break
		}
		users := ds.Users
		a, b := ds.Edges[i][0], ds.Edges[i][1]
		if a >= len(users) || b >= len(users) {
			break
		}
		pick := a
		if i%2 == 1 {
			pick = b
		}
		token := users[pick].Token
		if token == "" {
			token = cfg.AnonKey
		}
		subs = append(subs, subscription{
			token:   token,
			channel: "messages:" + cid,
			filters: []ChangeFilter{{Event: "INSERT", Schema: "public", Table: "messages"}},
		})
	}
	// Friendships and minigame-session channels for variety.
	for _, u := range ds.Users {
		token := u.Token
		if token == "" {
			token = cfg.AnonKey
		}
		subs = append(subs, subscription{
			token:   token,
			channel: "friendships:" + u.ID,
			filters: []ChangeFilter{{Event: "*", Schema: "public", Table: "friendships"}},
		})
	}
	for _, mid := range append(append([]string{}, ds.Matches...), ds.ActiveMatches...) {
		token := cfg.AnonKey
		if len(ds.Users) > 0 {
			if t := ds.Users[rng.Intn(len(ds.Users))].Token; t != "" {
				token = t
			}
		}
		subs = append(subs, subscription{
			token:   token,
			channel: "minigame-sessions:" + mid,
			filters: []ChangeFilter{{Event: "*", Schema: "public", Table: "minigame_sessions"}},
		})
	}
	return subs
}

func runSubscriber(ctx context.Context, cfg *Config, sub subscription, counter *RealtimeCounter, hist *LatencyHistogram, box *outbox, addErr func(error)) {
	backoff := 500 * time.Millisecond
	for ctx.Err() == nil {
		err := subscribeOnce(ctx, cfg, sub, counter, hist, box)
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			addErr(err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			if backoff < 8*time.Second {
				backoff *= 2
			}
			continue
		}
		backoff = 500 * time.Millisecond
	}
}

func subscribeOnce(ctx context.Context, cfg *Config, sub subscription, counter *RealtimeCounter, hist *LatencyHistogram, box *outbox) error {
	rt, err := DialRealtime(ctx, cfg, sub.token)
	if err != nil {
		return err
	}
	defer rt.Close()
	if err := rt.Join(ctx, sub.channel, sub.filters); err != nil {
		counter.Declined()
		return err
	}
	counter.Joined()

	events := make(chan Message, 64)
	readErr := make(chan error, 1)
	go func() {
		for {
			msg, err := rt.Next(ctx)
			if err != nil {
				select {
				case readErr <- err:
				default:
				}
				return
			}
			select {
			case events <- msg:
			case <-ctx.Done():
				return
			}
		}
	}()

	hb := time.NewTicker(25 * time.Second)
	defer hb.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-readErr:
			return err
		case <-hb.C:
			if err := rt.Heartbeat(ctx); err != nil {
				return err
			}
		case msg := <-events:
			if msg.Event != "postgres_changes" {
				continue
			}
			counter.Event()
			if d, ok := deliveryLatency(msg, box); ok {
				hist.Observe(d)
			}
		}
	}
}

func deliveryLatency(msg Message, box *outbox) (time.Duration, bool) {
	var payload struct {
		Data struct {
			Table  string         `json:"table"`
			Record map[string]any `json:"record"`
		} `json:"data"`
	}
	if err := json.Unmarshal(msg.Payload, &payload); err != nil {
		return 0, false
	}
	id, _ := payload.Data.Record["id"].(string)
	if id == "" || payload.Data.Table == "" {
		return 0, false
	}
	return box.take(payload.Data.Table + ":" + id)
}

func runGenerator(ctx context.Context, cfg *Config, c *Client, ds *Dataset, rng *rand.Rand, box *outbox, logf func(string, ...any)) {
	if len(ds.Chats) == 0 && len(ds.Users) < 2 {
		return
	}
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	seq := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		seq++
		if len(ds.Chats) > 0 {
			cid := ds.Chats[rng.Intn(len(ds.Chats))]
			sender := ds.Users[rng.Intn(len(ds.Users))]
			recipient := ds.Users[rng.Intn(len(ds.Users))]
			id := uuidFor("rtmsg", cfg.RunID, strconv.Itoa(seq), strconv.FormatInt(time.Now().UnixNano(), 36))
			box.mark("messages:" + id)
			_ = c.Insert(ctx, "messages", map[string]any{
				"id": id, "chat_id": cid, "sender_id": sender.ID,
				"recipient_id": recipient.ID, "content": ciphertext(rng, 32),
			}, c.ServiceKey)
		}
		if len(ds.Users) >= 2 {
			a := ds.Users[rng.Intn(len(ds.Users))]
			b := ds.Users[rng.Intn(len(ds.Users))]
			if a.ID != b.ID {
				id := uuidFor("rtfriend", cfg.RunID, strconv.Itoa(seq), strconv.FormatInt(time.Now().UnixNano(), 36))
				box.mark("friendships:" + id)
				_ = c.Insert(ctx, "friendships", map[string]any{
					"id": id, "requester_id": a.ID, "addressee_id": b.ID, "status": "pending",
				}, c.ServiceKey)
			}
		}
	}
}
