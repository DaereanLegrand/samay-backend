package loadtest

import (
	"context"
	"encoding/base64"
	"fmt"
	"math/rand"
	"strconv"
	"time"
)

const (
	defaultPassword = "LoadTest123!"
	seedWorkers     = 12
)

// Seed creates the full dataset on the target backend via the service_role key
// (auth admin API + direct PostgREST writes + storage uploads). It never
// cleans up: a fresh run-id namespaces every object.
func Seed(ctx context.Context, cfg *Config, c *Client, ds *Dataset, rng *rand.Rand, logf func(string, ...any)) (*SeedResult, error) {
	res := &SeedResult{}
	base := time.Now().UTC()

	// ── users ────────────────────────────────────────────────────────────
	// Identities are normally pre-built by Run (so tokens can be minted even
	// without seeding); only build them here when Seed is called standalone.
	if len(ds.Users) == 0 {
		for i := 0; i < cfg.Users; i++ {
			id := uuidFor(cfg.RunID, "user", strconv.Itoa(i))
			ds.Users = append(ds.Users, &Identity{
				Index:    i,
				ID:       id,
				Username: cfg.username(i),
				Email:    cfg.email(i),
				Password: defaultPassword,
			})
		}
	}
	logf("seeding %d users…", len(ds.Users))
	errs := runParallel(ctx, len(ds.Users), seedWorkers, func(i int) error {
		u := ds.Users[i]
		if err := c.AdminCreateUser(ctx, u.ID, u.Email, u.Password); err != nil {
			return fmt.Errorf("auth user: %w", err)
		}
		ur := rand.New(rand.NewSource(int64(hashSeed(u.Username))))
		avatarPath := u.ID + "/avatar.jpg"
		u.AvatarURL = publicURL(cfg.URL, "avatars", avatarPath)
		tier := "free"
		switch {
		case ur.Intn(20) == 0:
			tier = "vip"
		case ur.Intn(6) == 0:
			tier = "pro"
		}
		row := map[string]any{
			"id":                    u.ID,
			"username":              u.Username,
			"avatar_url":            u.AvatarURL,
			"date_of_birth":         fmt.Sprintf("19%02d-%02d-%02d", 80+ur.Intn(20), 1+ur.Intn(12), 1+ur.Intn(28)),
			"bio":                   fmt.Sprintf("Perfil de prueba #%d", i),
			"personal_shards":       500 + ur.Intn(20000),
			"preshards":             ur.Intn(500),
			"subscription_tier":     tier,
			"interest_tags":         pickTags(ur, 3),
			"discovery_opt_in":      ur.Intn(2) == 0,
			"read_receipts_enabled": true,
			"profile_public":        ur.Intn(2) == 0,
		}
		if err := c.Insert(ctx, "users", row, c.ServiceKey); err != nil {
			return fmt.Errorf("profile row: %w", err)
		}
		img, err := AvatarJPEG(u.Username, 256)
		if err != nil {
			return fmt.Errorf("avatar image: %w", err)
		}
		if err := c.StorageUpload(ctx, "avatars", avatarPath, img, "image/jpeg", c.ServiceKey); err != nil {
			return fmt.Errorf("avatar upload: %w", err)
		}
		return nil
	})
	for _, err := range errs {
		if err == nil {
			res.Users++
			continue
		}
		res.addError("user", err)
	}
	res.Avatars = res.Users
	logf("users: %d/%d", res.Users, len(ds.Users))
	if res.Users == 0 && len(ds.Users) > 0 {
		return res, fmt.Errorf("no users could be seeded: %v", firstError(res.Errors))
	}

	// ── friendships ──────────────────────────────────────────────────────
	if len(ds.Users) >= 2 && cfg.Friendships > 0 {
		ds.Edges = FriendshipEdges(len(ds.Users), cfg.Friendships, rng)
		rows := make([]map[string]any, 0, len(ds.Edges))
		for k, e := range ds.Edges {
			a := ds.Users[e[0]]
			b := ds.Users[e[1]]
			status := "accepted"
			if k%7 == 0 {
				status = "pending"
			}
			rows = append(rows, map[string]any{
				"id":           uuidFor(cfg.RunID, "friend", strconv.Itoa(k)),
				"requester_id": a.ID,
				"addressee_id": b.ID,
				"status":       status,
				"created_at":   ago(base, time.Duration(rng.Intn(200))*time.Hour),
			})
		}
		if err := c.Insert(ctx, "friendships", rows, c.ServiceKey); err != nil {
			res.addError("friendships", err)
		} else {
			res.Friendships = len(rows)
		}
		logf("friendships: %d", res.Friendships)
	}

	// ── groups + banners + members ───────────────────────────────────────
	for g := 0; g < cfg.Groups && len(ds.Users) >= 2; g++ {
		gid := uuidFor(cfg.RunID, "group", strconv.Itoa(g))
		host := ds.Users[rng.Intn(len(ds.Users))]
		coverPath := gid + "/banner.jpg"
		coverURL := publicURL(cfg.URL, "groups", coverPath)
		group := map[string]any{
			"id":                 gid,
			"name":               fmt.Sprintf("Load Group %d", g),
			"description":        fmt.Sprintf("Grupo de carga %d", g),
			"cover_url":          coverURL,
			"created_by_user_id": host.ID,
			"created_at":         ago(base, time.Duration(rng.Intn(400))*time.Hour),
		}
		if err := c.Insert(ctx, "groups", group, c.ServiceKey); err != nil {
			res.addError("group", err)
			continue
		}
		if img, err := BannerJPEG(gid, 800, 300); err == nil {
			if err := c.StorageUpload(ctx, "groups", coverPath, img, "image/jpeg", c.ServiceKey); err == nil {
				res.GroupBanners++
			} else {
				res.addError("group banner", err)
			}
		}
		memberCount := capMembers(2+rng.Intn(12), len(ds.Users))
		rows := []map[string]any{{
			"group_id":  gid,
			"user_id":   host.ID,
			"role":      "host",
			"status":    "active",
			"joined_at": ago(base, time.Duration(rng.Intn(400))*time.Hour),
		}}
		seen := map[string]bool{host.ID: true}
		attempts := 0
		maxAttempts := memberCount*20 + 100
		for len(rows) < memberCount && attempts < maxAttempts {
			attempts++
			u := ds.Users[rng.Intn(len(ds.Users))]
			if seen[u.ID] {
				continue
			}
			seen[u.ID] = true
			role := "member"
			if rng.Intn(12) == 0 {
				role = "staff"
			}
			rows = append(rows, map[string]any{
				"group_id":  gid,
				"user_id":   u.ID,
				"role":      role,
				"status":    "active",
				"joined_at": ago(base, time.Duration(rng.Intn(300))*time.Hour),
			})
		}
		if err := c.Insert(ctx, "group_members", rows, c.ServiceKey); err != nil {
			res.addError("group members", err)
		} else {
			res.GroupMembers += len(rows)
		}
		ds.Groups = append(ds.Groups, gid)
		res.Groups++
	}
	logf("groups: %d (%d members)", res.Groups, res.GroupMembers)

	// ── events + covers + rosters + photos ───────────────────────────────
	seedEvents(ctx, cfg, c, ds, rng, base, res)
	logf("events: %d (%d photos)", res.Events, res.EventPhotos)

	// ── chats + messages ─────────────────────────────────────────────────
	seedChats(ctx, cfg, c, ds, rng, base, res)
	logf("chats: %d (%d messages)", res.Chats, res.Messages)

	// ── minigame matches ─────────────────────────────────────────────────
	seedMatches(ctx, cfg, c, ds, rng, base, res)
	logf("matches: %d (%d states, %d reactions, %d results)", res.Matches, res.GameStates, res.Reactions, res.Results)

	return res, nil
}

