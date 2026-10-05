-- ============================================================================
-- Samay — seed-feed-test.sql  (BIG, configurable @tester universe)
--
-- Seeds the LOCAL supabase-testing stack with a large, realistic @tester data
-- set so every screen that reads groups / events / minigames / invites /
-- friendships / chats / notifications has data in ALL of its states.
--
-- This is INDEPENDENT from the small `seed-test.sql` snapshot (which is left
-- untouched). Applied by `tools/seed-feed-test.sh` (see `make supabase-feed-test`)
-- which creates the auth users + downloads/uploads the profile pictures,
-- event banners and group covers, then runs this file.
--
-- CONFIGURABLE: `:n` = number of numbered accounts (tester2..testerN). Default
-- 100. `:base_url` = storage public URL base the app can reach.
--
--   PGPASSWORD=postgres psql -h 127.0.0.1 -p 54382 -U postgres -d postgres \
--     -v n=100 -v base_url=http://127.0.0.1:54386 \
--     -v ON_ERROR_STOP=1 -f supabase-testing/seed/seed-feed-test.sql
--
-- Idempotent: all rows it owns are deleted first (deterministic UUID prefixes).
-- Triggers are suppressed (`session_replication_role = replica`) so the rows
-- can carry the exact shapes the app produces without capacity/tier guards.
-- ============================================================================

\set ON_ERROR_STOP on

-- ── deterministic UUID helpers (this session only) ─────────────────────────
CREATE FUNCTION pg_temp.tuid(kind text, i int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $f$
  SELECT ('00000000-0000-0000-' || kind || '-' || lpad(i::text, 12, '0'))::uuid;
$f$;

CREATE FUNCTION pg_temp.tester_uid(k int) RETURNS uuid LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE WHEN k = 1 THEN '6f8108f5-3964-45df-82a1-76a5d9185c10'::uuid
              ELSE ('00000000-0000-0000-0000-' || lpad(k::text, 12, '0'))::uuid END;
$f$;

CREATE FUNCTION pg_temp.tester_name(k int) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE WHEN k = 1 THEN 'tester' ELSE 'tester' || k END;
$f$;

BEGIN;
SET LOCAL session_replication_role = replica;

-- ════════════════════════════════════════════════════════════════════════════
-- 0. CLEANUP — remove everything this seed previously created
-- ════════════════════════════════════════════════════════════════════════════
DELETE FROM public.minigame_group_messages WHERE session_id::text LIKE '00000000-0000-0000-0003-%';
DELETE FROM public.minigame_results        WHERE session_id::text LIKE '00000000-0000-0000-0003-%';
DELETE FROM public.minigame_invites        WHERE session_id::text LIKE '00000000-0000-0000-0003-%';
DELETE FROM public.minigame_sessions       WHERE id::text         LIKE '00000000-0000-0000-0003-%';

DELETE FROM public.messages            WHERE chat_id::text LIKE '00000000-0000-0000-0005-%';
DELETE FROM public.chat_participants   WHERE chat_id::text LIKE '00000000-0000-0000-0005-%';
DELETE FROM public.chats               WHERE id::text      LIKE '00000000-0000-0000-0005-%';

DELETE FROM public.event_photo_likes   WHERE photo_id::text LIKE '00000000-0000-0000-0009-%';
DELETE FROM public.event_photos        WHERE id::text       LIKE '00000000-0000-0000-0009-%';
DELETE FROM public.event_attendances   WHERE event_id::text LIKE '00000000-0000-0000-0002-%';
DELETE FROM public.event_invites       WHERE event_id::text LIKE '00000000-0000-0000-0002-%';
DELETE FROM public.event_hosts         WHERE event_id::text LIKE '00000000-0000-0000-0002-%';
DELETE FROM public.events              WHERE id::text       LIKE '00000000-0000-0000-0002-%';

DELETE FROM public.group_shard_contributions WHERE group_id::text LIKE '00000000-0000-0000-0001-%';
DELETE FROM public.group_rank_snapshots      WHERE group_id::text LIKE '00000000-0000-0000-0001-%';
DELETE FROM public.group_members             WHERE group_id::text LIKE '00000000-0000-0000-0001-%';
DELETE FROM public.groups                    WHERE id::text       LIKE '00000000-0000-0000-0001-%';

DELETE FROM public.notifications WHERE id::text LIKE '00000000-0000-0000-0008-%';
DELETE FROM public.friendships   WHERE id::text LIKE '00000000-0000-0000-0007-%';
DELETE FROM public.users
  WHERE id::text LIKE '00000000-0000-0000-0000-%'
     OR id = '6f8108f5-3964-45df-82a1-76a5d9185c10';

-- ════════════════════════════════════════════════════════════════════════════
-- 1. AUTH USERS — one per account, password tester123 (bcrypt hash reused);
--    tools/seed-feed-test.sh re-asserts the password through the GoTrue admin
--    API so login is guaranteed even if this hash is ever rotated.
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous,
  created_at, updated_at
)
SELECT
  '00000000-0000-0000-0000-000000000000',
  pg_temp.tester_uid(k),
  'authenticated', 'authenticated',
  pg_temp.tester_name(k) || '@tester.com',
  '$2a$10$toqRPeDso5laOyPR4uVEr.DooqIBA1wU9VxzsOfI12fH/cKWEezau',
  now(),
  '{"provider": "email", "providers": ["email"]}'::jsonb,
  jsonb_build_object('email_verified', true),
  false, false,
  now() - (k || ' days')::interval,
  now()
