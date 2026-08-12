-- Samay Schema pgTAP Tests — Comprehensive
-- Covers all 25 migrations (20260510000001 through 20260810000007).
BEGIN;

SELECT plan(321);

-- ============================================================
-- SECTION 1: Extensions (migration 20260510000001)
-- ============================================================
SELECT has_extension('pgcrypto');
SELECT has_extension('moddatetime');
SELECT has_extension('pg_cron');

-- ============================================================
-- SECTION 2: Enums — all 21 (migrations 20260510000001, 20260520000001)
-- ============================================================
SELECT has_type('subscription_tier');
SELECT has_type('friendship_status');
SELECT has_type('group_role');
SELECT has_type('size_tier');
SELECT has_type('rank_bracket');
SELECT has_type('event_type');
SELECT has_type('event_status');
SELECT has_type('join_mode');
SELECT has_type('event_role');
SELECT has_type('invite_status');
SELECT has_type('cosmetic_type');
SELECT has_type('chat_type');
SELECT has_type('mini_game_type');
SELECT has_type('mini_game_status');
SELECT has_type('shard_reason');
SELECT has_type('preshard_reason');
SELECT has_type('report_target_type');
SELECT has_type('report_status');
SELECT has_type('admin_role');
SELECT has_type('preshard_remainder_action');
SELECT has_type('feature_request_status');

-- ============================================================
-- SECTION 3: Tables — original 30 (migration 20260510000001)
-- ============================================================
SELECT has_table('users');
SELECT has_table('cosmetics');
SELECT has_table('user_cosmetics');
SELECT has_table('group_cosmetics');
SELECT has_table('friendships');
SELECT has_table('groups');
SELECT has_table('group_members');
SELECT has_table('group_shard_contributions');
SELECT has_table('group_rank_snapshots');
SELECT has_table('events');
SELECT has_table('event_promotores');
SELECT has_table('event_invites');
SELECT has_table('event_qr_tokens');
SELECT has_table('event_attendances');
SELECT has_table('event_photos');
SELECT has_table('event_photo_likes');
SELECT has_table('chats');
SELECT has_table('messages');
SELECT has_table('chat_participants');
SELECT has_table('shard_ledger');
SELECT has_table('preshard_ledger');
SELECT has_table('minigame_sessions');
SELECT has_table('notifications');
SELECT has_table('feature_requests');
SELECT has_table('reports');
SELECT has_table('admin_users');
SELECT has_table('admin_audit_log');
SELECT has_table('subscription_overrides');
SELECT has_table('app_config');
SELECT has_table('processed_webhooks');

-- ============================================================
-- SECTION 4: Migration 20260512000010 — display_name dropped from users
-- ============================================================
SELECT hasnt_column('users', 'display_name', 'display_name was dropped from users table');

-- ============================================================
-- SECTION 5: Migration 20260512000011 — status column on group_members
-- ============================================================
SELECT has_column('group_members', 'status', 'group_members has status column');
SELECT col_type_is('group_members', 'status', 'text', 'group_members.status is text');
SELECT col_not_null('group_members', 'status', 'group_members.status is NOT NULL');

-- ============================================================
-- SECTION 6: Migrations 20260513000002 + 20260724000001 — signup_tracker table
-- ============================================================
SELECT has_table('signup_tracker');
SELECT has_column('signup_tracker', 'email');
SELECT has_column('signup_tracker', 'profile_created');
SELECT has_column('signup_tracker', 'created_at');
SELECT has_column('signup_tracker', 'updated_at');
SELECT col_is_pk('signup_tracker', 'email');

-- signup_tracker RLS is enabled AND forced (migration 20260724000001
-- added FORCE ROW LEVEL SECURITY so even the table owner must obey policies)
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'signup_tracker'::regclass),
    'signup_tracker has RLS enabled'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'signup_tracker'::regclass),
    'signup_tracker has FORCE ROW LEVEL SECURITY (migration 20260724000001)'
);

-- ============================================================
-- SECTION 7: Migration 20260520000001 — user_search_view
-- ============================================================
SELECT has_view('user_search_view');
SELECT columns_are('user_search_view', ARRAY['id', 'username', 'avatar_url'],
    'user_search_view exposes only id, username, avatar_url');

-- ============================================================
-- SECTION 8: Triggers — all 9 (migrations 20260510000001, 20260512000007)
-- ============================================================
SELECT has_trigger('users', 'users_updated_at');
SELECT has_trigger('groups', 'groups_updated_at');
SELECT has_trigger('events', 'events_updated_at');
SELECT has_trigger('group_members', 'group_size_tier_trigger');
SELECT has_trigger('events', 'dynamic_qr_enabled_trigger');
SELECT has_trigger('messages', 'message_cap_trigger');
SELECT has_trigger('group_shard_contributions', 'group_shards_increment_trigger');
SELECT has_trigger('event_photo_likes', 'photo_likes_count_trigger');
SELECT has_trigger('events', 'shard_distribution_dispatch_trigger');

-- ============================================================
-- SECTION 9: Trigger Functions (6 SECURITY DEFINER)
-- ============================================================
SELECT has_function('update_group_size_tier');
SELECT has_function('set_dynamic_qr_enabled');
SELECT has_function('enforce_message_cap');
SELECT has_function('increment_group_shards');
SELECT has_function('update_photo_likes_count');
SELECT has_function('dispatch_shard_distribution');

-- ============================================================
-- SECTION 10: RPC — donate_shards_to_group
-- (migrations 20260512000001, 20260724000002)
-- ============================================================
-- Migration 20260724000002 hardened the RPC: an auth.uid() != p_user_id
-- guard rejects cross-user donations and EXECUTE was REVOKEd from PUBLIC
-- and GRANTed to authenticated only. Behavioral checks (anon denied,
-- cross-user donation blocked) are covered by the curl integration test
-- test/opt-001-rls-security.sh (TEST H1-H3) — run it once the stack is up.
SELECT has_function('donate_shards_to_group', ARRAY['uuid', 'uuid', 'integer', 'timestamptz'],
    'donate_shards_to_group(p_group_id, p_user_id, p_amount, p_expires_at)');

-- ============================================================
-- SECTION 11: RPC — hard_delete_expired_users (migration 20260510000002)
-- ============================================================
SELECT has_function('hard_delete_expired_users');

-- ============================================================
-- SECTION 12: RPCs — Admin RPCs (migration 20260520000001)
-- ============================================================
SELECT has_function('grant_shards', ARRAY['uuid', 'integer', 'text'],
    'grant_shards(p_user_id, p_amount, p_reason)');
SELECT has_function('grant_preshards', ARRAY['uuid', 'integer', 'text'],
    'grant_preshards(p_user_id, p_amount, p_reason)');
SELECT has_function('distribute_shards', ARRAY['uuid'],
    'distribute_shards(p_event_id)');
