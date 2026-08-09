-- Samay Schema pgTAP Tests — Comprehensive
-- Covers all 21 migrations (20260510000001 through 20260809000003).
BEGIN;

SELECT plan(235);

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
SELECT has_function_priv('public', 'check_signup_email', ARRAY['text'], 'anon', 'EXECUTE',
    'anon has EXECUTE on check_signup_email');
SELECT has_function_priv('public', 'check_signup_email', ARRAY['text'], 'authenticated', 'EXECUTE',
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
    (SELECT 'search_path=' = ANY (proconfig) FROM pg_proc WHERE proname = 'update_group_size_tier'),
    'update_group_size_tier sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=' = ANY (proconfig) FROM pg_proc WHERE proname = 'set_dynamic_qr_enabled'),
    'set_dynamic_qr_enabled sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=' = ANY (proconfig) FROM pg_proc WHERE proname = 'enforce_message_cap'),
    'enforce_message_cap sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=' = ANY (proconfig) FROM pg_proc WHERE proname = 'increment_group_shards'),
    'increment_group_shards sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=' = ANY (proconfig) FROM pg_proc WHERE proname = 'update_photo_likes_count'),
    'update_photo_likes_count sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=' = ANY (proconfig) FROM pg_proc WHERE proname = 'dispatch_shard_distribution'),
    'dispatch_shard_distribution sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=' = ANY (proconfig) FROM pg_proc WHERE proname = 'hard_delete_expired_users'),
    'hard_delete_expired_users sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=' = ANY (proconfig) FROM pg_proc WHERE proname = 'donate_shards_to_group'),
    'donate_shards_to_group sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=' = ANY (proconfig) FROM pg_proc WHERE proname = 'grant_shards'),
    'grant_shards sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=' = ANY (proconfig) FROM pg_proc WHERE proname = 'grant_preshards'),
    'grant_preshards sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=' = ANY (proconfig) FROM pg_proc WHERE proname = 'distribute_shards'),
    'distribute_shards sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=' = ANY (proconfig) FROM pg_proc WHERE proname = 'recalculate_ranks'),
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

-- 39a: users protected columns are not UPDATE-able by authenticated
SELECT hasnt_column_priv('public', 'users', 'personal_shards', 'authenticated', 'UPDATE',
    'users.personal_shards is not UPDATE-able by authenticated (G-03)');
SELECT hasnt_column_priv('public', 'users', 'preshards', 'authenticated', 'UPDATE',
    'users.preshards is not UPDATE-able by authenticated (G-03)');
SELECT hasnt_column_priv('public', 'users', 'subscription_tier', 'authenticated', 'UPDATE',
    'users.subscription_tier is not UPDATE-able by authenticated (G-03)');
SELECT hasnt_column_priv('public', 'users', 'subscription_expires_at', 'authenticated', 'UPDATE',
    'users.subscription_expires_at is not UPDATE-able by authenticated (G-03)');
SELECT hasnt_column_priv('public', 'users', 'banned_at', 'authenticated', 'UPDATE',
    'users.banned_at is not UPDATE-able by authenticated (G-03)');
SELECT hasnt_column_priv('public', 'users', 'ban_reason', 'authenticated', 'UPDATE',
    'users.ban_reason is not UPDATE-able by authenticated (G-03)');
SELECT hasnt_column_priv('public', 'users', 'date_of_birth', 'authenticated', 'UPDATE',
    'users.date_of_birth is not UPDATE-able by authenticated (G-03)');

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
SELECT hasnt_function_priv('public', 'grant_shards', ARRAY['uuid', 'integer', 'text'], 'public', 'EXECUTE',
    'grant_shards is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT has_function_priv('public', 'grant_shards', ARRAY['uuid', 'integer', 'text'], 'service_role', 'EXECUTE',
    'grant_shards is service_role-EXECUTABLE');