FROM generate_series(1, :n) AS k
ON CONFLICT (id) DO NOTHING;

-- ════════════════════════════════════════════════════════════════════════════
-- 2. PUBLIC USERS — 100% profile pictures (colorful realistic portraits)
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO public.users (
  id, username, avatar_url, date_of_birth, bio, personal_shards, preshards,
  subscription_tier, entitlement_tier, interest_tags, discovery_opt_in,
  profile_public, read_receipts_enabled, minigame_invite_friends_only,
  notification_preferences, created_at, updated_at
)
SELECT
  pg_temp.tester_uid(k),
  pg_temp.tester_name(k),
  :'base_url' || '/storage/v1/object/public/avatars/' || pg_temp.tester_uid(k)::text || '/avatar.jpg',
  date '1990-01-01' + ((k * 37) % 7000),
  (ARRAY[
    'Amante de las juergas y los juegos de mesa.',
    'Siempre lista para un tono con amigos.',
    'Fotógrafa aficionada · Arequipa',
    'Me encantan los retos y las partidas rápidas.',
    'Busco gente para eventos casuales.',
    'Organizadora de previas épicas.',
    'Fan de la música y el baile.',
    'Aquí por las risas y los shards.'
  ])[(k - 1) % 8 + 1],
  100 + (k * 137) % 4900,
  (k * 53) % 12,
  (CASE k % 10 WHEN 0 THEN 'vip' WHEN 1 THEN 'pro' WHEN 2 THEN 'pro' WHEN 3 THEN 'pro' ELSE 'free' END)::public.subscription_tier,
  (CASE k % 10 WHEN 0 THEN 't0' WHEN 1 THEN 't1' WHEN 2 THEN 't2' ELSE 'free' END)::public.entitlement_tier,
  (CASE (k - 1) % 5
     WHEN 0 THEN ARRAY['fiesta','música','baile']
     WHEN 1 THEN ARRAY['juegos','estrategia','retos']
     WHEN 2 THEN ARRAY['fotos','viajes','café']
     WHEN 3 THEN ARRAY['deporte','cine','comida']
     ELSE ARRAY['lectura','arte','teatro']
   END)::text[],
  (k % 3 = 0),
  (k % 4 = 0),
  (k % 5 <> 0),
  (k % 7 = 0),
  jsonb_build_object(
    'friend_requests', true,
    'minigame_invites', (k % 6 <> 0),
    'event_invites', true
  ),
  now() - (k || ' days')::interval,
  now()
FROM generate_series(1, :n) AS k;

-- A couple of edge-state accounts: one banned, one soft-deleted (last two).
UPDATE public.users SET banned_at = now() - interval '2 days', ban_reason = 'Cuenta de prueba: baneada'
  WHERE id = pg_temp.tester_uid(:n);
