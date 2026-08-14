-- Samay — DEMO / DEV Seed Data (agent I-75)
-- ============================================================================
-- ⚠️  DEMO-ONLY DATA. NOT for production. NOT applied by default.
--
-- Applied ONLY when explicitly requested:
--   * `make supabase-seed-dev`           (direct psql against port 54382)
--   * `SEED_DEV=1 bash supabase/migrate.sh`  /  `SEED_DEV=1 bash supabase/reset.sh`
--   * `bash tools/seed_dev_data.sh`
-- Production (`seed.sql` — admin_users + app_config) stays untouched by this
-- file; the two files are independent and both idempotent.
--
-- What it inserts: 6 demo users, friendships, 2 groups (micro + small) with
-- members, 3 shard contributions (1 expired → boost-decay demo), 1 rank
-- snapshot, 2 events (public + group-scoped) with promotores + 1 invite,
-- 1 group chat with 3 messages (2 plaintext demo + 1 FAKE E2EE envelope),
-- 3 notifications, 2 cosmetics, 1 user_cosmetics.
--
-- IDEMPOTENCY: every statement uses fixed UUIDs + ON CONFLICT DO NOTHING, so
-- re-running is a no-op. Timestamps are relative (`now() - interval …`) for
-- realistic freshness; because of ON CONFLICT they are only inserted once.
--
-- SEEDING AS postgres (superuser) matters here: `assert_safe_user_update()`
-- (20260809000002 §1.2) is SECURITY INVOKER, but superusers take the
-- privileged branch, so personal_shards / preshards / subscription_tier /
-- subscription_expires_at are preserved verbatim instead of being normalized
-- to the signup defaults.
--
-- NOTES / known limitations (honest, by design):
--   * Demo users have NO `auth.users` row → they cannot log in. They are
--     readable in feed / search (user_search_view) / party finder
--     (discovery_view) / leaderboards / public events. To see demo groups,
--     chat and member-scoped rows with YOUR own account, add your user id
--     (auth.uid()) to `group_members` + `chat_participants` manually:
--         INSERT INTO group_members (group_id, user_id, role, status)
--         SELECT id, auth.uid(), 'member', 'active' FROM groups
--         WHERE name = 'Punketo Crew';
--   * The chat's 3rd message is a FAKE opaque ciphertext-looking envelope
--     (starts with `SME2.`). It is NOT a real E2EE envelope and cannot be
--     fabricated client-side — it exists so the chat UI shows an
--     undecryptable row that renders as 'Mensaje no descifrable'
--     (chatUndecryptable). It is clearly marked as a demo placeholder.
--   * Groups: size_tier is normally computed by the `group_size_tier_trigger`
--     (micro < 15 members). 'After Club Lima' is force-set to 'small' at the
--     END of this file (after all member inserts) so both tier UIs can be
--     exercised — the next membership change will recompute it to 'micro'
--     per the real trigger. The rank snapshot (group_rank_snapshots) carries
--     the authoritative leaderboard data.
-- ============================================================================

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. USERS — 6 demo profiles (fixed UUIDs; discovery_opt_in per I-60)
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO users (
    id, username, avatar_url, date_of_birth, bio, personal_shards, preshards,
    subscription_tier, subscription_expires_at, notification_preferences,
    interest_tags, discovery_opt_in, created_at
) VALUES
    ('10000000-0000-0000-0000-000000000001', 'demo_alex', NULL, '1998-04-12',
     'Promotor de punketos y afters limeños. La fila siempre la armo yo.',
     2560, 120, 'pro', now() + interval '180 days',
     '{"chat_message": true, "event_invite": true}',
     ARRAY['punketo', 'electro', 'fiesta'], true, now() - interval '120 days'),
    ('10000000-0000-0000-0000-000000000002', 'demo_bia', NULL, '2000-09-03',
     'Bailo reggaetón hasta que salga el sol. Foto de perfil: siempre movida.',
     890, 45, 'free', NULL,
     '{"chat_message": true}',
     ARRAY['reggaeton', 'fiesta'], true, now() - interval '90 days'),
    ('10000000-0000-0000-0000-000000000003', 'demo_carlos', NULL, '1996-11-27',
     'DJ y promotor de After Club Lima. Cumbia, techno y buen sonido.',
     5120, 300, 'vip', now() + interval '365 days',
     '{"event_invite": true, "shard_received": true}',
     ARRAY['cumbia', 'techno', 'fiesta'], true, now() - interval '110 days'),
    ('10000000-0000-0000-0000-000000000004', 'demo_dana', NULL, '2001-02-18',
     'Techno y afters en la azotea. Descubrimiento apagado, soy selectiva.',
     230, 10, 'free', NULL,
     '{}',
     ARRAY['techno', 'after'], false, now() - interval '60 days'),
    ('10000000-0000-0000-0000-000000000005', 'demo_erik', NULL, '1999-07-08',
     'Punketo los jueves, gym los viernes. Siempre ando con el grupo.',
     1540, 90, 'pro', now() + interval '90 days',
     '{"friend_request": true, "minigame_invite": true}',
     ARRAY['punketo', 'fiesta', 'amigos'], true, now() - interval '75 days'),
    ('10000000-0000-0000-0000-000000000006', 'demo_fabi', NULL, '2002-05-30',
     'Afro y reggaetón. Nueva en la app, buscando buenos planes.',
     640, 20, 'free', NULL,
     '{}',
     ARRAY['reggaeton', 'afro'], false, now() - interval '30 days')
