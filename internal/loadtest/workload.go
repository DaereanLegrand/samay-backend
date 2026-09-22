package loadtest

import (
	"context"
	"fmt"
	"math/rand"
	"strconv"
	"sync"
	"time"
)

type loadOp struct {
	name      string
	weight    int
	needsAuth bool
	fn        func(ctx context.Context, c *Client, ds *Dataset, rng *rand.Rand, token string, actor *Identity) error
}

// RunLoad drives the concurrent read/write workload until the duration ends.
func RunLoad(ctx context.Context, cfg *Config, c *Client, ds *Dataset, rec *Recorder, logf func(string, ...any)) {
	if len(ds.Users) == 0 {
		logf("no users available — skipping load phase")
		return
	}
	authed := ds.Users[0].Token != ""
	ops := loadOps()
	if !authed {
		filtered := ops[:0]
		for _, op := range ops {
			if !op.needsAuth {
				filtered = append(filtered, op)
			}
		}
		ops = filtered
		logf("no user tokens — running service/anon-only load ops")
	}
	deadline := time.Now().Add(cfg.Duration)
	var wg sync.WaitGroup
	for w := 0; w < cfg.Workers; w++ {
		wg.Add(1)
		go func(seed int64) {
			defer wg.Done()
			rng := rand.New(rand.NewSource(seed))
			for time.Now().Before(deadline) && ctx.Err() == nil {
				op := chooseOp(ops, rng)
				u := ds.userByIndex(rng.Intn(len(ds.Users)))
				token := u.Token
				if token == "" {
					token = c.ServiceKey
				}
				start := time.Now()
				err := op.fn(ctx, c, ds, rng, token, u)
				rec.Record(op.name, time.Since(start), err)
			}
		}(cfg.Seed + int64(w)*7919)
	}
	wg.Wait()
}

func chooseOp(ops []loadOp, rng *rand.Rand) loadOp {
	weights := make([]int, len(ops))
	for i, op := range ops {
		weights[i] = op.weight
	}
	return ops[PickWeighted(weights, rng.Intn(100000))]
}