UPDATE public.users SET deleted_at = now() - interval '1 day'
  WHERE id = pg_temp.tester_uid(:n - 1) AND :n >= 4;

-- ════════════════════════════════════════════════════════════════════════════
-- 3. FRIENDSHIPS — accepted / pending / blocked
-- ════════════════════════════════════════════════════════════════════════════
-- tester is friends with the first ~60% (accepted), has pending requests from
-- the next ~20% and a blocked relation with a few.
INSERT INTO public.friendships (id, requester_id, addressee_id, status, created_at)
SELECT
  pg_temp.tuid('0007', k),
  pg_temp.tester_uid(1),
  pg_temp.tester_uid(k),
  (CASE
     WHEN k % 10 IN (7, 8, 9) THEN 'blocked'
     WHEN k % 5 = 0 THEN 'pending'
     ELSE 'accepted'
   END)::public.friendship_status,
  now() - (k || ' days')::interval
FROM generate_series(2, :n) AS k
WHERE k <= greatest(2, :n);

-- Cross-friendships between the numbered accounts (so friends-of-friends work).
INSERT INTO public.friendships (id, requester_id, addressee_id, status, created_at)
SELECT
  pg_temp.tuid('0007', 100000 + k),
  pg_temp.tester_uid(((k % (greatest(:n, 2) - 1)) + 2)),
  pg_temp.tester_uid((((k + 1) % (greatest(:n, 2) - 1)) + 2)),
  'accepted',
  now() - ((k % 30) || ' days')::interval
FROM generate_series(1, least(greatest(:n - 1, 1), 120)) AS k
WHERE greatest(:n, 2) >= 3;

-- ════════════════════════════════════════════════════════════════════════════
-- 4. GROUPS — roles, sizes, frozen, shards, rank snapshots, covers
-- ════════════════════════════════════════════════════════════════════════════
-- 8 groups. Members are drawn from the numbered accounts; member count drives
-- the size tier and is written explicitly (triggers are suppressed).
INSERT INTO public.groups (
  id, name, description, cover_url, created_by_user_id, group_shards,
  size_tier, rank_bracket, frozen_at, created_at, updated_at
)
SELECT
  pg_temp.tuid('0001', g),
  (ARRAY[
    '[seed] Los Invencibles', '[seed] Noche Arequipeña', '[seed] Club del Tono',
    '[seed] Juerga Total', '[seed] Cazadores de Shards', '[seed] La Previa',
    '[seed] Reto Semanal', '[seed] Grupo Congelado'
  ])[g],
  'Grupo de prueba generado por seed-feed-test.',
  :'base_url' || '/storage/v1/object/public/groups/' || pg_temp.tuid('0001', g)::text || '/cover.jpg',
  pg_temp.tester_uid(g),
  -- group_shards is server-managed (sum of live contributions); mirrors the
  -- trigger's arithmetic for the seeded contributions (g<=3: 5 × m×50).
  CASE WHEN g <= 3 THEN 750 ELSE 0 END,
  (CASE
     WHEN g IN (1, 2) THEN 'medium'
     WHEN g IN (3, 4) THEN 'small'
     ELSE 'micro'
   END)::public.size_tier,
  (ARRAY['b0_20','b20_40','b40_60','b60_80','b80_90','b90_100'])[((g - 1) % 6) + 1]::public.rank_bracket,
  CASE WHEN g = 8 THEN now() - interval '3 days' ELSE NULL END,
  now() - interval '40 days',
  now() - (g || ' days')::interval
FROM generate_series(1, 8) AS g;

-- Members: creator is host; a staff; the rest members; some 'invited'.
INSERT INTO public.group_members (id, group_id, user_id, role, joined_at, status)
SELECT
  pg_temp.tuid('000e', g * 1000 + m),
  pg_temp.tuid('0001', g),
  pg_temp.tester_uid(m),
  (CASE WHEN m = g THEN 'host' WHEN m = (g % greatest(:n, 2)) + 1 THEN 'staff' ELSE 'member' END)::public.group_role,
  now() - ((m + g) || ' days')::interval,
  CASE WHEN m > 12 AND m % 5 = 0 THEN 'invited' ELSE 'active' END