// capMembers clamps a desired group size to the number of available users so
// the member-selection loop always terminates.
func capMembers(desired, users int) int {
	if desired > users {
		return users
	}
	if desired < 0 {
		return 0
	}
	return desired
}

func pickTags(r *rand.Rand, n int) []string {
	pool := []string{"fiesta", "música", "viajes", "gaming", "deportes", "cine", "arte", "tecnología"}
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, pool[r.Intn(len(pool))])
	}
	return out
}

func ago(base time.Time, d time.Duration) string {
	return base.Add(-d).Format(time.RFC3339)
}

func firstError(errs []string) string {
	if len(errs) == 0 {
		return "unknown error"
	}
	return errs[0]
}

func seedEvents(ctx context.Context, cfg *Config, c *Client, ds *Dataset, rng *rand.Rand, base time.Time, res *SeedResult) {
	if cfg.Events <= 0 || len(ds.Users) == 0 {
		return
	}
	statuses := []string{"draft", "upcoming", "live", "ended"}
	for e := 0; e < cfg.Events; e++ {
		eid := uuidFor(cfg.RunID, "event", strconv.Itoa(e))
		host := ds.Users[rng.Intn(len(ds.Users))]
		status := statuses[e%len(statuses)]
		starts, ends := eventWindow(status, base, rng)
		etype := "casual"
		pool := 0
		switch rng.Intn(3) {
		case 1:
			etype, pool = "juerga", 500
		case 2:
			etype, pool = "tono", 1000
		}
		var gid any
		if len(ds.Groups) > 0 && rng.Intn(2) == 0 {
			gid = ds.Groups[rng.Intn(len(ds.Groups))]
		}
		coverPath := eid + "/cover.jpg"
		coverURL := publicURL(cfg.URL, "events", coverPath)
		event := map[string]any{
			"id":                 eid,
			"name":               fmt.Sprintf("Load Event %d", e),
			"description":        "Evento de carga",
			"cover_url":          coverURL,
			"type":               etype,
			"created_by_user_id": host.ID,
			"group_id":           gid,
			"location_name":      "Lima",
			"starts_at":          starts,
			"ends_at":            ends,
			"join_mode":          "open",
			"preshards_pool":     pool,
			"capacity":           7,
			"status":             status,
			"created_at":         ago(base, 500*time.Hour),
		}
		if err := c.Insert(ctx, "events", event, c.ServiceKey); err != nil {
			res.addError("event", err)
			continue
		}
		res.Events++
		if img, err := BannerJPEG(eid, 800, 400); err == nil {
			_ = c.StorageUpload(ctx, "events", coverPath, img, "image/jpeg", c.ServiceKey)
		}
		_ = c.Insert(ctx, "event_hosts", map[string]any{
			"event_id": eid, "user_id": host.ID, "role": "host",
		}, c.ServiceKey)
		// rosters
		invited := map[string]bool{host.ID: true}
		inviteRows := []map[string]any{}
		attendRows := []map[string]any{}
		for n := 0; n < 8 && len(invited) < len(ds.Users); n++ {
			u := ds.Users[rng.Intn(len(ds.Users))]
			if invited[u.ID] {
				continue
			}
			invited[u.ID] = true
			istatus := []string{"pending", "accepted", "declined", "attended"}[rng.Intn(4)]
			inviteRows = append(inviteRows, map[string]any{
				"event_id": eid, "user_id": u.ID, "invited_by_user_id": host.ID,
				"status": istatus, "invited_at": ago(base, 400*time.Hour),
			})
			if istatus == "attended" {
				attendRows = append(attendRows, map[string]any{
					"event_id": eid, "user_id": u.ID, "confirmed_at": ago(base, 2*time.Hour),
				})
			}
		}
		if len(inviteRows) > 0 {
			_ = c.Insert(ctx, "event_invites", inviteRows, c.ServiceKey)
		}
		if len(attendRows) > 0 {
			_ = c.Insert(ctx, "event_attendances", attendRows, c.ServiceKey)
		}
		// photos
		for p := 0; p < 2; p++ {
			pid := uuidFor(cfg.RunID, "photo", strconv.Itoa(e), strconv.Itoa(p))
			path := eid + "/photos/" + pid + ".jpg"
			if img, err := AvatarJPEG(pid, 640); err == nil {
				_ = c.StorageUpload(ctx, "events", path, img, "image/jpeg", c.ServiceKey)
			}
			if err := c.Insert(ctx, "event_photos", map[string]any{
				"id": pid, "event_id": eid, "uploaded_by_user_id": host.ID, "storage_path": path,
			}, c.ServiceKey); err != nil {
				res.addError("event photo", err)
				continue
			}
			res.EventPhotos++
		}
	}
}