ON CONFLICT (id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. FRIENDSHIPS — accepted + pending (fixed IDs; no UNIQUE on the pair)
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO friendships (id, requester_id, addressee_id, status, created_at) VALUES
    ('10000000-0000-0000-0000-000000000101', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', 'accepted', now() - interval '90 days'),
    ('10000000-0000-0000-0000-000000000102', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000003', 'accepted', now() - interval '85 days'),
    ('10000000-0000-0000-0000-000000000103', '10000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000005', 'accepted', now() - interval '40 days'),
    ('10000000-0000-0000-0000-000000000104', '10000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000006', 'accepted', now() - interval '25 days'),
    ('10000000-0000-0000-0000-000000000105', '10000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000004', 'pending',   now() - interval '2 days'),
    ('10000000-0000-0000-0000-000000000106', '10000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000006', 'pending',   now() - interval '1 day')
ON CONFLICT (id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. GROUPS — micro + small tier demos (small forced at the end, see header)
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO groups (id, name, description, cover_url, created_by_user_id, group_shards, rank_bracket) VALUES
    ('10000000-0000-0000-0000-000000000201', 'Punketo Crew',
     'El grupo oficial del punketo de los jueves. Historia: somos 5, la casa siempre es de Alex.',
     NULL, '10000000-0000-0000-0000-000000000001', 0, 'b60_80'),
    ('10000000-0000-0000-0000-000000000202', 'After Club Lima',
     'After-community de Carlos: cumbia y techno desde las 2am. Entrada por invitación.',
     NULL, '10000000-0000-0000-0000-000000000003', 0, 'b80_90')
ON CONFLICT (id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. GROUP MEMBERS — roles + status (UNIQUE (group_id, user_id))
-- (size_tier recomputed by trigger on every insert → both end 'micro' for now;
--  'After Club Lima' is force-set to 'small' at the end of the file.)
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO group_members (id, group_id, user_id, role, joined_at, status) VALUES
    ('10000000-0000-0000-0000-000000000301', '10000000-0000-0000-0000-000000000201', '10000000-0000-0000-0000-000000000001', 'promotor',    now() - interval '110 days', 'active'),
    ('10000000-0000-0000-0000-000000000302', '10000000-0000-0000-0000-000000000201', '10000000-0000-0000-0000-000000000002', 'co_promotor', now() - interval '85 days',  'active'),
    ('10000000-0000-0000-0000-000000000303', '10000000-0000-0000-0000-000000000201', '10000000-0000-0000-0000-000000000003', 'member',      now() - interval '80 days',  'active'),
    ('10000000-0000-0000-0000-000000000304', '10000000-0000-0000-0000-000000000201', '10000000-0000-0000-0000-000000000004', 'member',      now() - interval '40 days',  'active'),
    ('10000000-0000-0000-0000-000000000305', '10000000-0000-0000-0000-000000000201', '10000000-0000-0000-0000-000000000005', 'member',      now() - interval '35 days',  'active'),
    ('10000000-0000-0000-0000-000000000306', '10000000-0000-0000-0000-000000000202', '10000000-0000-0000-0000-000000000003', 'promotor',    now() - interval '60 days',  'active'),
    ('10000000-0000-0000-0000-000000000307', '10000000-0000-0000-0000-000000000202', '10000000-0000-0000-0000-000000000005', 'co_promotor', now() - interval '55 days',  'active'),
    ('10000000-0000-0000-0000-000000000308', '10000000-0000-0000-0000-000000000202', '10000000-0000-0000-0000-000000000001', 'member',      now() - interval '50 days',  'active'),
    ('10000000-0000-0000-0000-000000000309', '10000000-0000-0000-0000-000000000202', '10000000-0000-0000-0000-000000000004', 'member',      now() - interval '30 days',  'active'),
    ('10000000-0000-0000-0000-000000000310', '10000000-0000-0000-0000-000000000202', '10000000-0000-0000-0000-000000000006', 'member',      now() - interval '10 days',  'active')
ON CONFLICT (group_id, user_id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. SHARD CONTRIBUTIONS — 3 (one EXPIRED → boost-decay demo; boost = 14 days,
--    economy.group_shard_boost_days). group_shards_increment_trigger adds each
--    shards_contributed to groups.group_shards.
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO group_shard_contributions (id, group_id, user_id, shards_contributed, contributed_at, expires_at) VALUES
    ('10000000-0000-0000-0000-000000000401', '10000000-0000-0000-0000-000000000201', '10000000-0000-0000-0000-000000000001', 500, now() - interval '20 days', now() - interval '6 days'),
    ('10000000-0000-0000-0000-000000000402', '10000000-0000-0000-0000-000000000201', '10000000-0000-0000-0000-000000000002', 250, now() - interval '5 days',  now() + interval '9 days'),
    ('10000000-0000-0000-0000-000000000403', '10000000-0000-0000-0000-000000000202', '10000000-0000-0000-0000-000000000003', 1000, now() - interval '1 day',   now() + interval '13 days')
ON CONFLICT (id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. RANK SNAPSHOT — leaderboard demo row (grs_read_all = public)
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO group_rank_snapshots (id, group_id, size_tier, rank_bracket, rank_position, score, member_count, calculated_at) VALUES
    ('10000000-0000-0000-0000-000000000501', '10000000-0000-0000-0000-000000000201', 'micro', 'b80_90', 3, 750, 5, now() - interval '1 day')
ON CONFLICT (id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 7. EVENTS — 1 public 'juerga' (preshard pool + cap + remainder; dynamic QR
--    auto-enabled by trigger) + 1 group-scoped 'casual' (pool forced 0 by the
--    check_casual_no_preshards constraint; approval join mode)
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO events (
    id, name, description, cover_url, type, created_by_user_id, group_id,
    location_name, location_lat, location_lng, starts_at, ends_at, join_mode,
    preshards_pool, preshards_cap_per_user, preshards_remainder_action,
    status, featured, featured_until
) VALUES
    ('10000000-0000-0000-0000-000000000601', 'Juerga de Bienvenida — Punketo',
     'Primera juerga del Punketo Crew abierta al público. Pool de preshards para los primeros que confirmen asistencia.',
     NULL, 'juerga', '10000000-0000-0000-0000-000000000001', NULL,
     'Av. La Mar 1234, Miraflores', -12.1183, -77.0282,
     now() + interval '7 days' + interval '22 hours', now() + interval '8 days' + interval '4 hours',
     'open', 5000, 250, 'redistribute', 'upcoming', true, now() + interval '7 days'),
    ('10000000-0000-0000-0000-000000000602', 'Punketo en Casa de Alex',
     'Previa casera del jueves: música, parlante y amigos. Solo miembros del grupo.',
     NULL, 'casual', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000201',
     'Casa de Alex, Surco', -12.1358, -76.9855,
     now() + interval '3 days' + interval '21 hours', now() + interval '4 days',
     'approval', 0, NULL, NULL, 'upcoming', false, NULL)
ON CONFLICT (id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 8. EVENT PROMOTORES (UNIQUE (event_id, user_id))
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO event_promotores (id, event_id, user_id, role, preshards_contributed, added_at) VALUES
    ('10000000-0000-0000-0000-000000000701', '10000000-0000-0000-0000-000000000601', '10000000-0000-0000-0000-000000000001', 'promotor',    3000, now() - interval '20 days'),
    ('10000000-0000-0000-0000-000000000702', '10000000-0000-0000-0000-000000000601', '10000000-0000-0000-0000-000000000003', 'co_promotor', 2000, now() - interval '18 days'),
    ('10000000-0000-0000-0000-000000000703', '10000000-0000-0000-0000-000000000602', '10000000-0000-0000-0000-000000000001', 'promotor',    0, now() - interval '5 days'),
    ('10000000-0000-0000-0000-000000000704', '10000000-0000-0000-0000-000000000602', '10000000-0000-0000-0000-000000000002', 'co_promotor', 0, now() - interval '5 days')
ON CONFLICT (event_id, user_id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 9. EVENT INVITE — pending, for the invite UX (UNIQUE (event_id, user_id))
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO event_invites (id, event_id, user_id, invited_by_user_id, status, invited_at) VALUES
    ('10000000-0000-0000-0000-000000000801', '10000000-0000-0000-0000-000000000601', '10000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'pending', now() - interval '1 day')
ON CONFLICT (event_id, user_id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 10. CHAT (group) + PARTICIPANTS + MESSAGES
--     Message 3 is a FAKE opaque base64url envelope (SME2. = demo marker).
--     NOT a real E2EE envelope: chat_service decrypt fails → the row renders
--     'Mensaje no descifrable' (chatUndecryptable). Honest demo placeholder.
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO chats (id, type, reference_id, created_at) VALUES
    ('10000000-0000-0000-0000-000000000901', 'group', '10000000-0000-0000-0000-000000000201', now() - interval '90 days')
ON CONFLICT (id) DO NOTHING;

INSERT INTO chat_participants (id, chat_id, user_id, created_at) VALUES
    ('10000000-0000-0000-0000-000000000911', '10000000-0000-0000-0000-000000000901', '10000000-0000-0000-0000-000000000001', now() - interval '90 days'),
    ('10000000-0000-0000-0000-000000000912', '10000000-0000-0000-0000-000000000901', '10000000-0000-0000-0000-000000000002', now() - interval '90 days'),
    ('10000000-0000-0000-0000-000000000913', '10000000-0000-0000-0000-000000000901', '10000000-0000-0000-0000-000000000003', now() - interval '85 days'),
    ('10000000-0000-0000-0000-000000000914', '10000000-0000-0000-0000-000000000901', '10000000-0000-0000-0000-000000000004', now() - interval '40 days'),
    ('10000000-0000-0000-0000-000000000915', '10000000-0000-0000-0000-000000000901', '10000000-0000-0000-0000-000000000005', now() - interval '35 days')
ON CONFLICT (chat_id, user_id) DO NOTHING;

INSERT INTO messages (id, chat_id, sender_id, content, created_at) VALUES
    ('10000000-0000-0000-0000-000000000921', '10000000-0000-0000-0000-000000000901', '10000000-0000-0000-0000-000000000001',
     '¡Hola! ¿Alguien se apunta al punketo del jueves? 🪩', now() - interval '6 days'),
    ('10000000-0000-0000-0000-000000000922', '10000000-0000-0000-0000-000000000901', '10000000-0000-0000-0000-000000000002',
     'Yo voy, llego tipo 11. ¿Llevamos algo? 🎉', now() - interval '5 days'),
    ('10000000-0000-0000-0000-000000000923', '10000000-0000-0000-0000-000000000901', '10000000-0000-0000-0000-000000000003',
     'SME2.AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4.QnVlbm9zQWlyZXNEZW1vRW52ZWxvcGUuREVNT19OT1RfUkVBTA',
     now() - interval '5 days' + interval '2 hours')
ON CONFLICT (id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 11. NOTIFICATIONS — known app types: event_invite / chat_message /
--     friend_request (icons + deep links per NOTI spec table)
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO notifications (id, user_id, type, title, body, data, read, created_at) VALUES
    ('10000000-0000-0000-0000-000000001001', '10000000-0000-0000-0000-000000000002', 'event_invite',
     'Invitación a evento', 'Alex te invitó a "Juerga de Bienvenida — Punketo".',
     jsonb_build_object('event_id', '10000000-0000-0000-0000-000000000601',
                        'deepLink', '/event/10000000-0000-0000-0000-000000000601'),
     false, now() - interval '1 day'),
    ('10000000-0000-0000-0000-000000001002', '10000000-0000-0000-0000-000000000001', 'chat_message',
     'Nuevo mensaje en Punketo Crew', 'Carlos: (mensaje cifrado de demostración).',
     jsonb_build_object('chat_id', '10000000-0000-0000-0000-000000000901',
                        'deepLink', '/chat/10000000-0000-0000-0000-000000000901'),
     false, now() - interval '5 days'),
    ('10000000-0000-0000-0000-000000001003', '10000000-0000-0000-0000-000000000004', 'friend_request',
     'Solicitud de amistad', 'Bia te envió una solicitud de amistad.',
     jsonb_build_object('user_id', '10000000-0000-0000-0000-000000000002',
                        'deepLink', '/user/10000000-0000-0000-0000-000000000002'),
     true, now() - interval '2 days')
ON CONFLICT (id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 12. COSMETICS (public catalog) + 1 USER_COSMETICS (UNIQUE (user_id,
--     cosmetic_id)). asset_url is a placeholder path — the real assets land
--     with U-20; the shop UI only needs the row to exist.
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO cosmetics (id, name, type, asset_url, shard_cost, tier_requirement) VALUES
    ('10000000-0000-0000-0000-000000001101', 'Marco Neón', 'avatar_frame', '/assets/cosmetics/marco_neon.png', 500, 'free'),
    ('10000000-0000-0000-0000-000000001102', 'Fondo Disco', 'profile_bg', '/assets/cosmetics/fondo_disco.png', 1500, 'pro')
ON CONFLICT (id) DO NOTHING;

INSERT INTO user_cosmetics (id, user_id, cosmetic_id, equipped, purchased_at) VALUES
    ('10000000-0000-0000-0000-000000001201', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000001101', true, now() - interval '30 days')
ON CONFLICT (user_id, cosmetic_id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 13. FINAL FIXUPS (documented in the header — trigger semantics override)
-- ────────────────────────────────────────────────────────────────────────────
-- After Club Lima: force 'small' AFTER all member inserts (the last member
-- insert recomputed size_tier → 'micro'; the trigger would again recompute
-- from real counts on the NEXT membership change — intended behavior).
UPDATE groups SET size_tier = 'small' WHERE id = '10000000-0000-0000-0000-000000000202';
-- Punketo Crew keeps the trigger-computed 'micro' — no statement needed.

COMMIT;