FROM generate_series(1, 8) AS g
CROSS JOIN generate_series(1, least(:n, CASE WHEN g IN (1, 2) THEN 60 WHEN g IN (3, 4) THEN 20 ELSE 8 END)) AS m
ON CONFLICT (group_id, user_id) DO NOTHING;

-- Shard contributions (recent, still valid) for the top groups.
INSERT INTO public.group_shard_contributions (id, group_id, user_id, shards_contributed, contributed_at, expires_at)
SELECT
  pg_temp.tuid('000a', g * 100 + m),
  pg_temp.tuid('0001', g),
  pg_temp.tester_uid(m + 1),
  (m * 50),
  now() - (m || ' days')::interval,
  now() + interval '30 days'
FROM generate_series(1, 3) AS g
CROSS JOIN generate_series(1, least(5, greatest(:n - 1, 1))) AS m
WHERE :n >= 2;

-- Rank snapshots (leaderboard).
INSERT INTO public.group_rank_snapshots (id, group_id, size_tier, rank_bracket, rank_position, score, member_count, calculated_at)
SELECT
  pg_temp.tuid('000b', g),
  pg_temp.tuid('0001', g),
  (CASE WHEN g IN (1, 2) THEN 'medium' WHEN g IN (3, 4) THEN 'small' ELSE 'micro' END)::public.size_tier,
  (ARRAY['b0_20','b20_40','b40_60','b60_80','b80_90','b90_100'])[((g - 1) % 6) + 1]::public.rank_bracket,
  g,
  g * 777,
  least(:n, CASE WHEN g IN (1, 2) THEN 60 WHEN g IN (3, 4) THEN 20 ELSE 8 END),
  now() - interval '1 day'
FROM generate_series(1, 8) AS g;

-- ════════════════════════════════════════════════════════════════════════════
-- 5. EVENTS — all types × statuses × join modes × featured × direct/group
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO public.events (
  id, name, description, cover_url, type, created_by_user_id, group_id,
  location_name, location_lat, location_lng, starts_at, ends_at, join_mode,
  preshards_pool, preshards_distributed, preshards_cap_per_user,
  preshards_remainder_action, dynamic_qr_enabled, capacity, invite_token,
  status, featured, featured_until, created_at, updated_at
)
SELECT
  pg_temp.tuid('0002', i),
  '[seed] ' || initcap(e.t) || ' #' || i || ' (' || e.s || ')',
  'Evento de prueba (' || e.t || ', ' || e.s || ') generado por seed-feed-test.',
  -- Event covers live in the PUBLIC `groups` bucket at `event_covers/…`
  -- (the app's uploadEventCover contract: the `events` bucket is private and
  -- only serves signed URLs, so a public cover_url must point at `groups`).
  :'base_url' || '/storage/v1/object/public/groups/event_covers/' || pg_temp.tuid('0002', i)::text || '.jpg',
  e.t::public.event_type,
  CASE WHEN e.g IS NOT NULL THEN pg_temp.tester_uid(e.g) ELSE pg_temp.tester_uid(1) END,
  CASE WHEN e.g IS NOT NULL THEN pg_temp.tuid('0001', e.g) ELSE NULL END,
  'Arequipa · punto ' || i,
  -16.3988 + ((i % 10) - 5) * 0.010,
  -71.5369 + ((i % 7) - 3) * 0.010,
  CASE e.s
    WHEN 'live'      THEN now() - interval '1 hour'
    WHEN 'ended'     THEN now() - interval '9 days'
    WHEN 'cancelled' THEN now() + interval '4 days'
    ELSE now() + (i || ' days')::interval
  END,
  CASE e.s
    WHEN 'live'      THEN now() + interval '4 hours'
    WHEN 'ended'     THEN now() - interval '9 days' + interval '4 hours'
    WHEN 'cancelled' THEN now() + interval '4 days' + interval '4 hours'
    ELSE now() + (i || ' days')::interval + interval '4 hours'
  END,
  (CASE WHEN i % 2 = 0 THEN 'approval' ELSE 'open' END)::public.join_mode,
  CASE WHEN e.t = 'casual' THEN 0 ELSE (i % 12 + 1) * 250 END,
  (e.s = 'ended'),
  CASE WHEN e.t = 'casual' THEN NULL ELSE 250 END,
  CASE WHEN e.t = 'casual' THEN NULL
       ELSE (CASE WHEN i % 2 = 0 THEN 'redistribute' ELSE 'return' END)::public.preshard_remainder_action END,
  -- dynamic QR auto-activates whenever the preshard pool > 0
  -- (set_dynamic_qr_enabled), so casual events stay false.
  (e.t <> 'casual'),
  (ARRAY[7, 14, 56, 1120])[(i - 1) % 4 + 1],
  gen_random_uuid()::text,
  e.s::public.event_status,
  (i % 3 = 0),
  CASE WHEN i % 3 = 0 THEN now() + interval '14 days' ELSE NULL END,
  now() - interval '20 days',
  now() - interval '20 days'