func eventWindow(status string, base time.Time, rng *rand.Rand) (string, string) {
	switch status {
	case "live":
		return ago(base, 1*time.Hour), base.Add(3 * time.Hour).Format(time.RFC3339)
	case "ended":
		return ago(base, 48*time.Hour), ago(base, 44*time.Hour)
	default:
		start := base.Add(time.Duration(24+rng.Intn(240)) * time.Hour)
		return start.Format(time.RFC3339), start.Add(6 * time.Hour).Format(time.RFC3339)
	}
}

func seedChats(ctx context.Context, cfg *Config, c *Client, ds *Dataset, rng *rand.Rand, base time.Time, res *SeedResult) {
	if len(ds.Edges) == 0 || cfg.Users < 2 {
		return
	}
	maxChats := 40
	if len(ds.Edges) < maxChats {
		maxChats = len(ds.Edges)
	}
	for i := 0; i < maxChats; i++ {
		e := ds.Edges[i]
		a, b := ds.Users[e[0]], ds.Users[e[1]]
		cid := uuidFor(cfg.RunID, "chat", strconv.Itoa(i))
		if err := c.Insert(ctx, "chats", map[string]any{"id": cid, "type": "direct"}, c.ServiceKey); err != nil {
			res.addError("chat", err)
			continue
		}
		if err := c.Insert(ctx, "chat_participants", []map[string]any{
			{"chat_id": cid, "user_id": a.ID},
			{"chat_id": cid, "user_id": b.ID},
		}, c.ServiceKey); err != nil {
			res.addError("chat participants", err)
			continue
		}
		res.Chats++
		ds.Chats = append(ds.Chats, cid)
		if ds.UserChats == nil {
			ds.UserChats = map[string][]string{}
		}
		ds.UserChats[a.ID] = append(ds.UserChats[a.ID], cid)
		ds.UserChats[b.ID] = append(ds.UserChats[b.ID], cid)
		msgs := 4 + rng.Intn(8)
		rows := make([]map[string]any, 0, msgs)
		for m := 0; m < msgs; m++ {
			sender, recipient := a, b
			if m%2 == 1 {
				sender, recipient = b, a
			}
			rows = append(rows, map[string]any{
				"id":           uuidFor(cfg.RunID, "message", strconv.Itoa(i), strconv.Itoa(m)),
				"chat_id":      cid,
				"sender_id":    sender.ID,
				"recipient_id": recipient.ID,
				"content":      ciphertext(rng, 64),
				"created_at":   ago(base, time.Duration(rng.Intn(300))*time.Minute),
				"sent_at":      ago(base, time.Duration(rng.Intn(300))*time.Minute),
			})
		}
		if err := c.Insert(ctx, "messages", rows, c.ServiceKey); err != nil {
			res.addError("messages", err)
			continue
		}
		res.Messages += len(rows)
	}
}