SELECT has_function('recalculate_ranks', ARRAY['text'],
    'recalculate_ranks(p_tier)');

-- ============================================================
-- SECTION 13: Migration 20260513000001/02 — handle_signup RPC was dropped
-- ============================================================
SELECT hasnt_function('handle_signup', ARRAY['text'],
    'handle_signup RPC was dropped in migration 20260513000002');

-- ============================================================
-- SECTION 14: RLS Policies — users
-- ============================================================
SELECT policies_are('users', ARRAY[
    'users_read_own',
    'users_update_own',
    'users_insert_own'
], 'users has expected RLS policies');

-- ============================================================
-- SECTION 15: RLS Policies — signup_tracker (email-scoped, migration 20260724000001)
-- ============================================================
-- The four wide-open "Anyone can ..." policies were dropped in
-- 20260724000001 and replaced with email-scoped policies
-- (email = auth.jwt() ->> 'email').
SELECT policies_are('signup_tracker', ARRAY[
    'signup_tracker_select_own',
    'signup_tracker_insert_own',
    'signup_tracker_update_own',
    'signup_tracker_delete_own'
], 'signup_tracker has email-scoped RLS policies (own email only)');

-- ============================================================
-- SECTION 16: RLS Policies — friendships
-- ============================================================
SELECT policies_are('friendships', ARRAY[
    'friendships_read_involving',
    'friendships_insert_own',
    'friendships_update_own',
    'friendships_delete_own'
], 'friendships has expected RLS policies');

-- ============================================================
-- SECTION 17: RLS Policies — groups
-- groups_delete_own added by migration 20260809000002 (I-32) — creator
-- deletes own group during leaveGroup's empty-group cleanup.
-- ============================================================
SELECT policies_are('groups', ARRAY[
    'groups_read_member',
    'groups_read_own',
    'groups_update_promotor',
    'groups_insert_own',
    'groups_delete_own'
], 'groups has expected RLS policies');

-- ============================================================
-- SECTION 18: RLS Policies — group_members (no recursion)
-- Migration 20260809000002 (I-32): insert_creator → insert_promotor
-- (creator self-insert + promotor invites), read_same restored via
-- SECURITY DEFINER is_group_member() (member lists), update_own_status
-- added (invitees accept their own invite; role pinned to 'member').
-- ============================================================
SELECT policies_are('group_members', ARRAY[
    'group_members_read_own',
    'group_members_read_same',
    'group_members_insert_promotor',
    'group_members_delete_own',
    'group_members_delete_promotor',
    'group_members_update_own_status',
    'group_members_update_promotor'
], 'group_members has expected RLS policies (no recursion)');

-- ============================================================
-- SECTION 19: RLS Policies — events (no recursion)
-- ============================================================
SELECT policies_are('events', ARRAY[
    'events_read_access',
    'events_update_promotor',
    'events_insert_own'
], 'events has expected RLS policies');

-- ============================================================
-- SECTION 20: RLS Policies — event_promotores (no recursion)
-- ============================================================
SELECT policies_are('event_promotores', ARRAY[
    'ep_read_own',
    'ep_insert_promotor'
], 'event_promotores has expected RLS policies (no recursion)');

-- ============================================================
-- SECTION 21: RLS Policies — event_invites
-- ============================================================
SELECT policies_are('event_invites', ARRAY[
    'ei_read_own',
    'ei_update_own'
], 'event_invites has expected RLS policies');

-- ============================================================
-- SECTION 22: RLS Policies — event_qr_tokens (Edge Function writes only)
-- ============================================================
SELECT policies_are('event_qr_tokens', ARRAY[
    'eqt_read_own'
], 'event_qr_tokens has SELECT-only RLS (Edge Function writes)');

-- ============================================================
-- SECTION 23: RLS Policies — event_attendances
-- ============================================================
SELECT policies_are('event_attendances', ARRAY[
    'ea_read_access'
], 'event_attendances has expected RLS policies');

-- ============================================================
-- SECTION 24: RLS Policies — event_photos
-- ============================================================
SELECT policies_are('event_photos', ARRAY[
    'eph_read_access',
    'eph_insert_own'
], 'event_photos has expected RLS policies');

-- ============================================================
-- SECTION 25: RLS Policies — event_photo_likes
-- ============================================================
SELECT policies_are('event_photo_likes', ARRAY[
    'epl_read_access',
    'epl_insert_own',
    'epl_delete_own'
], 'event_photo_likes has expected RLS policies');

-- ============================================================
-- SECTION 26: RLS Policies — chats
-- chats_delete_related added by migration 20260809000002 (I-32) — creator
-- deletes the group/event chat during leaveGroup cleanup.
-- ============================================================
SELECT policies_are('chats', ARRAY[
    'chats_insert_related',
    'chats_read_participant',
    'chats_delete_related'
], 'chats has expected RLS policies');

-- ============================================================
-- SECTION 27: RLS Policies — messages
-- ============================================================
SELECT policies_are('messages', ARRAY[
    'messages_read_participant',
    'messages_insert_own'
], 'messages has expected RLS policies');

-- ============================================================
-- SECTION 28: RLS Policies — chat_participants
-- ============================================================
SELECT policies_are('chat_participants', ARRAY[
    'cp_read_own'
], 'chat_participants has expected RLS policies');

-- ============================================================
-- SECTION 29: RLS Policies — shard_ledger / preshard_ledger
-- ============================================================
SELECT policies_are('shard_ledger', ARRAY[
    'sl_read_own',
    'sl_insert_own'
], 'shard_ledger has expected RLS policies');

SELECT policies_are('preshard_ledger', ARRAY[
    'pl_read_own'
], 'preshard_ledger has expected RLS policies');

-- ============================================================
-- SECTION 30: RLS Policies — user_cosmetics
-- ============================================================
SELECT policies_are('user_cosmetics', ARRAY[
    'user_cosmetics_read_own',
    'user_cosmetics_insert_own',
    'user_cosmetics_update_own'
], 'user_cosmetics has expected RLS policies');

-- ============================================================
-- SECTION 31: RLS Policies — cosmetics, group_cosmetics (public read)
-- ============================================================
SELECT policies_are('cosmetics', ARRAY[
    'cosmetics_read_all'
], 'cosmetics is public-readable');
SELECT policies_are('group_cosmetics', ARRAY[
    'group_cosmetics_select'
], 'group_cosmetics is public-readable');