FROM (
  SELECT
    i,
    (ARRAY['draft','upcoming','live','ended','cancelled'])[(i - 1) % 5 + 1] AS s,
    (ARRAY['casual','juerga','tono'])[(i - 1) % 3 + 1]              AS t,
    CASE WHEN i % 4 = 0 THEN (i / 4)::int ELSE NULL END            AS g
  FROM generate_series(1, 15) AS i
) e;

-- Hosts: the creator is host; a couple of events get a staff member.
INSERT INTO public.event_hosts (id, event_id, user_id, role, preshards_contributed, added_at)
SELECT
  pg_temp.tuid('000f', i),
  pg_temp.tuid('0002', i),
  CASE WHEN e.g IS NOT NULL THEN pg_temp.tester_uid(e.g) ELSE pg_temp.tester_uid(1) END,
  'host',
  0,
  now() - interval '20 days'
FROM (
  SELECT i, CASE WHEN i % 4 = 0 THEN (i / 4)::int ELSE NULL END AS g
  FROM generate_series(1, 15) AS i
) e
ON CONFLICT (event_id, user_id) DO NOTHING;

INSERT INTO public.event_hosts (id, event_id, user_id, role, preshards_contributed, added_at)
SELECT
  pg_temp.tuid('000f', 500 + i),
  pg_temp.tuid('0002', i),
  pg_temp.tester_uid(2 + (i % greatest(:n - 1, 1))),
  'staff',
  0,
  now() - interval '18 days'
FROM generate_series(1, 15) AS i
WHERE :n >= 3
ON CONFLICT (event_id, user_id) DO NOTHING;

-- Invites on upcoming/live events, all statuses.
INSERT INTO public.event_invites (id, event_id, user_id, invited_by_user_id, status, invited_at, responded_at)
SELECT
  pg_temp.tuid('0010', i * 10 + j),
  pg_temp.tuid('0002', i),
  pg_temp.tester_uid(2 + j),
  pg_temp.tester_uid(1),
  (ARRAY['pending','accepted','declined','attended'])[j]::public.invite_status,
  now() - interval '5 days',
  CASE WHEN j = 1 THEN NULL ELSE now() - interval '4 days' END
FROM generate_series(1, 15) AS i
CROSS JOIN generate_series(1, 4) AS j
WHERE ((i - 1) % 5 + 1) IN (2, 3)               -- upcoming / live
  AND :n >= 6
ON CONFLICT (event_id, user_id) DO NOTHING;

-- Attendances on live/ended events.
INSERT INTO public.event_attendances (id, event_id, user_id, confirmed_at, shards_received)
SELECT
  pg_temp.tuid('0011', i * 10 + j),
  pg_temp.tuid('0002', i),
  pg_temp.tester_uid(2 + j),
  now() - interval '3 days',
  CASE WHEN ((i - 1) % 5 + 1) = 4 THEN 250 ELSE 0 END