func loadOps() []loadOp {
	return []loadOp{
		{name: "read:ranking", weight: 8, fn: func(ctx context.Context, c *Client, ds *Dataset, rng *rand.Rand, token string, actor *Identity) error {
			_, err := c.RPC(ctx, "get_user_ranking", map[string]any{"p_limit": 50}, token)
			return err
		}},
		{name: "read:inbox", weight: 6, fn: func(ctx context.Context, c *Client, ds *Dataset, rng *rand.Rand, token string, actor *Identity) error {
			_, err := c.RPC(ctx, "get_chat_inbox", map[string]any{}, token)
			return err
		}},
		{name: "read:group_members", weight: 6, fn: func(ctx context.Context, c *Client, ds *Dataset, rng *rand.Rand, token string, actor *Identity) error {
			if len(ds.Groups) == 0 {
				return nil
			}
			gid := ds.Groups[rng.Intn(len(ds.Groups))]
			_, _, err := c.Get(ctx, "/rest/v1/group_members?group_id=eq."+gid+"&select=user_id,role&limit=50", token)
			return err
		}},
		{name: "read:event_list", weight: 8, fn: func(ctx context.Context, c *Client, ds *Dataset, rng *rand.Rand, token string, actor *Identity) error {
			_, _, err := c.Get(ctx, "/rest/v1/events?select=id,name,status,starts_at&limit=20", token)
			return err
		}},
		{name: "read:friend_profiles", weight: 4, fn: func(ctx context.Context, c *Client, ds *Dataset, rng *rand.Rand, token string, actor *Identity) error {
			ids := make([]string, 0, 5)
			for i := 0; i < 5 && i < len(ds.Users); i++ {
				ids = append(ids, ds.Users[rng.Intn(len(ds.Users))].ID)
			}
			_, err := c.RPC(ctx, "get_friend_profiles", map[string]any{"p_user_ids": ids}, token)
			return err
		}},
		{name: "read:chat_messages", weight: 6, fn: func(ctx context.Context, c *Client, ds *Dataset, rng *rand.Rand, token string, actor *Identity) error {
			if len(ds.Chats) == 0 {
				return nil
			}
			cid := ds.Chats[rng.Intn(len(ds.Chats))]
			_, _, err := c.Get(ctx, "/rest/v1/messages?chat_id=eq."+cid+"&select=id,created_at&limit=30", token)
			return err
		}},
		{name: "read:search", weight: 1, fn: func(ctx context.Context, c *Client, ds *Dataset, rng *rand.Rand, token string, actor *Identity) error {
			_, err := c.RPC(ctx, "search_users", map[string]any{"p_query": "ld" + strconv.Itoa(rng.Intn(100000))}, token)
			return err
		}},
		{name: "write:message", weight: 8, fn: func(ctx context.Context, c *Client, ds *Dataset, rng *rand.Rand, token string, actor *Identity) error {
			if len(ds.Chats) == 0 || len(ds.Users) < 2 {
				return nil
			}
			chats := ds.UserChats[actor.ID]
			if len(chats) == 0 {
				return nil
			}
			cid := chats[rng.Intn(len(chats))]
			recipient := ds.Users[rng.Intn(len(ds.Users))]
			if recipient.ID == actor.ID {
				return nil
			}
			return c.Insert(ctx, "messages", map[string]any{
				"id":           uuidFor("msg", strconv.FormatInt(time.Now().UnixNano(), 10), strconv.Itoa(rng.Intn(1<<30))),
				"chat_id":      cid,
				"sender_id":    actor.ID,
				"recipient_id": recipient.ID,
				"content":      ciphertext(rng, 48),
			}, token)
		}},
		{name: "write:friend_request", weight: 4, fn: func(ctx context.Context, c *Client, ds *Dataset, rng *rand.Rand, token string, actor *Identity) error {
			if len(ds.Users) < 2 {
				return nil
			}
			a := actor
			b := ds.Users[rng.Intn(len(ds.Users))]
			if a.ID == b.ID {
				return nil
			}
			return c.Insert(ctx, "friendships", map[string]any{
				"id":           uuidFor("friend", strconv.FormatInt(time.Now().UnixNano(), 10), strconv.Itoa(rng.Intn(1<<30))),
				"requester_id": a.ID,
				"addressee_id": b.ID,
				"status":       "pending",
			}, token)
		}},
		{name: "write:profile", weight: 4, needsAuth: true, fn: func(ctx context.Context, c *Client, ds *Dataset, rng *rand.Rand, token string, actor *Identity) error {
			_, err := c.RPC(ctx, "update_my_profile", map[string]any{
				"p_bio":           fmt.Sprintf("bio-%d", rng.Intn(1_000_000)),
				"p_date_of_birth": nil,
			}, token)
			return err
		}},
		{name: "write:create_match", weight: 3, needsAuth: true, fn: func(ctx context.Context, c *Client, ds *Dataset, rng *rand.Rand, token string, actor *Identity) error {
			gt := gameTypes[rng.Intn(len(gameTypes))]
			mode := "by_turns"
			if allowsAsync(gt) && rng.Intn(2) == 0 {
				mode = "async"
			}
			_, err := c.RPC(ctx, "create_minigame_session", map[string]any{
				"p_group_id":                nil,
				"p_game_type":               gt,
				"p_wager":                   0,
				"p_invitees":                []string{},
				"p_name":                    nil,
				"p_rounds":                  5,
				"p_prize_positions":         3,
				"p_play_mode":               mode,
				"p_anonymous":               false,
				"p_async_rounds_per_player": 1,
				"p_async_ends_at":           nil,
			}, token)
			return err
		}},
		{name: "write:reaction", weight: 4, needsAuth: true, fn: func(ctx context.Context, c *Client, ds *Dataset, rng *rand.Rand, token string, actor *Identity) error {
			if len(ds.ActiveMatches) == 0 {
				return nil
			}
			mid := ds.ActiveMatches[rng.Intn(len(ds.ActiveMatches))]
			emoji := []string{"heart", "excited", "surprised", "sad"}[rng.Intn(4)]
			_, err := c.RPC(ctx, "submit_minigame_reaction", map[string]any{
				"p_session_id": mid,
				"p_reaction":   emoji,
			}, token)
			return err
		}},
	}
}