-- ============================================================
-- SECTION 32: RLS Policies — remaining non-admin tables
-- ============================================================
SELECT policies_are('group_shard_contributions', ARRAY[
    'gsc_read_member'
], 'group_shard_contributions has expected RLS policies');
SELECT policies_are('group_rank_snapshots', ARRAY[
    'grs_read_all'
], 'group_rank_snapshots is public-readable');
SELECT policies_are('minigame_sessions', ARRAY[
    'ms_read_group_member'
], 'minigame_sessions has expected RLS policies');
SELECT policies_are('notifications', ARRAY[
    'notif_read_own',
    'notif_update_own'
], 'notifications has expected RLS policies');
SELECT policies_are('feature_requests', ARRAY[
    'fr_read_own',
    'fr_insert_own'
], 'feature_requests has expected RLS policies');
SELECT policies_are('reports', ARRAY[
    'reports_insert_own'
], 'reports has expected RLS policies');
SELECT policies_are('app_config', ARRAY[
    'app_config_read_all'
], 'app_config is public-readable');

-- ============================================================
-- SECTION 33: RLS Policies — admin tables (service_role only)
-- ============================================================
SELECT policies_are('admin_users', ARRAY[
    'admin_users_no_access'
], 'admin_users is service_role only');
SELECT policies_are('admin_audit_log', ARRAY[
    'admin_audit_log_no_access'
], 'admin_audit_log is service_role only');
SELECT policies_are('subscription_overrides', ARRAY[
    'subscription_overrides_no_access'
], 'subscription_overrides is service_role only');
SELECT policies_are('processed_webhooks', ARRAY[
    'processed_webhooks_no_access'
], 'processed_webhooks is service_role only');

-- ============================================================
-- SECTION 34: Seed data
-- NOTE (I-33, 2026-08-09): seed INSERTs were removed from
-- migrations/20260510000001_full_schema.sql §7 — supabase/seed.sql is now the
-- single source of truth (SUP-04). Applied post-migration via config.toml
-- [db.seed] / reset.sh / migrate.sh. Post-reset state is unchanged except for
-- app.search_debounce_ms which I-33 added to seed.sql (read by invite/search
-- screens, PERF-05/L-24) → count is 38.
-- ============================================================
SELECT ok(
    (SELECT count(*) = 1 FROM admin_users),
    'admin_users has 1 seed row (system admin, from seed.sql)'
);
SELECT ok(
    (SELECT count(*) = 38 FROM app_config),
    'app_config has 38 seed rows (37 original + app.search_debounce_ms, from seed.sql)'
);

-- ============================================================
-- SECTION 35: admin_users retains display_name (never dropped)
-- ============================================================
SELECT has_column('admin_users', 'display_name',
    'admin_users retains display_name (only dropped from users)');
SELECT ok(
    (SELECT display_name IS NOT NULL FROM admin_users LIMIT 1),
    'Seed admin has a non-null display_name'
);

-- ============================================================
-- SECTION 36: Verify handle_signup was actually dropped
-- ============================================================
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_proc WHERE proname = 'handle_signup'
    ),
    'handle_signup function is confirmed absent from pg_proc'
);

-- ============================================================
-- SECTION 37: RPC — check_signup_email (migration 20260724000001)
-- ============================================================
-- SECURITY DEFINER pre-auth email lookup used by checkSignupEmail()
-- (lib/core/services/supabase_service.dart). Migration 20260724000001
-- REVOKEd EXECUTE from PUBLIC and granted it to anon + authenticated.
SELECT has_function('check_signup_email', ARRAY['text'],
    'check_signup_email(p_email text) exists');
SELECT function_privs_are('public', 'check_signup_email', ARRAY['text']::name[], 'anon', ARRAY['EXECUTE'],
    'anon has EXECUTE on check_signup_email');
SELECT function_privs_are('public', 'check_signup_email', ARRAY['text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'authenticated has EXECUTE on check_signup_email');

-- ============================================================
-- SECTION 38: Hardening migration 20260809000001 (agent I-31)
--   38a. FORCE ROW LEVEL SECURITY on all 31 RLS-enabled tables
--        (30 from 20260510000001 §6 + signup_tracker, re-asserted).
--        relforcerowsecurity mirrors D-04's signup_tracker pattern (Section 6).
--   38b. SET search_path = '' on all 12 hardened SECURITY DEFINER
--        functions — asserted via pg_proc.proconfig containing 'search_path='.
--   38c. service_role BYPASSRLS — FORCE RLS must NOT lock out the admin CLI
--        (Go + SUPABASE_SERVICE_ROLE_KEY via PostgREST as service_role;
--        bypassrls granted by the supabase/postgres image's baked-in
--        00-initial-schema.sql, verified against upstream at commit 8d3216973).
-- ============================================================

-- 38a: FORCE ROW LEVEL SECURITY
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'users'::regclass),
    'users has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'user_cosmetics'::regclass),
    'user_cosmetics has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'cosmetics'::regclass),
    'cosmetics has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'group_cosmetics'::regclass),
    'group_cosmetics has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'friendships'::regclass),
    'friendships has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'groups'::regclass),
    'groups has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'group_members'::regclass),
    'group_members has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'group_shard_contributions'::regclass),
    'group_shard_contributions has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'group_rank_snapshots'::regclass),
    'group_rank_snapshots has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'events'::regclass),
    'events has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'event_promotores'::regclass),
    'event_promotores has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'event_invites'::regclass),
    'event_invites has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'event_qr_tokens'::regclass),
    'event_qr_tokens has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'event_attendances'::regclass),
    'event_attendances has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'event_photos'::regclass),
    'event_photos has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'event_photo_likes'::regclass),
    'event_photo_likes has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'chats'::regclass),
    'chats has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'messages'::regclass),
    'messages has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'chat_participants'::regclass),
    'chat_participants has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'shard_ledger'::regclass),
    'shard_ledger has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'preshard_ledger'::regclass),
    'preshard_ledger has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'minigame_sessions'::regclass),
    'minigame_sessions has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'notifications'::regclass),
    'notifications has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'feature_requests'::regclass),
    'feature_requests has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'reports'::regclass),
    'reports has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'app_config'::regclass),
    'app_config has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'admin_users'::regclass),
    'admin_users has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'admin_audit_log'::regclass),
    'admin_audit_log has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'subscription_overrides'::regclass),
    'subscription_overrides has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'processed_webhooks'::regclass),
    'processed_webhooks has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'signup_tracker'::regclass),
    'signup_tracker has FORCE ROW LEVEL SECURITY (migration 20260809000001 re-assertion)'
);