func ciphertext(rng *rand.Rand, n int) string {
	buf := make([]byte, n)
	for i := range buf {
		buf[i] = byte(rng.Intn(256))
	}
	return "b64:" + base64.StdEncoding.EncodeToString(buf)
}

func seedMatches(ctx context.Context, cfg *Config, c *Client, ds *Dataset, rng *rand.Rand, base time.Time, res *SeedResult) {
	if cfg.Matches <= 0 || len(ds.Users) < 2 {
		return
	}
	plans := PlanMatches(cfg.Matches, len(ds.Groups), rng)
	for i, p := range plans {
		mid := uuidFor(cfg.RunID, "match", strconv.Itoa(i))
		participants := pickParticipants(ds, p.Players, rng)
		if len(participants) < 2 {
			continue
		}
		status := "active"
		var winner any
		if p.State == "finished" {
			status = "finished"
			winner = participants[rng.Intn(len(participants))]
		}
		var gid any
		if p.GroupID >= 0 && p.GroupID < len(ds.Groups) {
			gid = ds.Groups[p.GroupID]
		}
		row := map[string]any{
			"id":                      mid,
			"group_id":                gid,
			"game_type":               p.GameType,
			"status":                  status,
			"shard_wager":             0,
			"player_limit":            8,
			"participants":            participants,
			"winner_id":               winner,
			"is_public":               p.Public,
			"play_mode":               p.Mode,
			"async_rounds_per_player": 1,
			"round_target":            5,
			"prize_positions":         3,
			"name":                    fmt.Sprintf("Partida carga %d", i),
			"created_at":              ago(base, time.Duration(rng.Intn(500))*time.Hour),
		}
		if p.Mode == "async" {
			row["async_ends_at"] = base.Add(time.Duration(1+rng.Intn(48)) * time.Hour).Format(time.RFC3339)
		}
		if err := c.Insert(ctx, "minigame_sessions", row, c.ServiceKey); err != nil {
			res.addError("match", err)
			continue
		}
		res.Matches++
		ds.Matches = append(ds.Matches, mid)
		if p.State != "finished" {
			ds.ActiveMatches = append(ds.ActiveMatches, mid)
		}

		phase := "playing"
		switch p.State {
		case "lobby":
			phase = "lobby"
		case "countdown":
			phase = "countdown"
		}
		state := map[string]any{
			"judge_index": 0,
			"round":       0,
			"phase":       phase,
			"subject_id":  participants[0],
		}
		gs := map[string]any{
			"session_id": mid,
			"game_type":  p.GameType,
			"state":      state,
			"rounds":     []any{},
		}
		if err := c.Insert(ctx, "minigame_game_state", gs, c.ServiceKey); err != nil {
			res.addError("game state", err)
		} else {
			res.GameStates++
		}

		if p.State == "playing" || p.State == "finished" {
			rounds := 1 + rng.Intn(4)
			reactionRows := []map[string]any{}
			for r := 0; r < rounds; r++ {
				for _, voter := range participants {
					if voter == participants[r%len(participants)] {
						continue
					}
					reactionRows = append(reactionRows, map[string]any{
						"session_id": mid,
						"round":      r,
						"voter_id":   voter,
						"reaction":   []string{"heart", "excited", "surprised", "sad"}[rng.Intn(4)],
						"created_at": ago(base, time.Duration(rng.Intn(120))*time.Minute),
					})
				}
			}
			if len(reactionRows) > 0 {
				if err := c.Insert(ctx, "minigame_reactions", reactionRows, c.ServiceKey); err != nil {
					res.addError("reactions", err)
				} else {
					res.Reactions += len(reactionRows)
				}
			}
		}
		if p.State == "finished" {
			results := make([]map[string]any, 0, len(participants))
			for rank, uid := range participants {
				results = append(results, map[string]any{
					"id":    uid,
					"rank":  rank + 1,
					"score": len(participants) - rank,
					"prize": 0,
				})
			}
			if err := c.Insert(ctx, "minigame_results", map[string]any{
				"session_id": mid, "results": results,
			}, c.ServiceKey); err != nil {
				res.addError("results", err)
			} else {
				res.Results++
			}
		}
	}
}

// pickParticipants returns up to n distinct user ids, preferring a friend of
// the first pick when edges exist.
func pickParticipants(ds *Dataset, n int, rng *rand.Rand) []string {
	if len(ds.Users) < 2 {
		return nil
	}
	if n < 2 {
		n = 2
	}
	if n > len(ds.Users) {
		n = len(ds.Users)
	}
	chosen := map[string]bool{}
	out := []string{ds.Users[rng.Intn(len(ds.Users))].ID}
	chosen[out[0]] = true
	attempts := 0
	maxAttempts := n*20 + 100
	for len(out) < n && attempts < maxAttempts {
		attempts++
		u := ds.Users[rng.Intn(len(ds.Users))]
		if chosen[u.ID] {
			continue
		}
		chosen[u.ID] = true
		out = append(out, u.ID)
	}
	return out
}