FROM generate_series(1, 15) AS i
CROSS JOIN generate_series(1, 3) AS j
WHERE ((i - 1) % 5 + 1) IN (3, 4)               -- live / ended
  AND :n >= 5
ON CONFLICT (event_id, user_id) DO NOTHING;

-- ════════════════════════════════════════════════════════════════════════════
-- 6. GROUP CHATS (so group-scoped minigames have a thread) + participants
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO public.chats (id, type, reference_id, created_at)
SELECT pg_temp.tuid('0005', g), 'group', pg_temp.tuid('0001', g), now() - interval '40 days'
FROM generate_series(1, 8) AS g;

INSERT INTO public.chat_participants (id, chat_id, user_id, created_at, last_read_at)
SELECT
  pg_temp.tuid('0006', (g * 1000 + gm.rn)::int),
  pg_temp.tuid('0005', g),
  gm.user_id,
  now() - interval '40 days',
  now() - interval '1 day'
FROM (
  SELECT group_id, user_id, row_number() OVER (PARTITION BY group_id ORDER BY joined_at) AS rn
  FROM public.group_members
  WHERE status = 'active'
    AND group_id IN (SELECT pg_temp.tuid('0001', k) FROM generate_series(1, 8) AS k)
) gm
JOIN (SELECT generate_series(1, 8) AS g) gg ON gm.group_id = pg_temp.tuid('0001', gg.g)
ON CONFLICT (chat_id, user_id) DO NOTHING;

-- ════════════════════════════════════════════════════════════════════════════
-- 7. MINIGAME SESSIONS — 7 games × {direct-private, direct-public, group,
--    finished-with-winner}; plus a few sessions that INVITE tester (pending)
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO public.minigame_sessions (
  id, group_id, game_type, status, shard_wager, player_limit, participants,
  winner_id, created_at, name, auto_name, round_target, prize_positions,
  play_mode, anonymous, async_rounds_per_player, async_ends_at, is_public
)
SELECT
  pg_temp.tuid('0003', i),
  s.group_id,
  s.game_type::public.mini_game_type,
  s.status::public.mini_game_status,
  s.wager,
  -- player_limit is frozen from the CREATOR's subscription tier at creation
  -- (tester is PRO → minigame.pro_max_players = 32).
  32,
  s.parts,
  s.winner,
  now() - ((i * 5) || ' hours')::interval,
  s.name,
  'partida-' || i,
  5,
  3,
  s.play_mode,
  (s.variant = 2 AND i % 2 = 0),
  CASE WHEN s.play_mode = 'async' THEN 1 ELSE 1 END,
  CASE WHEN s.play_mode = 'async' THEN now() + interval '3 days' ELSE NULL END,
  s.is_public
FROM (
  SELECT
    i,
    (i - 1) / 7 + 1                                              AS variant,
    (ARRAY['poke_chain','questions','truth_dare','drunk_bottle',
           'challenge','two_lies_one_truth','charades'])[(i - 1) % 7 + 1] AS game_type,
    CASE WHEN (i - 1) / 7 + 1 = 4 THEN 'finished' ELSE 'active' END AS status,
    CASE WHEN (i - 1) / 7 + 1 = 2 THEN 250
         WHEN (i - 1) / 7 + 1 = 4 THEN 500
         ELSE 0 END                                              AS wager,
    CASE WHEN (i - 1) / 7 + 1 = 3 THEN pg_temp.tuid('0001', (i % 6) + 1) ELSE NULL END AS group_id,
    CASE WHEN (i - 1) / 7 + 1 = 4 THEN pg_temp.tester_uid(2 + (i % 3)) ELSE NULL END   AS winner,
    CASE WHEN (i - 1) / 7 + 1 = 2
         THEN '[seed] Partida ' || substring((ARRAY['de verdad','picante','relámpago','nocturna','express','salvaje','temática'])[(i - 1) % 7 + 1], 1, 30)
         ELSE NULL END                                           AS name,
    CASE WHEN (i - 1) / 7 + 1 = 3 THEN 'partida-' || i ELSE NULL END AS auto_name,
    CASE WHEN (i - 1) / 7 + 1 = 2 THEN 'async' ELSE 'by_turns' END   AS play_mode,
    CASE WHEN (i - 1) / 7 + 1 = 2 THEN true ELSE false END           AS is_public,
    (CASE (i - 1) / 7 + 1
       WHEN 1 THEN ARRAY[pg_temp.tester_uid(1), pg_temp.tester_uid(2)]
       WHEN 2 THEN ARRAY[pg_temp.tester_uid(1), pg_temp.tester_uid(2), pg_temp.tester_uid(3), pg_temp.tester_uid(4)]
       WHEN 3 THEN ARRAY[pg_temp.tester_uid(1), pg_temp.tester_uid(2), pg_temp.tester_uid(3)]
       ELSE ARRAY[pg_temp.tester_uid(1), pg_temp.tester_uid(2), pg_temp.tester_uid(3), pg_temp.tester_uid(4)]
     END)::uuid[]                                          AS parts
  FROM generate_series(1, 28) AS i
) s;