-- 38b: SECURITY DEFINER functions hardened with SET search_path = ''
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'update_group_size_tier'),
    'update_group_size_tier sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'set_dynamic_qr_enabled'),
    'set_dynamic_qr_enabled sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'enforce_message_cap'),
    'enforce_message_cap sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'increment_group_shards'),
    'increment_group_shards sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'update_photo_likes_count'),
    'update_photo_likes_count sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'dispatch_shard_distribution'),
    'dispatch_shard_distribution sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'hard_delete_expired_users'),
    'hard_delete_expired_users sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'donate_shards_to_group'),
    'donate_shards_to_group sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'grant_shards'),
    'grant_shards sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'grant_preshards'),
    'grant_preshards sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'distribute_shards'),
    'distribute_shards sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'recalculate_ranks'),
    'recalculate_ranks sets search_path = '''' (migration 20260809000001)'
);

-- 38c: service_role BYPASSRLS — admin CLI keeps bypassing RLS under FORCE
SELECT ok(
    (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'service_role'),
    'service_role has BYPASSRLS — FORCE RLS does not lock out admin (migration 20260809000001)'
);

-- ============================================================
-- SECTION 39: RLS audit fixes migration 20260809000002 (agent I-32)
--   39a. G-03 users UPDATE mass-assignment: column-level REVOKE UPDATE on
--        the 7 protected columns (personal_shards, preshards,
--        subscription_tier, subscription_expires_at, banned_at, ban_reason,
--        date_of_birth). PostgREST-safe standard approach — RLS policies
--        cannot restrict columns. REVOKE'd from authenticated + anon.
--   39b. assert_safe_user_update_trigger + function. SECURITY INVOKER on
--        purpose: SECURITY DEFINER would set current_user = postgres
--        (superuser) and the BYPASSRLS/superuser gate would always pass —
--        the trigger would never block anyone.
--   39c. Admin RPCs no longer PUBLIC-EXECUTABLE: grant_shards,
--        grant_preshards, distribute_shards, recalculate_ranks,
--        hard_delete_expired_users were SECURITY DEFINER with default
--        PUBLIC EXECUTE → any anon/authenticated caller could mint shards
--        or drain event pools via PostgREST. Now service_role only
--        (pg_cron runs as postgres — unaffected).
--   39d. Server-managed groups/events columns revoked from authenticated:
--        groups INSERT (group_shards, size_tier, frozen_at) + UPDATE
--        (group_shards, size_tier, frozen_at, rank_bracket); events UPDATE
--        (preshards_distributed, featured, featured_until).
--   39e. user_search_view anon SELECT revoked (authenticated search only).
--   39f. Recreated/added policies asserted via policies_are (Section
--        17/18/26 lists updated in place).
-- ============================================================

-- 39a: users protected columns carry no column-level grants. NOTE: the
-- image's default privileges grant TABLE-level UPDATE to authenticated, so
-- has_column_privilege() still resolves UPDATE — the real enforcement for
-- the protected columns is assert_safe_user_update() (39b), which rejects
-- changes by non-privileged roles. Table-level grant cleanup is an S-03 item.
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.users'::regclass AND a.attname = 'personal_shards'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'users.personal_shards has no column-level UPDATE grant (G-03; trigger is the enforcement)');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.users'::regclass AND a.attname = 'preshards'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'users.preshards has no column-level UPDATE grant (G-03; trigger is the enforcement)');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.users'::regclass AND a.attname = 'subscription_tier'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'users.subscription_tier has no column-level UPDATE grant (G-03; trigger is the enforcement)');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.users'::regclass AND a.attname = 'subscription_expires_at'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'users.subscription_expires_at has no column-level UPDATE grant (G-03; trigger is the enforcement)');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.users'::regclass AND a.attname = 'banned_at'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'users.banned_at has no column-level UPDATE grant (G-03; trigger is the enforcement)');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.users'::regclass AND a.attname = 'ban_reason'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'users.ban_reason has no column-level UPDATE grant (G-03; trigger is the enforcement)');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.users'::regclass AND a.attname = 'date_of_birth'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'users.date_of_birth has no column-level UPDATE grant (G-03; trigger is the enforcement)');

-- 39b: assert_safe_user_update trigger + function
SELECT has_trigger('users', 'assert_safe_user_update_trigger',
    'users has assert_safe_user_update_trigger (migration 20260809000002)');
SELECT has_function('public', 'assert_safe_user_update', ARRAY[]::text[],
    'assert_safe_user_update() exists (migration 20260809000002)');
SELECT ok(
    (SELECT NOT prosecdef FROM pg_proc WHERE proname = 'assert_safe_user_update'),
    'assert_safe_user_update is SECURITY INVOKER (gate must see the real caller)'
);

-- 39c: admin RPC EXECUTE lockdown (REVOKE PUBLIC / GRANT service_role)
SELECT function_privs_are('public', 'grant_shards', ARRAY['uuid', 'integer', 'text']::name[], 'public', ARRAY[]::name[],
    'grant_shards is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT function_privs_are('public', 'grant_shards', ARRAY['uuid', 'integer', 'text']::name[], 'service_role', ARRAY['EXECUTE'],
    'grant_shards is service_role-EXECUTABLE');
SELECT function_privs_are('public', 'grant_preshards', ARRAY['uuid', 'integer', 'text']::name[], 'public', ARRAY[]::name[],
    'grant_preshards is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT function_privs_are('public', 'grant_preshards', ARRAY['uuid', 'integer', 'text']::name[], 'service_role', ARRAY['EXECUTE'],
    'grant_preshards is service_role-EXECUTABLE');
SELECT function_privs_are('public', 'distribute_shards', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'distribute_shards is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT function_privs_are('public', 'distribute_shards', ARRAY['uuid']::name[], 'service_role', ARRAY['EXECUTE'],
    'distribute_shards is service_role-EXECUTABLE');
SELECT function_privs_are('public', 'recalculate_ranks', ARRAY['text']::name[], 'public', ARRAY[]::name[],
    'recalculate_ranks is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT function_privs_are('public', 'recalculate_ranks', ARRAY['text']::name[], 'service_role', ARRAY['EXECUTE'],
    'recalculate_ranks is service_role-EXECUTABLE');
SELECT function_privs_are('public', 'hard_delete_expired_users', ARRAY[]::text[]::name[], 'public', ARRAY[]::name[],
    'hard_delete_expired_users is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT function_privs_are('public', 'hard_delete_expired_users', ARRAY[]::text[]::name[], 'service_role', ARRAY['EXECUTE'],
    'hard_delete_expired_users is service_role-EXECUTABLE');

-- 39d: server-managed groups/events columns carry no column-level grants;
-- enforcement is the assert_safe_group_update/assert_safe_event_update
-- triggers (migration 20260811000001 — table-level grants from the image
-- defaults make column REVOKEs ineffective, so the triggers reject
-- changes to the server-managed columns by non-privileged roles).
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.groups'::regclass AND a.attname = 'group_shards'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*a'))),
    'groups.group_shards has no column-level INSERT grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.groups'::regclass AND a.attname = 'size_tier'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*a'))),
    'groups.size_tier has no column-level INSERT grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.groups'::regclass AND a.attname = 'frozen_at'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*a'))),
    'groups.frozen_at has no column-level INSERT grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.groups'::regclass AND a.attname = 'group_shards'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'groups.group_shards has no column-level UPDATE grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.groups'::regclass AND a.attname = 'size_tier'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'groups.size_tier has no column-level UPDATE grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.groups'::regclass AND a.attname = 'frozen_at'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'groups.frozen_at has no column-level UPDATE grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.groups'::regclass AND a.attname = 'rank_bracket'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'groups.rank_bracket has no column-level UPDATE grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.events'::regclass AND a.attname = 'preshards_distributed'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'events.preshards_distributed has no column-level UPDATE grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.events'::regclass AND a.attname = 'featured'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'events.featured has no column-level UPDATE grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.events'::regclass AND a.attname = 'featured_until'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'events.featured_until has no column-level UPDATE grant');

-- 39g: server-managed groups/events triggers (migration 20260811000001)
SELECT has_trigger('groups', 'assert_safe_group_update_trigger',
    'groups has assert_safe_group_update_trigger (migration 20260811000001)');
SELECT has_trigger('events', 'assert_safe_event_update_trigger',
    'events has assert_safe_event_update_trigger (migration 20260811000001)');

-- 39e: user_search_view authenticated-only
SELECT ok(
    NOT has_table_privilege('anon', 'public.user_search_view', 'SELECT'),
    'user_search_view is not SELECT-able by anon (authenticated search only)');

-- 39f: policy sets asserted in Sections 17/18/26 (updated lists)

-- ============================================================
-- SECTION 41: E2EE prekey table + fetch RPC (migration 20260809000003,
-- agent I-38) — table, own-row RLS, FORCE RLS, index, SECURITY DEFINER
-- RPC with SET search_path = '' and authenticated-only EXECUTE.
-- ============================================================
SELECT has_table('e2ee_identity_keys',
    'e2ee_identity_keys exists (migration 20260809000003)');
SELECT has_column('e2ee_identity_keys', 'user_id');
SELECT has_column('e2ee_identity_keys', 'identity_key');
SELECT has_column('e2ee_identity_keys', 'identity_sig_key');
SELECT has_column('e2ee_identity_keys', 'signed_prekey_id');
SELECT has_column('e2ee_identity_keys', 'signed_prekey');
SELECT has_column('e2ee_identity_keys', 'signed_prekey_sig');
SELECT has_column('e2ee_identity_keys', 'signed_prekey_expires_at');
SELECT has_column('e2ee_identity_keys', 'one_time_prekeys');
SELECT has_column('e2ee_identity_keys', 'consumed_one_time_prekeys');
SELECT has_column('e2ee_identity_keys', 'updated_at');
SELECT col_is_pk('e2ee_identity_keys', 'user_id',
    'e2ee_identity_keys.user_id is the primary key');
SELECT col_type_is('e2ee_identity_keys', 'identity_key', 'text',
    'identity_key is text (base64url X25519 public)');
SELECT col_type_is('e2ee_identity_keys', 'one_time_prekeys', 'jsonb',
    'one_time_prekeys is jsonb');
SELECT col_not_null('e2ee_identity_keys', 'user_id');
SELECT col_not_null('e2ee_identity_keys', 'identity_key');
SELECT col_not_null('e2ee_identity_keys', 'identity_sig_key');
SELECT col_not_null('e2ee_identity_keys', 'signed_prekey_id');
SELECT col_not_null('e2ee_identity_keys', 'signed_prekey');
SELECT col_not_null('e2ee_identity_keys', 'signed_prekey_sig');
SELECT col_not_null('e2ee_identity_keys', 'signed_prekey_expires_at');
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'e2ee_identity_keys'::regclass),
    'e2ee_identity_keys has RLS enabled'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'e2ee_identity_keys'::regclass),
    'e2ee_identity_keys has FORCE ROW LEVEL SECURITY (migration 20260809000003)'
);
SELECT policies_are('e2ee_identity_keys', ARRAY[
    'e2ee_identity_keys_select_own',
    'e2ee_identity_keys_insert_own',
    'e2ee_identity_keys_update_own',
    'e2ee_identity_keys_delete_own'
], 'e2ee_identity_keys has own-row (user_id = auth.uid()) RLS policies');
SELECT has_index('e2ee_identity_keys', 'e2ee_identity_keys_user_id_idx',
    'e2ee_identity_keys has an index on user_id');
SELECT has_function('fetch_prekey_bundle', ARRAY['uuid'],
    'fetch_prekey_bundle(p_user_id uuid) exists (SECURITY DEFINER RPC)');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'fetch_prekey_bundle'),
    'fetch_prekey_bundle sets search_path = '''' (migration 20260809000003)'
);
SELECT function_privs_are('public', 'fetch_prekey_bundle', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'fetch_prekey_bundle is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'fetch_prekey_bundle', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'fetch_prekey_bundle is authenticated-EXECUTABLE');
SELECT is(
    (SELECT relreplident FROM pg_class WHERE oid = 'public.messages'::regclass),
    'f',
    'messages has REPLICA IDENTITY FULL (realtime full-row delivery, E2EE §9.3)'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'messages'
    ),
    'messages is in the supabase_realtime publication (E2EE §9.3)'
);