SELECT hasnt_function_priv('public', 'grant_preshards', ARRAY['uuid', 'integer', 'text'], 'public', 'EXECUTE',
    'grant_preshards is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT has_function_priv('public', 'grant_preshards', ARRAY['uuid', 'integer', 'text'], 'service_role', 'EXECUTE',
    'grant_preshards is service_role-EXECUTABLE');
SELECT hasnt_function_priv('public', 'distribute_shards', ARRAY['uuid'], 'public', 'EXECUTE',
    'distribute_shards is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT has_function_priv('public', 'distribute_shards', ARRAY['uuid'], 'service_role', 'EXECUTE',
    'distribute_shards is service_role-EXECUTABLE');
SELECT hasnt_function_priv('public', 'recalculate_ranks', ARRAY['text'], 'public', 'EXECUTE',
    'recalculate_ranks is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT has_function_priv('public', 'recalculate_ranks', ARRAY['text'], 'service_role', 'EXECUTE',
    'recalculate_ranks is service_role-EXECUTABLE');
SELECT hasnt_function_priv('public', 'hard_delete_expired_users', ARRAY[]::text[], 'public', 'EXECUTE',
    'hard_delete_expired_users is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT has_function_priv('public', 'hard_delete_expired_users', ARRAY[]::text[], 'service_role', 'EXECUTE',
    'hard_delete_expired_users is service_role-EXECUTABLE');

-- 39d: server-managed groups/events columns revoked from authenticated
SELECT hasnt_column_priv('public', 'groups', 'group_shards', 'authenticated', 'INSERT',
    'groups.group_shards is not INSERT-able by authenticated');
SELECT hasnt_column_priv('public', 'groups', 'size_tier', 'authenticated', 'INSERT',
    'groups.size_tier is not INSERT-able by authenticated');
SELECT hasnt_column_priv('public', 'groups', 'frozen_at', 'authenticated', 'INSERT',
    'groups.frozen_at is not INSERT-able by authenticated');
SELECT hasnt_column_priv('public', 'groups', 'group_shards', 'authenticated', 'UPDATE',
    'groups.group_shards is not UPDATE-able by authenticated');
SELECT hasnt_column_priv('public', 'groups', 'size_tier', 'authenticated', 'UPDATE',
    'groups.size_tier is not UPDATE-able by authenticated');
SELECT hasnt_column_priv('public', 'groups', 'frozen_at', 'authenticated', 'UPDATE',
    'groups.frozen_at is not UPDATE-able by authenticated');
SELECT hasnt_column_priv('public', 'groups', 'rank_bracket', 'authenticated', 'UPDATE',
    'groups.rank_bracket is not UPDATE-able by authenticated');
SELECT hasnt_column_priv('public', 'events', 'preshards_distributed', 'authenticated', 'UPDATE',
    'events.preshards_distributed is not UPDATE-able by authenticated');
SELECT hasnt_column_priv('public', 'events', 'featured', 'authenticated', 'UPDATE',
    'events.featured is not UPDATE-able by authenticated');
SELECT hasnt_column_priv('public', 'events', 'featured_until', 'authenticated', 'UPDATE',
    'events.featured_until is not UPDATE-able by authenticated');

-- 39e: user_search_view authenticated-only
SELECT hasnt_table_priv('public', 'user_search_view', 'anon', 'SELECT',
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
    (SELECT 'search_path=' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'fetch_prekey_bundle'),
    'fetch_prekey_bundle sets search_path = '''' (migration 20260809000003)'
);
SELECT hasnt_function_priv('public', 'fetch_prekey_bundle', ARRAY['uuid'], 'public', 'EXECUTE',
    'fetch_prekey_bundle is not PUBLIC-EXECUTABLE');
SELECT has_function_priv('public', 'fetch_prekey_bundle', ARRAY['uuid'], 'authenticated', 'EXECUTE',
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

SELECT * FROM finish();
ROLLBACK;