-- Sessions created by OTHER users that invite tester → tester's pending feed.
INSERT INTO public.minigame_sessions (
  id, group_id, game_type, status, shard_wager, player_limit, participants,
  winner_id, created_at, name, auto_name, round_target, prize_positions,
  play_mode, anonymous, async_rounds_per_player, async_ends_at, is_public
)
SELECT
  pg_temp.tuid('0003', 100 + j),
  CASE WHEN j = 3 THEN pg_temp.tuid('0001', 1) ELSE NULL END,
  (ARRAY['truth_dare','two_lies_one_truth','charades','drunk_bottle',
         'poke_chain','questions','challenge'])[j]::public.mini_game_type,
  'active', 0, 8,
  ARRAY[pg_temp.tester_uid(2 + j)],
  NULL,
  now() - (j || ' hours')::interval,
  CASE WHEN j % 2 = 0 THEN '[seed] Invitación pendiente ' || j ELSE NULL END,
  'partida-' || (100 + j),
  5, 3, 'by_turns', false, 1, NULL, false
FROM generate_series(1, 6) AS j
WHERE :n >= 8;

-- Invites for the authored sessions (mixed statuses) + tester invitations.
INSERT INTO public.minigame_invites (id, session_id, invitee_id, created_by, status, created_at, decided_at)
SELECT
  pg_temp.tuid('0004', i * 10 + j),
  pg_temp.tuid('0003', i),
  pg_temp.tester_uid(2 + ((i + j) % greatest(:n - 1, 1))),
  pg_temp.tester_uid(1),
  (ARRAY['pending','accepted','declined'])[j]::public.mini_game_invite_status,
  now() - interval '2 hours',
  CASE WHEN j = 1 THEN NULL ELSE now() - interval '1 hour' END
FROM generate_series(1, 28) AS i
CROSS JOIN generate_series(1, 3) AS j
WHERE (i - 1) / 7 + 1 <= 2
ON CONFLICT (session_id, invitee_id) DO NOTHING;

INSERT INTO public.minigame_invites (id, session_id, invitee_id, created_by, status, created_at, decided_at)
SELECT
  pg_temp.tuid('0004', 9000 + j),
  pg_temp.tuid('0003', 100 + j),
  pg_temp.tester_uid(1),
  pg_temp.tester_uid(2 + (j % greatest(:n - 1, 1))),
  'pending',
  now() - (j || ' minutes')::interval,
  NULL
FROM generate_series(1, 6) AS j
WHERE :n >= 4
ON CONFLICT (session_id, invitee_id) DO NOTHING;

-- Group-scoped sessions post a notice in their group chat.
INSERT INTO public.minigame_group_messages (id, chat_id, group_id, session_id, actor_id, created_at)
SELECT
  pg_temp.tuid('000d', i),
  pg_temp.tuid('0005', (i % 6) + 1),
  pg_temp.tuid('0001', (i % 6) + 1),
  pg_temp.tuid('0003', i),
  pg_temp.tester_uid(1),
  now() - ((i * 5) || ' hours')::interval
FROM generate_series(1, 28) AS i
WHERE (i - 1) / 7 + 1 = 3
  AND EXISTS (SELECT 1 FROM public.chats c WHERE c.id = pg_temp.tuid('0005', (i % 6) + 1));