-- ============================================================
-- SECTION 43: Party Finder discovery (migration 20260809000004,
-- agent I-60) — users.interest_tags + users.discovery_opt_in (user-owned,
-- self-editable), discovery_view security-barrier view (authenticated only).
--   43a. Columns exist with the right type/default/NOT NULL.
--   43b. Trigger/REVOKE interplay (documented decision): the two columns are
--        deliberately NOT in assert_safe_user_update()'s protected set nor in
--        the I-32 column-level REVOKE UPDATE list → authenticated keeps
--        UPDATE (users_update_own, id = auth.uid()) so the opt-in toggle and
--        tags editor persist. Asserted via has_column_priv (UPDATE = true).
--   43c. discovery_view: security barrier, exact column projection
--        (id, username, avatar_url, interest_tags), authenticated SELECT
--        only (anon revoked — no pre-auth enumeration, mirrors I-32 §13).
-- ============================================================

-- 43a: columns + defaults
SELECT has_column('users', 'interest_tags',
    'users.interest_tags exists (migration 20260809000004)');
SELECT has_column('users', 'discovery_opt_in',
    'users.discovery_opt_in exists (migration 20260809000004)');
SELECT col_type_is('users', 'interest_tags', 'text[]',
    'users.interest_tags is text[]');
SELECT col_type_is('users', 'discovery_opt_in', 'boolean',
    'users.discovery_opt_in is boolean');
SELECT col_not_null('users', 'interest_tags',
    'users.interest_tags is NOT NULL');
SELECT col_not_null('users', 'discovery_opt_in',
    'users.discovery_opt_in is NOT NULL');
SELECT ok(
    (SELECT pg_get_expr(adbin, adrelid)::text = '''{}''::text[]'
     FROM pg_catalog.pg_attrdef d
     JOIN pg_catalog.pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE a.attrelid = 'users'::regclass AND a.attname = 'interest_tags'),
    'users.interest_tags defaults to the empty array (opt-in by default)');
SELECT col_default_is('users', 'discovery_opt_in', 'false',
    'users.discovery_opt_in defaults to false (discovery OFF by default)');

-- 43b: user-owned columns keep UPDATE for authenticated
SELECT ok(
    has_column_privilege('authenticated', 'public.users', 'interest_tags', 'UPDATE'),
    'users.interest_tags is UPDATE-able by authenticated (user-owned, PFND)');
SELECT ok(
    has_column_privilege('authenticated', 'public.users', 'discovery_opt_in', 'UPDATE'),
    'users.discovery_opt_in is UPDATE-able by authenticated (user-owned, PFND)');

-- 43c: discovery_view
SELECT has_view('discovery_view',
    'discovery_view exists (migration 20260809000004)');
SELECT columns_are('discovery_view',
    ARRAY['id', 'username', 'avatar_url', 'interest_tags'],
    'discovery_view exposes only id, username, avatar_url, interest_tags');
SELECT ok(
    has_table_privilege('authenticated', 'public.discovery_view', 'SELECT'),
    'discovery_view is SELECT-able by authenticated');
SELECT ok(
    NOT has_table_privilege('anon', 'public.discovery_view', 'SELECT'),
    'discovery_view is not SELECT-able by anon (no pre-auth enumeration)');
SELECT ok(
    (SELECT 'security_barrier=true' = ANY (c.reloptions)
     FROM pg_class c WHERE c.oid = 'discovery_view'::regclass),
    'discovery_view is a security_barrier view (no predicate-pushdown leaks)'
);

-- ============================================================
-- SECTION 44: QR validate RPC (migration 20260809000005, agent I-57) —
-- validate_qr_token: SECURITY DEFINER + SET search_path = '' + FOR UPDATE
-- serialization, PUBLIC EXECUTE revoked, authenticated-only EXECUTE
-- (I-31 hardening pattern; QRSC validator contract).
-- ============================================================
SELECT has_function('validate_qr_token', ARRAY['uuid', 'text'],
    'validate_qr_token(p_event_id uuid, p_token text) exists (migration 20260809000005)');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'validate_qr_token'),
    'validate_qr_token sets search_path = '''' (migration 20260809000005)'
);
SELECT function_privs_are('public', 'validate_qr_token', ARRAY['uuid', 'text']::name[], 'public', ARRAY[]::name[],
    'validate_qr_token is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'validate_qr_token', ARRAY['uuid', 'text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'validate_qr_token is authenticated-EXECUTABLE');

-- ============================================================
-- SECTION 45: create_minigame_session RPC (migration 20260809000006,
-- agent I-63) — GMCR/GWAG foundation: SECURITY DEFINER + SET search_path = ''
-- (I-31 pattern), membership gate via the I-32 is_group_member helper,
-- atomic wager deduct + minigame_wager ledger + session insert (escrow
-- contract, GWAG), business outcomes returned as jsonb statuses, PUBLIC
-- EXECUTE revoked, authenticated-only EXECUTE. Winner-settlement RPCs
-- (minigame_win/minigame_refund) are the documented I-77/S-03 handoff.
-- ============================================================
SELECT has_function('create_minigame_session', ARRAY['uuid', 'text', 'integer'],
    'create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer) exists (migration 20260809000006)');
SELECT ok(
    (SELECT prosecdef FROM pg_proc WHERE proname = 'create_minigame_session'),
    'create_minigame_session is SECURITY DEFINER'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'create_minigame_session'),
    'create_minigame_session sets search_path = '''' (migration 20260809000006)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.is_group_member(p_group_id)%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session references is_group_member'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%minigame_wager%'
       AND pg_get_functiondef(p.oid) LIKE '%public.shard_ledger%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session writes the minigame_wager ledger'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''insufficient_shards''%'
       AND pg_get_functiondef(p.oid) LIKE '%''not_member''%'
       AND pg_get_functiondef(p.oid) LIKE '%''created''%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session returns typed jsonb statuses (I-57 contract)'
);
SELECT function_privs_are('public', 'create_minigame_session', ARRAY['uuid', 'text', 'integer']::name[], 'public', ARRAY[]::name[],
    'create_minigame_session is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'create_minigame_session', ARRAY['uuid', 'text', 'integer']::name[], 'authenticated', ARRAY['EXECUTE'],
    'create_minigame_session is authenticated-EXECUTABLE');

-- ============================================================
-- SECTION 46: Static trigger/constraint/RPC contract (agent I-77,
-- I-76 handoff + I-31/I-32/I-38/I-57/I-63 regression net)
--   46a. Trigger→function bindings (trigger_is) for all 9 triggers from
--        migration 20260510000001 §5 (existence already asserted in
--        Section 8; binding guards against a trigger pointing at the
--        wrong function after a CREATE OR REPLACE).
--   46b. Trigger-function BODY contract (pg_get_functiondef LIKE, I-63
--        Section 45 pattern) — the static equivalent of the behavioral
--        coverage that opt-002/003/004 delegate to pgTAP: message_cap
--        reads app_config chat.message_cap with the 1000 fallback,
--        dynamic_qr derives the flag from preshards_pool in both
--        branches, likes-count recomputes from event_photo_likes.
--   46c. Constraints: check_casual_no_preshards + group_members_status_check
--        (name-anchored pg_constraint checks — pgTAP has_check() only
--        asserts "some check exists", not the name/table) and the UNIQUE
--        column pairs (col_is_unique) that opt-002/004 exercise
--        (event_photo_likes(photo_id,user_id) → 23505, group_members
--        (group_id,user_id), events.invite_token, ...).
--   46d. e2ee_identity_keys full structure (completes Section 41):
--        exact column projection + types + jsonb defaults; fetch_prekey_bundle
--        SECURITY DEFINER (is_definer — Section 41 asserts search_path +
--        grants only).
--   46e. RPC completeness: validate_qr_token SECURITY DEFINER (Section 44
--        gap — prosecdef was not asserted); is_group_member helper
--        (20260809000002 §11.1) existence + SECURITY DEFINER + STABLE +
--        search_path hardening (used by create_minigame_session and
--        group_members_read_same).
-- ============================================================

-- 46a: trigger → function bindings
SELECT trigger_is('public', 'users', 'users_updated_at', 'extensions', 'moddatetime',
    'users_updated_at fires extensions.moddatetime');
SELECT trigger_is('public', 'groups', 'groups_updated_at', 'extensions', 'moddatetime',
    'groups_updated_at fires extensions.moddatetime');
SELECT trigger_is('public', 'events', 'events_updated_at', 'extensions', 'moddatetime',
    'events_updated_at fires extensions.moddatetime');
SELECT trigger_is('public', 'group_members', 'group_size_tier_trigger', 'public', 'update_group_size_tier',
    'group_size_tier_trigger fires update_group_size_tier');
SELECT trigger_is('public', 'events', 'dynamic_qr_enabled_trigger', 'public', 'set_dynamic_qr_enabled',
    'dynamic_qr_enabled_trigger fires set_dynamic_qr_enabled');
SELECT trigger_is('public', 'messages', 'message_cap_trigger', 'public', 'enforce_message_cap',
    'message_cap_trigger fires enforce_message_cap');
SELECT trigger_is('public', 'group_shard_contributions', 'group_shards_increment_trigger', 'public', 'increment_group_shards',
    'group_shards_increment_trigger fires increment_group_shards');
SELECT trigger_is('public', 'event_photo_likes', 'photo_likes_count_trigger', 'public', 'update_photo_likes_count',
    'photo_likes_count_trigger fires update_photo_likes_count');
SELECT trigger_is('public', 'events', 'shard_distribution_dispatch_trigger', 'public', 'dispatch_shard_distribution',
    'shard_distribution_dispatch_trigger fires dispatch_shard_distribution');

-- 46b: trigger-function bodies (static behavioral contract)
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.app_config%'
       AND pg_get_functiondef(p.oid) LIKE '%chat.message_cap%'
       AND pg_get_functiondef(p.oid) LIKE '%1000%'
     FROM pg_proc p WHERE proname = 'enforce_message_cap'),
    'enforce_message_cap reads app_config chat.message_cap with 1000 fallback (I-76 full-cap contract)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%NEW.dynamic_qr_enabled = (NEW.preshards_pool > 0)%'
     FROM pg_proc p WHERE proname = 'set_dynamic_qr_enabled'),
    'set_dynamic_qr_enabled derives dynamic_qr_enabled from preshards_pool (both INSERT and UPDATE branches)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%UPDATE public.event_photos SET likes_count = (%'
       AND pg_get_functiondef(p.oid) LIKE '%SELECT COUNT(*) FROM public.event_photo_likes WHERE photo_id = target_photo_id%'
     FROM pg_proc p WHERE proname = 'update_photo_likes_count'),
    'update_photo_likes_count recomputes likes_count from event_photo_likes (count accuracy)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%UPDATE public.groups SET size_tier = CASE%'
       AND pg_get_functiondef(p.oid) LIKE '%member_count >= 257%'
       AND pg_get_functiondef(p.oid) LIKE '%member_count >= 15%'
     FROM pg_proc p WHERE proname = 'update_group_size_tier'),
    'update_group_size_tier maps member_count to size_tier thresholds (large 257+ / small 15+)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%UPDATE public.groups SET group_shards = group_shards + NEW.shards_contributed%'
     FROM pg_proc p WHERE proname = 'increment_group_shards'),
    'increment_group_shards adds shards_contributed to groups.group_shards'
);

-- 46c: constraints
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'events'::regclass
          AND conname = 'check_casual_no_preshards'
          AND contype = 'c'
    ),
    'events has check_casual_no_preshards (casual events cannot carry a preshards pool, opt-002 TEST B)'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'group_members'::regclass
          AND conname = 'group_members_status_check'
          AND contype = 'c'
    ),
    'group_members has group_members_status_check (status IN active/invited, migration 20260512000011)'
);
SELECT col_is_unique('event_photo_likes', ARRAY['photo_id', 'user_id'],
    'event_photo_likes has UNIQUE (photo_id, user_id) — duplicate likes are 23505 (opt-004 TEST D)');
SELECT col_is_unique('group_members', ARRAY['group_id', 'user_id'],
    'group_members has UNIQUE (group_id, user_id)');
SELECT col_is_unique('event_attendances', ARRAY['event_id', 'user_id'],
    'event_attendances has UNIQUE (event_id, user_id)');
SELECT col_is_unique('user_cosmetics', ARRAY['user_id', 'cosmetic_id'],
    'user_cosmetics has UNIQUE (user_id, cosmetic_id)');
SELECT col_is_unique('event_promotores', ARRAY['event_id', 'user_id'],
    'event_promotores has UNIQUE (event_id, user_id) (opt-002 promotor contract)');
SELECT col_is_unique('event_invites', ARRAY['event_id', 'user_id'],
    'event_invites has UNIQUE (event_id, user_id)');
SELECT col_is_unique('chat_participants', ARRAY['chat_id', 'user_id'],
    'chat_participants has UNIQUE (chat_id, user_id)');
SELECT col_is_unique('group_cosmetics', ARRAY['group_id', 'cosmetic_id'],
    'group_cosmetics has UNIQUE (group_id, cosmetic_id)');
SELECT col_is_unique('events', 'invite_token',
    'events.invite_token is UNIQUE (invite links, opt-002 TEST A)');

-- 46d: e2ee_identity_keys structure (completes Section 41)
SELECT columns_are('e2ee_identity_keys', ARRAY[
    'user_id', 'identity_key', 'identity_sig_key', 'signed_prekey_id',
    'signed_prekey', 'signed_prekey_sig', 'signed_prekey_expires_at',
    'one_time_prekeys', 'consumed_one_time_prekeys', 'updated_at'
], 'e2ee_identity_keys exposes exactly the 10 X3DH columns (migration 20260809000003)');
SELECT col_type_is('e2ee_identity_keys', 'user_id', 'uuid',
    'e2ee_identity_keys.user_id is uuid (FK to users.id)');
SELECT col_type_is('e2ee_identity_keys', 'identity_sig_key', 'text',
    'identity_sig_key is text (base64url Ed25519)');
SELECT col_type_is('e2ee_identity_keys', 'signed_prekey_id', 'integer',
    'signed_prekey_id is integer (spk_id carried by init envelopes)');
SELECT col_type_is('e2ee_identity_keys', 'signed_prekey', 'text',
    'signed_prekey is text (base64url X25519 signed prekey)');
SELECT col_type_is('e2ee_identity_keys', 'signed_prekey_sig', 'text',
    'signed_prekey_sig is text (Ed25519 sig over signed_prekey)');
SELECT col_type_is('e2ee_identity_keys', 'signed_prekey_expires_at', 'timestamptz',
    'signed_prekey_expires_at is timestamptz');
SELECT col_type_is('e2ee_identity_keys', 'consumed_one_time_prekeys', 'jsonb',
    'consumed_one_time_prekeys is jsonb (audit trail)');
SELECT col_type_is('e2ee_identity_keys', 'updated_at', 'timestamptz',
    'updated_at is timestamptz');
SELECT ok(
    (SELECT pg_get_expr(adbin, adrelid)::text = '''[]''::jsonb'
     FROM pg_catalog.pg_attrdef d
     JOIN pg_catalog.pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE a.attrelid = 'e2ee_identity_keys'::regclass AND a.attname = 'one_time_prekeys'),
    'one_time_prekeys defaults to the empty array');