-- ════════════════════════════════════════════════════════════════════════════
-- 8. NOTIFICATIONS (test-only data set) — every relevant state
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO public.notifications (id, user_id, type, title, body, data, read, created_at)
SELECT
  pg_temp.tuid('0008', k),
  pg_temp.tester_uid(1),
  (ARRAY['friend_request','minigame_invite','event_invite','attendance_confirmed',
         'chat_message','event_starting','minigame_notice'])[(k - 1) % 7 + 1],
  (ARRAY['Nueva solicitud de amistad','Te invitaron a una partida','Invitación a un evento',
         'Asistencia confirmada','Nuevo mensaje','Tu evento está por empezar',
         'Novedad en una partida'])[(k - 1) % 7 + 1],
  'Notificación de prueba generada por seed-feed-test.',
  jsonb_build_object('seed', true, 'index', k),
  (k % 2 = 0),
  now() - (k || ' hours')::interval
FROM generate_series(1, 14) AS k;

-- ════════════════════════════════════════════════════════════════════════════
-- 9. EVENT PHOTOS + likes (ended events → gallery + collage)
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO public.event_photos (id, event_id, uploaded_by_user_id, storage_path, likes_count, reported, created_at)
SELECT
  pg_temp.tuid('0009', i * 10 + j),
  pg_temp.tuid('0002', i),
  pg_temp.tester_uid(2 + j),
  pg_temp.tuid('0002', i)::text || '/photos/photo-' || j || '.jpg',
  0,
  false,
  now() - interval '8 days'
FROM generate_series(1, 15) AS i
CROSS JOIN generate_series(1, 3) AS j
WHERE ((i - 1) % 5 + 1) = 4                -- ended
  AND :n >= 6;

INSERT INTO public.event_photo_likes (id, photo_id, user_id, created_at)
SELECT
  pg_temp.tuid('0012', i * 100 + j),
  pg_temp.tuid('0009', i * 10 + j),
  pg_temp.tester_uid(3 + j),
  now() - interval '7 days'
FROM generate_series(1, 15) AS i
CROSS JOIN generate_series(1, 2) AS j
WHERE ((i - 1) % 5 + 1) = 4
  AND :n >= 7;

COMMIT;

-- ── sanity report ───────────────────────────────────────────────────────────
SELECT 'users'        AS entity, count(*) FROM public.users WHERE username LIKE 'tester%'
UNION ALL SELECT 'friendships',  count(*) FROM public.friendships WHERE requester_id::text LIKE '00000000-0000-0000-0000-%'
UNION ALL SELECT 'groups',       count(*) FROM public.groups       WHERE id::text LIKE '00000000-0000-0000-0001-%'
UNION ALL SELECT 'group_members',count(*) FROM public.group_members WHERE group_id::text LIKE '00000000-0000-0000-0001-%'
UNION ALL SELECT 'events',       count(*) FROM public.events       WHERE id::text LIKE '00000000-0000-0000-0002-%'
UNION ALL SELECT 'event_invites',count(*) FROM public.event_invites WHERE event_id::text LIKE '00000000-0000-0000-0002-%'
UNION ALL SELECT 'event_attend', count(*) FROM public.event_attendances WHERE event_id::text LIKE '00000000-0000-0000-0002-%'
UNION ALL SELECT 'sessions',     count(*) FROM public.minigame_sessions WHERE id::text LIKE '00000000-0000-0000-0003-%'
UNION ALL SELECT 'mg_invites',   count(*) FROM public.minigame_invites WHERE session_id::text LIKE '00000000-0000-0000-0003-%'
UNION ALL SELECT 'chats',        count(*) FROM public.chats WHERE id::text LIKE '00000000-0000-0000-0005-%'
UNION ALL SELECT 'notifications',count(*) FROM public.notifications WHERE id::text LIKE '00000000-0000-0000-0008-%'
UNION ALL SELECT 'event_photos', count(*) FROM public.event_photos WHERE id::text LIKE '00000000-0000-0000-0009-%';