SELECT ok(
    (SELECT pg_get_expr(adbin, adrelid)::text = '''[]''::jsonb'
     FROM pg_catalog.pg_attrdef d
     JOIN pg_catalog.pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE a.attrelid = 'e2ee_identity_keys'::regclass AND a.attname = 'consumed_one_time_prekeys'),
    'consumed_one_time_prekeys defaults to the empty array');
SELECT is_definer('public', 'fetch_prekey_bundle', ARRAY['uuid'],
    'fetch_prekey_bundle is SECURITY DEFINER');

-- 46e: RPC completeness
SELECT is_definer('public', 'validate_qr_token', ARRAY['uuid', 'text'],
    'validate_qr_token is SECURITY DEFINER (migration 20260809000005)');
SELECT has_function('is_group_member', ARRAY['uuid'],
    'is_group_member(p_group_id uuid) exists (migration 20260809000002 §11.1)');
SELECT is_definer('public', 'is_group_member', ARRAY['uuid'],
    'is_group_member is SECURITY DEFINER (RLS-recursion-safe helper)');
SELECT volatility_is('public', 'is_group_member', ARRAY['uuid'], 'stable',
    'is_group_member is STABLE (usable inside RLS policies)');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'is_group_member'),
    'is_group_member sets search_path = '''' (migration 20260809000002)'
);

-- ============================================================
-- SECTION 47: Storage buckets + storage.objects RLS (agent M-08,
-- migration 20260810000007 — S-09/M-track bucket-creation gap closure)
--   47a. The storage schema tables exist — storage.buckets /
--        storage.objects are created by the storage-api tenant migrations
--        (0002/0007/0008, all present in the pinned storage-api v1.60.4),
--        NOT by the app migrations; the bucket rows + objects RLS policies
--        below are what 20260810000007 adds. has_table with an explicit
--        schema also guards against the storage schema being dropped.
--   47b. Bucket rows exist with the exact public flags: avatars=true,
--        groups=true (public reads via getPublicUrl), events=false (private
--        — PHUP signed-URL retrieval only).
--   47c. storage.objects RLS is enabled (relrowsecurity) and the five
--        migration policies are present under their exact names
--        (policies_are).
-- ============================================================

-- 47a: storage schema tables
SELECT has_table('storage', 'buckets',
    'storage.buckets exists (storage-api tenant schema, asserted by M-08)');
SELECT has_table('storage', 'objects',
    'storage.objects exists (storage-api tenant schema, asserted by M-08)');

-- 47b: bucket rows + public flags (migration 20260810000007 §1)
SELECT results_eq(
    'SELECT id FROM storage.buckets WHERE id IN (''avatars'', ''groups'', ''events'') ORDER BY id',
    ARRAY['avatars', 'events', 'groups']::text[],
    'avatars/groups/events bucket rows exist (migration 20260810000007)'
);
SELECT ok(
    (SELECT public FROM storage.buckets WHERE id = 'avatars'),
    'avatars bucket is public=true (app reads avatars via getPublicUrl)'
);
SELECT ok(
    (SELECT public FROM storage.buckets WHERE id = 'groups'),
    'groups bucket is public=true (app reads group covers via getPublicUrl)'
);
SELECT ok(
    NOT (SELECT public FROM storage.buckets WHERE id = 'events'),
    'events bucket is public=false (private — PHUP signed-URL retrieval only)'
);

-- 47c: objects RLS enabled + exact policy set
SELECT ok(
    (SELECT relrowsecurity FROM pg_catalog.pg_class
     WHERE oid = 'storage.objects'::regclass),
    'storage.objects has ROW LEVEL SECURITY enabled (storage-api 0002)'
);
SELECT policies_are('storage', 'objects', ARRAY[
    'storage_objects_delete_own',
    'storage_objects_events_select_access',
    'storage_objects_insert_own',
    'storage_objects_public_read_avatars_groups',
    'storage_objects_update_own'
], 'storage.objects has exactly the 5 M-08 policies (public read avatars/groups, events select-access, own insert/update/delete)');

-- ============================================================
-- SECTION 48: Function EXECUTE hardening (20260811000001)
-- The supabase image's default privileges granted anon EXECUTE on every
-- function created by postgres/supabase_admin in public; prior per-function
-- REVOKE ... FROM PUBLIC only removed the PUBLIC entry. Section asserts the
-- hardened posture (anon excluded everywhere except the two intended cases).
-- ============================================================

SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prosecdef
       AND has_function_privilege('anon', p.oid, 'EXECUTE')
       AND p.proname NOT IN ('check_signup_email', 'is_group_member')) = 0,
    'anon cannot EXECUTE any SECURITY DEFINER function (except check_signup_email + is_group_member RLS helper)'
);

SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_default_acl d
     JOIN pg_roles r ON r.oid = d.defaclrole
     JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
     WHERE n.nspname = 'public'
       AND r.rolname IN ('postgres', 'supabase_admin')
       AND d.defaclobjtype = 'f'
       AND d.defaclacl::text LIKE '%anon=X%') = 0,
    'public-schema default privileges no longer grant anon EXECUTE on functions (20260811000001)'
);

SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('donate_shards_to_group', 'fetch_prekey_bundle',
                         'validate_qr_token', 'create_minigame_session')
       AND has_function_privilege('authenticated', p.oid, 'EXECUTE')) = 4,
    'authenticated can EXECUTE the 4 client RPCs'
);

SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('grant_shards', 'grant_preshards', 'distribute_shards',
                         'recalculate_ranks', 'hard_delete_expired_users')
       AND has_function_privilege('service_role', p.oid, 'EXECUTE')) = 5,
    'service_role can EXECUTE the 5 admin RPCs'
);

SELECT ok(
    has_function_privilege('anon', 'public.check_signup_email(text)', 'EXECUTE'),
    'check_signup_email remains anon-callable (pre-auth email check, by design)'
);

SELECT ok(
    has_function_privilege('anon', 'public.is_group_member(uuid)', 'EXECUTE'),
    'is_group_member remains anon-callable (invoked from RLS policies)'
);

-- donate_shards_to_group NULL-uid guard: unauthenticated sessions have
-- auth.uid() = NULL; the old `auth.uid() != p_user_id` guard evaluated NULL
-- (not TRUE) and silently passed. Setting empty jwt claims reproduces it.
SELECT set_config('request.jwt.claims', '{}', true);
SELECT throws_ok($$SELECT public.donate_shards_to_group('00000000-0000-0000-0000-000000000000'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 50, '2026-12-31T23:59:59Z')$$,
    'P0001', 'Not authorized',
    'donate_shards_to_group NULL-uid guard raises Not authorized (20260811000001)');

SELECT * FROM finish();
ROLLBACK;
