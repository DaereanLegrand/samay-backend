-- Samay Schema pgTAP Tests — slim-prod surface
-- Covers the SURVIVING schema of slim production Samay: extensions, enums,
-- the kept tables (users, friendships, groups, group_members, group_themes,
-- notifications, device_tokens, minigame_*, prompt_packs, app_config,
-- admin_*, reports, appeals, action_rate_limits, signup_tracker, ...), their
-- keys/indexes/RLS policies/ACLs, and the kept RPCs and their signatures.
--
-- Removed features (events, E2EE chat, feed, photos, rankings,
-- shards/wagers/cosmetics, event share links) keep their tables but no
-- client role may touch them (300_slim/05_revoke_removed.sql); that closed
-- ACL IS asserted (Sections 19/26/29). The 300_slim forward-fix contracts
-- (onboarding, prompt packs, wager removal, leave-session) are covered by
-- supabase/tests/slim_test.sql and only spot-checked here.
BEGIN;

SELECT plan(901);

-- ============================================================
-- SECTION 1: Extensions (migration 20260510000001)
-- ============================================================
SELECT has_extension('pgcrypto');
SELECT has_extension('moddatetime');
SELECT has_extension('pg_cron');

-- ============================================================
-- SECTION 2: Enums — the 22 baseline types (migrations 20260510000001,
-- 20260520000001). The event/cosmetic/shard enums are kept even though their
-- features are removed (enum types are cheap and the removed tables still
-- reference them). mini_game_invite_status and group_theme_mode are asserted
-- in Sections 49b and 75.
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
SELECT has_type('report_category');
SELECT has_type('report_status');
SELECT has_type('admin_role');
SELECT has_type('preshard_remainder_action');
SELECT has_type('feature_request_status');

-- ============================================================
-- SECTION 3: Kept tables (slim-prod surface). The removed-feature tables
-- (events*, chat*, shards/cosmetics/rankings) still EXIST — their data is
-- retained and the migration history is immutable — but no client role may
-- touch them (asserted in Sections 19/26/29).
-- ============================================================
SELECT has_table('users');
SELECT has_table('friendships');
SELECT has_table('groups');
SELECT has_table('group_members');
SELECT has_table('group_themes');
SELECT has_table('group_theme_changes');
SELECT has_table('notifications');
SELECT has_table('device_tokens');
SELECT has_table('feature_requests');
SELECT has_table('reports');
SELECT has_table('appeals');
SELECT has_table('user_mutes');
SELECT has_table('moderation_evidence');
SELECT has_table('admin_users');
SELECT has_table('admin_audit_log');
SELECT has_table('subscription_overrides');
SELECT has_table('processed_webhooks');
SELECT has_table('webhook_failures');
SELECT has_table('app_config');
SELECT has_table('action_rate_limits');
SELECT has_table('retention_matrix');
SELECT has_table('account_deletion_audit');
SELECT has_table('auth_cleanup_queue');

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
-- (bio added 20260815000001 — public profile copy only; the sensitive
--  columns stay out of the barrier.)
-- ============================================================
SELECT has_view('user_search_view');
SELECT columns_are('user_search_view', ARRAY['id', 'username', 'avatar_url', 'bio', 'profile_public'],
    'user_search_view exposes the safe identity columns + profile_public (Q8)');

-- ============================================================
-- SECTION 8: Triggers — kept feature tables (migrations
-- 20260510000001, 20260512000007)
-- ============================================================
SELECT has_trigger('users', 'users_updated_at');
SELECT has_trigger('groups', 'groups_updated_at');
SELECT has_trigger('group_members', 'group_size_tier_trigger');

-- ============================================================
-- SECTION 9: Trigger Functions — kept (SECURITY DEFINER)
-- ============================================================
SELECT has_function('update_group_size_tier');

-- ============================================================
-- SECTION 11: RPC — hard_delete_expired_users (migration 20260510000002)
-- ============================================================
SELECT has_function('hard_delete_expired_users');

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
    'friendships_delete_own',
    'active_users_only'
], 'friendships has expected RLS policies');

-- ============================================================
-- SECTION 17: RLS Policies — groups
-- groups_delete_own added by migration 20260809000002 (I-32) — creator
-- deletes own group during leaveGroup's empty-group cleanup.
-- ============================================================
SELECT policies_are('groups', ARRAY[
    'groups_read_member',
    'groups_read_own',
    'groups_update_host',
    'groups_insert_own',
    'groups_delete_own',
    'active_users_only'
], 'groups has expected RLS policies');

-- ============================================================
-- SECTION 18: RLS Policies — group_members (no recursion)
-- Migration 20260809000002 (I-32): insert_creator → insert_host
-- (creator self-insert + host invites), read_same restored via
-- SECURITY DEFINER is_group_member() (member lists), update_own_status
-- added (invitees accept their own invite; role pinned to 'member').
-- ============================================================
SELECT policies_are('group_members', ARRAY[
    'group_members_read_own',
    'group_members_read_same',
    'group_members_insert_host',
    'group_members_delete_own',
    'group_members_delete_host',
    'group_members_update_own_status',
    'group_members_update_host',
    'active_users_only'
], 'group_members has expected RLS policies (no recursion)');

-- ============================================================
-- SECTION 19: Removed event surface — clients cannot read it
-- (300_slim/05_revoke_removed.sql). The tables still exist (data retained)
-- but anon/authenticated hold NO grant; the events feature is not part of
-- slim-prod, and re-granting is the whole re-add.
-- ============================================================
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.event_hosts', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.event_invites', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.event_attendances', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.event_photos', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.event_photo_likes', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.event_scan_nonces', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.event_code_keys', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.event_join_requests', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.share_links', 'SELECT'),
    'authenticated cannot read any removed event relation (event_* + share_links)'
);
SELECT ok(
    NOT has_table_privilege('anon', 'public.event_hosts', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.event_invites', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.event_attendances', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.event_photos', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.event_photo_likes', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.share_links', 'SELECT'),
    'anon cannot read any removed event relation'
);

-- ============================================================
-- SECTION 26: Removed E2EE chat surface — clients cannot read it
-- (300_slim/05_revoke_removed.sql). Chats/messages/read receipts/prekeys
-- and the group-chat notice table remain for data retention only.
-- ============================================================
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.messages', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.chat_participants', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.message_reads', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.deleted_messages', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.message_reports', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.e2ee_identity_keys', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.minigame_group_messages', 'SELECT'),
    'authenticated cannot read any removed chat/E2EE relation'
);
SELECT ok(
    NOT has_table_privilege('anon', 'public.messages', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.chat_participants', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.message_reads', 'SELECT'),
    'anon cannot read any removed chat relation'
);

-- ============================================================
-- SECTION 28c: users.profile_public — kept privacy flag (search_users reads
-- it to keep private profiles exact-match only, Q8).
-- ============================================================
SELECT has_column('users', 'profile_public',
    'users has the profile_public privacy flag');
SELECT col_type_is('users', 'profile_public', 'boolean',
    'profile_public is boolean');
SELECT col_not_null('users', 'profile_public',
    'profile_public is NOT NULL — every account starts private');
SELECT col_default_is('users', 'profile_public', 'false',
    'profile_public defaults false — anonymous until the user opts in');

-- ============================================================
-- SECTION 29: Removed shard / cosmetics / ranking surface — clients cannot
-- read or write it (300_slim/05_revoke_removed.sql). Wagers and cosmetics
-- are retired from slim-prod; the ledgers and rank snapshots are retained
-- server-side only.
-- ============================================================
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.preshard_ledger', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.group_shard_contributions', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.group_rank_snapshots', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.group_rank_snapshots', 'SELECT'),
    'authenticated/anon cannot read preshard, contribution or rank-snapshot rows'
);
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.cosmetics', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.group_cosmetics', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.user_cosmetics', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.user_cosmetics', 'UPDATE')
    AND NOT has_table_privilege('anon', 'public.cosmetics', 'SELECT'),
    'cosmetics are fully closed to clients (no read, no equip write)'
);

-- ============================================================
-- SECTION 32: RLS Policies — remaining non-admin tables
-- ============================================================
SELECT policies_are('minigame_sessions', ARRAY[
    'ms_read_group_member',
    'ms_read_invitee',
    'ms_read_direct_participant',
    'active_users_only'
], 'minigame_sessions has invite/participant-only policies (E4 code-only matches)');
SELECT col_is_null('minigame_sessions', 'group_id',
    'minigame_sessions.group_id is NULLABLE (NULL = direct session, direct-minigames 2026-08-27)');
SELECT col_not_null('minigame_sessions', 'player_limit',
    'minigame_sessions.player_limit is NOT NULL (subscription-scaled player cap, frozen at creation)');
SELECT col_has_default('minigame_sessions', 'player_limit',
    'minigame_sessions.player_limit defaults to 8 (free tier baseline)');
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'minigame_sessions'
          AND policyname = 'ms_read_direct_participant'
          AND cmd = 'SELECT'
          AND qual LIKE '%group_id IS NULL%'
          AND qual LIKE '%participants%'
    )),
    'ms_read_direct_participant requires group_id IS NULL AND auth.uid() IN participants (direct-session read only)'
);
SELECT policies_are('notifications', ARRAY[
    'notif_read_own',
    'notif_update_own',
    'active_users_only'
], 'notifications has expected RLS policies');
SELECT policies_are('feature_requests', ARRAY[
    'fr_read_own',
    'fr_insert_own'
], 'feature_requests has expected RLS policies');
SELECT policies_are('reports', ARRAY[
    'reports_insert_own',
    'active_users_only'
], 'reports has expected RLS policies');
SELECT policies_are('app_config', ARRAY[
    'app_config_read_all'
], 'app_config is public-readable');
-- prompt_packs — the RevenueCat-tiered prompt-pack catalogue (300_slim/02).
-- Its seed + RPC contracts live in slim_test.sql; here we pin the schema.
SELECT columns_are('prompt_packs',
    ARRAY['id', 'game_type', 'name', 'tier_requirement', 'pack_version',
          'is_active', 'created_at', 'updated_at'],
    'prompt_packs exposes exactly the pack columns (300_slim/02)');
SELECT col_is_pk('prompt_packs', 'id', 'prompt_packs.id is the primary key');
SELECT col_type_is('prompt_packs', 'game_type', 'public.mini_game_type',
    'prompt_packs.game_type is the mini_game_type enum');
SELECT col_type_is('prompt_packs', 'tier_requirement', 'public.subscription_tier',
    'prompt_packs.tier_requirement is the subscription_tier enum (free/pro/vip)');
SELECT fk_ok('minigame_prompts', ARRAY['pack_id'::name], 'prompt_packs', ARRAY['id'::name],
    'minigame_prompts.pack_id references prompt_packs.id (300_slim/02)');


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
-- seed-config.sql is the fundamental config (applied by start/reset; app_config tuning
-- keys + the system admin row); it seeds NO user accounts. Test data is
-- explicit-only (`make seed`). The row counts below pin the
-- current seed-config surface; a removable tuning key changes the total.
-- ============================================================
SELECT ok(
    (SELECT count(*) = 1 FROM admin_users),
    'admin_users has the system admin row (from seed-config)'
);
SELECT ok(
    (SELECT count(*) = 48 FROM app_config),
    'app_config has 48 tuning rows (seed-config baseline)'
);

-- ============================================================
-- SECTION 35: admin_users retains display_name (never dropped)
-- ============================================================
SELECT has_column('admin_users', 'display_name',
    'admin_users retains display_name (only dropped from users)');
SELECT ok(
    (SELECT NOT EXISTS (
        SELECT 1 FROM users WHERE username = 'reviewer')),
    'seed-config seeds no user rows (reviewer is staging-only)'
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
-- SECTION 37b: RPC — upsert_signup_tracker (migration 20260812000001)
-- ============================================================
-- SECURITY DEFINER pre-auth signup_tracker WRITE used by sendOtp()
-- (lib/core/services/auth_service.dart): the email-scoped RLS policies
-- (email = auth.jwt()->>'email') can never match an ANONYMOUS JWT (no
-- email claim), so the client's pre-OTP upsert 42501'd into the OTP
-- funnel's "No tienes permiso..." error. Same posture as check_signup_email:
-- search_path = '' + EXECUTE granted to anon + authenticated only. The
-- p_profile_created = true branch is gated on the JWT email matching
-- p_email (anon must not be able to squat 'exists' rows).
SELECT has_function('upsert_signup_tracker', ARRAY['text', 'boolean'],
    'upsert_signup_tracker(p_email text, p_profile_created boolean) exists');
SELECT is((SELECT prosecdef FROM pg_proc WHERE proname = 'upsert_signup_tracker'),
    true, 'upsert_signup_tracker is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY(proconfig) FROM pg_proc WHERE proname = 'upsert_signup_tracker'),
    'upsert_signup_tracker sets search_path = '''' (migration 20260812000001)'
);
SELECT function_privs_are('public', 'upsert_signup_tracker', ARRAY['text', 'boolean']::name[], 'anon', ARRAY['EXECUTE'],
    'anon has EXECUTE on upsert_signup_tracker');
SELECT function_privs_are('public', 'upsert_signup_tracker', ARRAY['text', 'boolean']::name[], 'authenticated', ARRAY['EXECUTE'],
    'authenticated has EXECUTE on upsert_signup_tracker');
-- Behavioral: anon-style claims (no email claim) can write the pre-verify
-- row (profile_created = false) but cannot squat profile_created = true.
SELECT set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000000","role":"anon"}', false);
SELECT lives_ok($$SELECT public.upsert_signup_tracker('tracker-probe@test.local', false)$$,
    'anon-style claims: pre-verify write (profile_created = false) works');
SELECT throws_ok($$SELECT public.upsert_signup_tracker('tracker-probe@test.local', true)$$,
    'P0001', 'Not authorized',
    'anon-style claims: profile_created = true raises (JWT-email guard, 20260812000001)');

-- ============================================================
-- SECTION 38: Hardening migration 20260809000001 (agent I-31)
--   38a. FORCE ROW LEVEL SECURITY on the kept, RLS-enabled tables (the
--        signup_tracker pattern from Section 6).
--   38b. SET search_path = '' on the kept hardened SECURITY DEFINER
--        functions — asserted via pg_proc.proconfig containing 'search_path='.
--   38c. service_role BYPASSRLS — FORCE RLS must NOT lock out the admin CLI
--        (Go + SUPABASE_SERVICE_ROLE_KEY via PostgREST as service_role;
--        bypassrls granted by the supabase/postgres image's baked-in
--        00-initial-schema.sql, verified against upstream at commit 8d3216973).
-- ============================================================

-- 38a: FORCE ROW LEVEL SECURITY — kept tables only
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'users'::regclass),
    'users has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
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
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'hard_delete_expired_users'),
    'hard_delete_expired_users sets search_path = '''' (migration 20260809000001)'
);

-- 38c: service_role BYPASSRLS — admin CLI keeps bypassing RLS under FORCE
SELECT ok(
    (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'service_role'),
    'service_role has BYPASSRLS — FORCE RLS does not lock out admin (migration 20260809000001)'
);
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
-- 39g: server-managed groups/events triggers (migration 20260811000001)
SELECT has_trigger('groups', 'assert_safe_group_update_trigger',
    'groups has assert_safe_group_update_trigger (migration 20260811000001)');
-- 39e: user_search_view is server-RPC-only (Q8: no directory enumeration)
SELECT ok(
    NOT has_table_privilege('anon', 'public.user_search_view', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.user_search_view', 'SELECT'),
    'user_search_view is not SELECT-able by anon/authenticated (Q8 RPC-only)');
SELECT ok(
    has_table_privilege('service_role', 'public.user_search_view', 'SELECT'),
    'service_role keeps SELECT on user_search_view');

-- ============================================================
-- SECTION 41: friendships realtime (20260815000002) — the kept social graph
-- streams live. The removed chat tables keep their publication membership
-- but no client can read them, so their realtime presence is not part of
-- the slim contract.
-- ============================================================
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'friendships'
    ),
    'friendships is in the supabase_realtime publication (friendships realtime, 20260815000002)'
);

-- ============================================================
-- SECTION 43: discovery columns + view (migration 20260809000004, agent I-60)
--   43a. users.interest_tags + users.discovery_opt_in exist with the right
--        type/default/NOT NULL (kept columns; the Party Finder itself is
--        removed and discovery_view is closed to both client roles).
--   43b. clients cannot UPDATE either column (profile-RPC lockdown).
--   43c. discovery_view keeps its security-barrier shape and exact column
--        projection; it is not SELECT-able by anon (and no longer by
--        authenticated — 300_slim/05_revoke_removed.sql).
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

-- 43b: user-owned columns moved behind RPCs (2026-08-25 profile-RPC
-- lockdown): clients lost table/column UPDATE entirely — discovery_opt_in is
-- mutated through set_discovery_opt_in(), interest_tags has no client setter
-- (no writers exist). The UPDATE-able pins from the PFND era are inverted.
SELECT ok(
    NOT has_column_privilege('authenticated', 'public.users', 'interest_tags', 'UPDATE'),
    'users.interest_tags is NOT UPDATE-able by authenticated (RPC lockdown 2026-08-25)');
SELECT ok(
    NOT has_column_privilege('authenticated', 'public.users', 'discovery_opt_in', 'UPDATE'),
    'users.discovery_opt_in is NOT UPDATE-able by authenticated (mutated via set_discovery_opt_in)');

-- 43c: discovery_view — Party Finder is removed, so the view is closed to the
-- pre-auth role (the authenticated closure is pinned by slim_test.sql).
SELECT ok(
    NOT has_table_privilege('anon', 'public.discovery_view', 'SELECT'),
    'discovery_view is not SELECT-able by anon (no pre-auth enumeration)'
);

-- ============================================================
-- SECTION 45: create_minigame_session RPC (300_slim/03_remove_wagers —
-- wager-free 10-arg signature). SECURITY DEFINER + SET search_path = '',
-- membership gate via is_group_member, invite validation (blocked/deleted +
-- friends-only privacy + player cap), one minigame_invites row per invitee,
-- a session insert with NO wager/escrow and the game-state row seeded at
-- creation. Business outcomes are typed jsonb statuses; PUBLIC/anon EXECUTE
-- revoked, authenticated-only.
-- ============================================================
SELECT has_function('create_minigame_session',
    ARRAY['uuid', 'text', 'uuid[]', 'text', 'integer', 'integer', 'text', 'boolean', 'integer', 'timestamp with time zone'],
    'create_minigame_session(p_group_id, p_game_type, p_invitees, p_name, p_rounds, p_prize_positions, p_play_mode, p_anonymous, p_async_rounds_per_player, p_async_ends_at) exists (wager-free 10-arg)');
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'create_minigame_session' AND pronargs = 11
    ),
    'the 11-arg wager overload is dropped (wagers removed)'
);
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'create_minigame_session' AND 'p_wager' = ANY (proargnames)
    ),
    'no create_minigame_session overload takes p_wager'
);
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'create_minigame_session' AND pronargs = 3
    ),
    'the pre-invite 3-arg create_minigame_session overload is dropped'
);
SELECT ok(
    (SELECT prosecdef FROM pg_proc WHERE proname = 'create_minigame_session'),
    'create_minigame_session is SECURITY DEFINER'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'create_minigame_session'),
    'create_minigame_session sets search_path = '''' '
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.is_group_member(p_group_id)%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session references is_group_member'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) NOT LIKE '%minigame_wager%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%public.shard_ledger%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%insufficient_shards%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session writes no wager/ledger/escrow (wagers removed)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''not_member''%'
       AND pg_get_functiondef(p.oid) LIKE '%''created''%'
       AND pg_get_functiondef(p.oid) LIKE '%''invited''%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session returns typed jsonb statuses'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.minigame_invites%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session writes one minigame_invites row per invitee (140_minigame_invites)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%minigame_invite_friends_only%'
       AND pg_get_functiondef(p.oid) LIKE '%friendships%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session enforces the friends-only invite privacy switch server-side'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''invitee_not_allowed''%'
       AND pg_get_functiondef(p.oid) LIKE '%''invitee_friends_only''%'
       AND pg_get_functiondef(p.oid) LIKE '%''too_many_invitees''%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session returns typed invitee rejection statuses'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%status = ''blocked''::public.friendship_status%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session rejects blocked invitees (either direction)'
);
SELECT function_privs_are('public', 'create_minigame_session',
    ARRAY['uuid', 'text', 'uuid[]', 'text', 'integer', 'integer', 'text', 'boolean', 'integer', 'timestamp with time zone']::name[], 'public', ARRAY[]::name[],
    'create_minigame_session is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'create_minigame_session',
    ARRAY['uuid', 'text', 'uuid[]', 'text', 'integer', 'integer', 'text', 'boolean', 'integer', 'timestamp with time zone']::name[], 'authenticated', ARRAY['EXECUTE'],
    'create_minigame_session is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'create_minigame_session',
    ARRAY['uuid', 'text', 'uuid[]', 'text', 'integer', 'integer', 'text', 'boolean', 'integer', 'timestamp with time zone']::name[], 'anon', ARRAY[]::name[],
    'create_minigame_session is not anon-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%minigame.free_max_players%'
       AND pg_get_functiondef(p.oid) LIKE '%minigame.pro_max_players%'
       AND pg_get_functiondef(p.oid) LIKE '%minigame.vip_max_players%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session computes the player cap from the creator subscription tier via app_config'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''player_limit_reached''%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session rejects over-cap rosters with player_limit_reached'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%player_limit%'
       AND pg_get_functiondef(p.oid) LIKE '%INSERT INTO public.minigame_sessions%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session stores the frozen player_limit on the session row'
);

-- ============================================================
-- SECTION 46: Static trigger/constraint/RPC contract (agent I-77,
-- I-76 handoff + I-31/I-32/I-57 regression net)
--   46a. Trigger→function bindings (trigger_is) — existence is asserted in
--        Section 8; the binding guards against a trigger pointing at the
--        wrong function after a CREATE OR REPLACE.
--   46b. Trigger-function BODY contract — update_group_size_tier maps
--        member_count to size_tier thresholds.
--   46c. Constraint contract — group_members_status_check (name-anchored
--        pg_constraint check) and the UNIQUE (group_id, user_id) key.
--   46e. RPC completeness: is_group_member helper existence + SECURITY
--        DEFINER + STABLE + search_path hardening (used by
--        create_minigame_session and group_members_read_same).
-- ============================================================

-- 46a: trigger → function bindings
SELECT trigger_is('public', 'users', 'users_updated_at', 'extensions', 'moddatetime',
    'users_updated_at fires extensions.moddatetime');
SELECT trigger_is('public', 'groups', 'groups_updated_at', 'extensions', 'moddatetime',
    'groups_updated_at fires extensions.moddatetime');
SELECT trigger_is('public', 'group_members', 'group_size_tier_trigger', 'public', 'update_group_size_tier',
    'group_size_tier_trigger fires update_group_size_tier');
-- 46b: trigger-function bodies (static behavioral contract)
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%UPDATE public.groups SET size_tier = CASE%'
       AND pg_get_functiondef(p.oid) LIKE '%member_count >= 257%'
       AND pg_get_functiondef(p.oid) LIKE '%member_count >= 15%'
     FROM pg_proc p WHERE proname = 'update_group_size_tier'),
    'update_group_size_tier maps member_count to size_tier thresholds (large 257+ / small 15+)'
);
-- 46c: constraints
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'group_members'::regclass
          AND conname = 'group_members_status_check'
          AND contype = 'c'
    ),
    'group_members has group_members_status_check (status IN active/invited, migration 20260512000011)'
);
SELECT col_is_unique('group_members', ARRAY['group_id', 'user_id'],
    'group_members has UNIQUE (group_id, user_id)');
-- 46e: RPC completeness
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
--   47b. Kept bucket rows exist with the exact public flags: avatars=true,
--        groups=true (public reads via getPublicUrl), minigame_images=false
--        (private encrypted-image store, signed-URL retrieval only). The
--        events bucket row is retained but belongs to a removed feature.
--   47c. storage.objects RLS is enabled (relrowsecurity) and the six kept
--        policies are present under their exact names.
-- ============================================================

-- 47a: storage schema tables
SELECT has_table('storage', 'buckets',
    'storage.buckets exists (storage-api tenant schema, asserted by M-08)');
SELECT has_table('storage', 'objects',
    'storage.objects exists (storage-api tenant schema, asserted by M-08)');

-- 47b: bucket rows + public flags (migration 20260810000007 §1)
SELECT results_eq(
    'SELECT id FROM storage.buckets WHERE id IN (''avatars'', ''groups'', ''minigame_images'') ORDER BY id',
    ARRAY['avatars', 'groups', 'minigame_images']::text[],
    'kept bucket rows exist — avatars, groups and minigame_images (migration 20260810000007)'
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
    NOT (SELECT public FROM storage.buckets WHERE id = 'minigame_images'),
    'minigame_images bucket is private (public=false, signed-URL retrieval only)'
);

-- 47c: objects RLS enabled + exact policy set
SELECT ok(
    (SELECT relrowsecurity FROM pg_catalog.pg_class
     WHERE oid = 'storage.objects'::regclass),
    'storage.objects has ROW LEVEL SECURITY enabled (storage-api 0002)'
);
SELECT ok(
    (SELECT count(*) = 6
       FROM pg_policies
      WHERE schemaname = 'storage' AND tablename = 'objects'
        AND policyname IN ('storage_objects_delete_own',
                           'storage_objects_insert_own',
                           'storage_objects_update_own',
                           'storage_objects_public_read_avatars_groups',
                           'storage_objects_minigame_images_select',
                           'storage_objects_minigame_images_insert')),
    'storage.objects carries the 6 kept policies (own insert/update/delete, public read avatars/groups, minigame-images select/insert)'
);

-- ============================================================
-- SECTION 48: Function EXECUTE hardening (20260811000001)
-- The supabase image's default privileges granted anon EXECUTE on every
-- function created by postgres/supabase_admin in public; prior per-function
-- REVOKE ... FROM PUBLIC only removed the PUBLIC entry. Section asserts the
-- hardened posture (anon excluded everywhere except the four intended cases).
-- ============================================================

SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prosecdef
       AND has_function_privilege('anon', p.oid, 'EXECUTE')
       AND p.proname NOT IN ('check_signup_email', 'is_group_member', 'is_chat_participant', 'upsert_signup_tracker')) = 0,
    'anon cannot EXECUTE any SECURITY DEFINER function (except check_signup_email + is_group_member + is_chat_participant + upsert_signup_tracker)'
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
       AND p.proname IN ('create_minigame_session', 'join_minigame_session',
                         'join_minigame_by_code', 'get_minigame_game_state',
                         'leave_minigame_session', 'abandon_minigame_game')
       AND has_function_privilege('authenticated', p.oid, 'EXECUTE')) = 6,
    'authenticated can EXECUTE the 6 kept minigame client RPCs (finish is server-only)'
);

SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('hard_delete_expired_users', 'admin_grant_subscription',
                         'admin_revoke_subscription', 'purge_expired_retention',
                         'retry_auth_cleanup', 'moderate_report',
                         'decide_appeal', 'claim_report')
       AND has_function_privilege('service_role', p.oid, 'EXECUTE')) = 8,
    'service_role can EXECUTE the 8 kept admin/CLI RPCs'
);

SELECT ok(
    has_function_privilege('anon', 'public.check_signup_email(text)', 'EXECUTE'),
    'check_signup_email remains anon-callable (pre-auth email check, by design)'
);

SELECT ok(
    has_function_privilege('anon', 'public.is_group_member(uuid)', 'EXECUTE'),
    'is_group_member remains anon-callable (invoked from RLS policies)'
);

-- ============================================================
-- SECTION 49: join/settlement minigame RPCs (migration 20260813000001,
-- agent R4; wager-free after 300_slim/03_remove_wagers):
-- join_minigame_session (session-exists + is_group_member gate, idempotent
-- participants append, NO escrow) and the finish_minigame_game settlement
-- that replaced finish_minigame_session. Both are SECURITY DEFINER +
-- SET search_path = '' (I-31 pattern), jsonb status outcomes (I-57
-- contract), PUBLIC EXECUTE revoked, client RPCs authenticated-only.
-- ============================================================

-- 49a: join_minigame_session(uuid)
SELECT has_function('join_minigame_session', ARRAY['uuid'],
    'join_minigame_session(p_session_id uuid) exists (migration 20260813000001)');
SELECT ok(
    (SELECT prosecdef FROM pg_proc WHERE proname = 'join_minigame_session'),
    'join_minigame_session is SECURITY DEFINER'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'join_minigame_session'),
    'join_minigame_session sets search_path = '''' (migration 20260813000001)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.is_group_member(v_group_id)%'
     FROM pg_proc p WHERE proname = 'join_minigame_session'),
    'join_minigame_session validates membership via is_group_member'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%participants || ARRAY[v_current_user]%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%minigame_wager%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%public.shard_ledger%'
     FROM pg_proc p WHERE proname = 'join_minigame_session'),
    'join_minigame_session appends the participant with no wager/ledger write (wagers removed)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.minigame_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%''not_allowed''%'
     FROM pg_proc p WHERE proname = 'join_minigame_session'),
    'join_minigame_session gates DIRECT sessions by participant / pending-invite standing (not_allowed)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%array_length(v_participants, 1) >= v_player_limit%'
       AND pg_get_functiondef(p.oid) LIKE '%''player_limit_reached''%'
     FROM pg_proc p WHERE proname = 'join_minigame_session'),
    'join_minigame_session enforces the frozen player cap (player_limit_reached)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''joined''%'
       AND pg_get_functiondef(p.oid) LIKE '%''session_not_found''%'
       AND pg_get_functiondef(p.oid) LIKE '%''session_not_active''%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%''insufficient_shards''%'
     FROM pg_proc p WHERE proname = 'join_minigame_session'),
    'join_minigame_session returns typed jsonb statuses (no insufficient_shards)'
);
SELECT function_privs_are('public', 'join_minigame_session', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'join_minigame_session is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'join_minigame_session', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'join_minigame_session is authenticated-EXECUTABLE');

-- 49b: finish_minigame_session is REPLACED by finish_minigame_game
-- (201_minigame_voting) — the winner-takes-all + draw settlement seams are
-- dropped; the leaderboard settlement is the one and only path.
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'finish_minigame_session'),
    'finish_minigame_session is dropped (201_minigame_voting replaces it with finish_minigame_game)'
);

-- ============================================================
-- SECTION 49b: Minigame invites (migration 140_minigame_invites,
-- 2026-08-26) — participant select. minigame_invites table (FORCE RLS,
-- invitee+creator read), users.minigame_invite_friends_only privacy switch
-- (default OFF), the RPC family (set_*/accept/decline: SECURITY DEFINER +
-- empty search_path + PUBLIC-revoked + authenticated-EXECUTABLE), the
-- ms_read_invitee session-read policy, and the realtime memberships that
-- deliver invites live to the invitee's notification center.
-- ============================================================
SELECT has_type('mini_game_invite_status',
    'mini_game_invite_status exists (140_minigame_invites)');
SELECT has_table('minigame_invites',
    'minigame_invites exists');
SELECT col_is_unique('minigame_invites', ARRAY['session_id', 'invitee_id'],
    'minigame_invites(session_id, invitee_id) is unique (one invite per player per session)');
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.minigame_invites'::regclass),
    'minigame_invites has RLS ENABLED (140_minigame_invites)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.minigame_invites'::regclass),
    'minigame_invites has FORCE ROW LEVEL SECURITY (140_minigame_invites)'
);
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_class
        WHERE relnamespace = 'public'::regnamespace
          AND relkind = 'r'
          AND relforcerowsecurity
          AND NOT relrowsecurity
    ),
    'every public table with FORCE RLS also has RLS ENABLED (no inert-policy leak)'
);
SELECT policies_are('minigame_invites', ARRAY[
    'mi_read_own',
    'active_users_only'
], 'minigame_invites policies: invitee/creator SELECT only (every write is an RPC contract)');
SELECT has_column('users', 'minigame_invite_friends_only',
    'users.minigame_invite_friends_only exists (invite privacy switch, 140_minigame_invites)');
SELECT ok(
    (SELECT pg_get_expr(adbin, adrelid)::text = 'false'
     FROM pg_attrdef d
     JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE a.attrelid = 'users'::regclass AND a.attname = 'minigame_invite_friends_only'),
    'users.minigame_invite_friends_only defaults to false (non-friends may invite by default)'
);
SELECT has_function('set_minigame_invite_friends_only', ARRAY['boolean'],
    'set_minigame_invite_friends_only(p_value boolean) exists (profile-RPC lockdown)');
SELECT is_definer('public', 'set_minigame_invite_friends_only', ARRAY['boolean']::name[],
    'set_minigame_invite_friends_only is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'set_minigame_invite_friends_only'),
    'set_minigame_invite_friends_only sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'set_minigame_invite_friends_only', ARRAY['boolean']::name[], 'public', ARRAY[]::name[],
    'set_minigame_invite_friends_only is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'set_minigame_invite_friends_only', ARRAY['boolean']::name[], 'authenticated', ARRAY['EXECUTE'],
    'set_minigame_invite_friends_only is authenticated-EXECUTABLE');
SELECT has_function('accept_minigame_invite', ARRAY['uuid'],
    'accept_minigame_invite(p_invite_id uuid) exists');
SELECT is_definer('public', 'accept_minigame_invite', ARRAY['uuid']::name[],
    'accept_minigame_invite is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'accept_minigame_invite'),
    'accept_minigame_invite sets search_path = "" (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''session_finished''%'
       AND pg_get_functiondef(p.oid) LIKE '%participants || ARRAY[v_current_user]%'
     FROM pg_proc p WHERE proname = 'accept_minigame_invite'),
    'accept_minigame_invite rejects finished sessions and appends the participant'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) NOT LIKE '%minigame_wager%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%public.shard_ledger%'
     FROM pg_proc p WHERE proname = 'accept_minigame_invite'),
    'accept_minigame_invite writes no wager/escrow (wagers removed)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%array_length(v_participants, 1) >= v_player_limit%'
       AND pg_get_functiondef(p.oid) LIKE '%''player_limit_reached''%'
     FROM pg_proc p WHERE proname = 'accept_minigame_invite'),
    'accept_minigame_invite enforces the frozen player cap (player_limit_reached)'
);
SELECT function_privs_are('public', 'accept_minigame_invite', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'accept_minigame_invite is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'accept_minigame_invite', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'accept_minigame_invite is authenticated-EXECUTABLE');
SELECT has_function('decline_minigame_invite', ARRAY['uuid'],
    'decline_minigame_invite(p_invite_id uuid) exists');
SELECT is_definer('public', 'decline_minigame_invite', ARRAY['uuid']::name[],
    'decline_minigame_invite is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'decline_minigame_invite'),
    'decline_minigame_invite sets search_path = "" (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%DELETE FROM public.minigame_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%invitee_id = v_current_user%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%status = ''''declined''''%'
     FROM pg_proc p WHERE proname = 'decline_minigame_invite'),
    'decline_minigame_invite DELETEs the row (a declined invite is indistinguishable from one that never existed — 2026-09-02 user directive)'
);
SELECT function_privs_are('public', 'decline_minigame_invite', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'decline_minigame_invite is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'decline_minigame_invite', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'decline_minigame_invite is authenticated-EXECUTABLE');
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'notifications'
    ),
    'notifications joins the supabase_realtime publication (GO-realtime invites land live)'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'minigame_invites'
    ),
    'minigame_invites joins the supabase_realtime publication (accept/decline streaming)'
);

-- ============================================================
-- SECTION 49c: Minigame game state (migration 150_minigame_play) —
-- the reusable play engine for all game types. Two tables + five RPCs:
--   * minigame_game_state — one row per minigame session (state jsonb:
--     judge_index/round/phase + game-specific keys, rounds jsonb[]
--     append-only history, updated_at touch trigger), FORCE RLS with the
--     single mgs_read_participant SELECT (session-row-visible check).
--   * minigame_prompts — the generic prompt bank (game_type +
--     prompt_type + category + body + pack_id), FORCE RLS with NO client
--     policy: prompt bodies are served only through SECURITY DEFINER RPCs
--     (mgs_prompts_select dropped by 300_slim/02_prompt_packs.sql).
--   * get/init/reveal/advance RPCs: SECURITY DEFINER +
--     SET search_path = '' (I-31 pattern), typed jsonb statuses (I-57
--     contract), auth gate first, participant-only gates, PUBLIC EXECUTE
--     revoked + authenticated (+service_role for settle) grants.
--   * minigame_game_state joins supabase_realtime (game state streams live).
-- ============================================================

-- 49c-a: minigame_game_state table shape
SELECT has_table('minigame_game_state',
    'minigame_game_state exists (150_minigame_play)');
SELECT has_table('minigame_prompts',
    'minigame_prompts exists (150_minigame_play)');
SELECT col_is_pk('minigame_game_state', 'session_id',
    'minigame_game_state.session_id is the primary key');
SELECT col_type_is('minigame_game_state', 'session_id', 'uuid',
    'minigame_game_state.session_id is uuid');
SELECT col_type_is('minigame_game_state', 'game_type', 'public.mini_game_type',
    'minigame_game_state.game_type is the mini_game_type enum (denormalized convenience)');
SELECT col_type_is('minigame_game_state', 'state', 'jsonb',
    'minigame_game_state.state is jsonb (game-agnostic play state)');
SELECT col_type_is('minigame_game_state', 'rounds', 'jsonb[]',
    'minigame_game_state.rounds is jsonb[] (append-only round history)');
SELECT col_type_is('minigame_game_state', 'created_at', 'timestamp with time zone',
    'minigame_game_state.created_at is timestamptz');
SELECT col_type_is('minigame_game_state', 'updated_at', 'timestamp with time zone',
    'minigame_game_state.updated_at is timestamptz');
SELECT col_not_null('minigame_game_state', 'session_id',
    'minigame_game_state.session_id is NOT NULL');
SELECT col_not_null('minigame_game_state', 'game_type',
    'minigame_game_state.game_type is NOT NULL');
SELECT col_not_null('minigame_game_state', 'state',
    'minigame_game_state.state is NOT NULL');
SELECT col_not_null('minigame_game_state', 'rounds',
    'minigame_game_state.rounds is NOT NULL');
SELECT col_has_default('minigame_game_state', 'state',
    'minigame_game_state.state defaults to an empty jsonb object');
SELECT col_has_default('minigame_game_state', 'rounds',
    'minigame_game_state.rounds defaults to the empty array');
SELECT fk_ok('minigame_game_state', ARRAY['session_id'::name], 'minigame_sessions', ARRAY['id'::name],
    'minigame_game_state.session_id cascades from minigame_sessions.id (ON DELETE CASCADE)');
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.minigame_game_state'::regclass),
    'minigame_game_state has RLS enabled (150_minigame_play)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.minigame_game_state'::regclass),
    'minigame_game_state has FORCE ROW LEVEL SECURITY (150_minigame_play)'
);
SELECT policies_are('minigame_game_state', ARRAY[
    'mgs_read_participant',
    'active_users_only'
], 'minigame_game_state policies: participant/invitee/group-member SELECT only (every write is an RPC contract)');
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'minigame_game_state'
          AND policyname = 'mgs_read_participant'
          AND cmd = 'SELECT'
          AND qual LIKE '%minigame_sessions%'
          AND qual LIKE '%minigame_invites%'
    ),
    'mgs_read_participant reads the session row exactly when participant/invitee/group-member does (EXISTS over minigame_sessions + minigame_invites)'
);
SELECT has_trigger('minigame_game_state', 'minigame_game_state_touch',
    'minigame_game_state has the updated_at touch trigger');
SELECT is_definer('public', 'minigame_game_state_touch', ARRAY[]::name[],
    'minigame_game_state_touch is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'minigame_game_state_touch'),
    'minigame_game_state_touch sets search_path = '''' (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%NEW.updated_at := now()%'
       AND pg_get_functiondef(p.oid) LIKE '%NEW.updated_at%'
     FROM pg_proc p WHERE proname = 'minigame_game_state_touch'),
    'minigame_game_state_touch stamps updated_at = now() on UPDATE'
);

-- 49c-b: minigame_prompts shape + seed
SELECT col_type_is('minigame_prompts', 'id', 'uuid',
    'minigame_prompts.id is uuid');
SELECT col_type_is('minigame_prompts', 'game_type', 'public.mini_game_type',
    'minigame_prompts.game_type is the mini_game_type enum');
SELECT col_type_is('minigame_prompts', 'prompt_type', 'text',
    'minigame_prompts.prompt_type is text (verdad/reto, quick/challenge, ...)');
SELECT col_type_is('minigame_prompts', 'category', 'text',
    'minigame_prompts.category is text (amor/foto/reto/general)');
SELECT col_type_is('minigame_prompts', 'body', 'text',
    'minigame_prompts.body is text (the prompt text)');
SELECT col_not_null('minigame_prompts', 'game_type',
    'minigame_prompts.game_type is NOT NULL');
SELECT col_not_null('minigame_prompts', 'prompt_type',
    'minigame_prompts.prompt_type is NOT NULL');
SELECT col_not_null('minigame_prompts', 'category',
    'minigame_prompts.category is NOT NULL');
SELECT col_not_null('minigame_prompts', 'body',
    'minigame_prompts.body is NOT NULL');
SELECT col_not_null('minigame_prompts', 'is_active',
    'minigame_prompts.is_active is NOT NULL');
SELECT col_has_default('minigame_prompts', 'category',
    'minigame_prompts.category defaults to general');
SELECT col_has_default('minigame_prompts', 'is_active',
    'minigame_prompts.is_active defaults true');
SELECT ok(
    (SELECT count(*) = 0 FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'minigame_prompts'),
    'minigame_prompts has no client RLS policies — prompt bodies are RPC-only (mgs_prompts_select dropped)'
);
SELECT ok(
    (SELECT count(*) >= 8 FROM public.minigame_prompts WHERE game_type = 'truth_dare'),
    'truth_dare prompt bank is seeded with at least 8 prompts (150_minigame_play seed)'
);
SELECT ok(
    EXISTS (SELECT 1 FROM public.minigame_prompts
            WHERE game_type = 'truth_dare' AND prompt_type = 'verdad'
              AND category = 'amor' AND body = '¿Cuál fue tu primer beso?'),
    'seed: "¿Cuál fue tu primer beso?" (verdad/amor) is present'
);
SELECT ok(
    EXISTS (SELECT 1 FROM public.minigame_prompts
            WHERE game_type = 'truth_dare' AND prompt_type = 'verdad'
              AND category = 'amor' AND body = '¿Quién fue tu primer amor?'),
    'seed: "¿Quién fue tu primer amor?" (verdad/amor) is present'
);
SELECT ok(
    EXISTS (SELECT 1 FROM public.minigame_prompts
            WHERE game_type = 'truth_dare' AND prompt_type = 'verdad'
              AND body = 'Di la inicial de quien te gusta'),
    'seed: "Di la inicial de quien te gusta" (verdad) is present'
);
SELECT ok(
    EXISTS (SELECT 1 FROM public.minigame_prompts
            WHERE game_type = 'truth_dare' AND prompt_type = 'reto'
              AND body = 'Envía una foto de tu perro'),
    'seed: "Envía una foto de tu perro" (reto) is present'
);
SELECT ok(
    EXISTS (SELECT 1 FROM public.minigame_prompts
            WHERE game_type = 'truth_dare' AND prompt_type = 'reto'
              AND body = 'Hazte una selfie con un objeto'),
    'seed: "Hazte una selfie con un objeto" (reto) is present'
);
SELECT ok(
    EXISTS (SELECT 1 FROM public.minigame_prompts
            WHERE game_type = 'truth_dare' AND prompt_type = 'reto'
              AND body = 'Haz un challenge'),
    'seed: "Haz un challenge" (reto) is present'
);

-- 49c-c: the 5 RPCs — signature + hardening
SELECT has_function('get_minigame_game_state', ARRAY['uuid'],
    'get_minigame_game_state(p_session_id uuid) exists (150_minigame_play)');
SELECT is_definer('public', 'get_minigame_game_state', ARRAY['uuid'],
    'get_minigame_game_state is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'get_minigame_game_state'),
    'get_minigame_game_state sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'get_minigame_game_state', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'get_minigame_game_state is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'get_minigame_game_state', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'get_minigame_game_state is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''not_started''%'
       AND pg_get_functiondef(p.oid) LIKE '%''ok''%'
       AND pg_get_functiondef(p.oid) LIKE '%''session_not_found''%'
       AND pg_get_functiondef(p.oid) LIKE '%''not_allowed''%'
     FROM pg_proc p WHERE proname = 'get_minigame_game_state'),
    'get_minigame_game_state returns typed jsonb statuses (I-57 contract)'
);

SELECT has_function('init_minigame_game_state', ARRAY['uuid'],
    'init_minigame_game_state(p_session_id uuid) exists (150_minigame_play)');
SELECT is_definer('public', 'init_minigame_game_state', ARRAY['uuid'],
    'init_minigame_game_state is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'init_minigame_game_state'),
    'init_minigame_game_state sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'init_minigame_game_state', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'init_minigame_game_state is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'init_minigame_game_state', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'init_minigame_game_state is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''already_started''%'
       AND pg_get_functiondef(p.oid) LIKE '%''started''%'
       AND pg_get_functiondef(p.oid) LIKE '%''session_not_active''%'
       AND pg_get_functiondef(p.oid) LIKE '%random()%'
     FROM pg_proc p WHERE proname = 'init_minigame_game_state'),
    'init_minigame_game_state is idempotent (already_started), active-only, and picks the subject RANDOMLY (server-random)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%jsonb_build_object(%'
       AND pg_get_functiondef(p.oid) LIKE '%judge_index%'
       AND pg_get_functiondef(p.oid) LIKE '%phase%'
       AND pg_get_functiondef(p.oid) LIKE '%subject_id%'
     FROM pg_proc p WHERE proname = 'init_minigame_game_state'),
    'init_minigame_game_state seeds judge_index/round/phase and writes subject_id into the payload'
);

SELECT has_function('reveal_minigame_prompt', ARRAY['uuid', 'text'],
    'reveal_minigame_prompt(p_session_id uuid, p_prompt_type text) exists (150_minigame_play)');
SELECT is_definer('public', 'reveal_minigame_prompt', ARRAY['uuid', 'text'],
    'reveal_minigame_prompt is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'reveal_minigame_prompt'),
    'reveal_minigame_prompt sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'reveal_minigame_prompt', ARRAY['uuid', 'text']::name[], 'public', ARRAY[]::name[],
    'reveal_minigame_prompt is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'reveal_minigame_prompt', ARRAY['uuid', 'text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'reveal_minigame_prompt is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''invalid_prompt_type''%'
       AND pg_get_functiondef(p.oid) LIKE '%''revealed''%'
       AND pg_get_functiondef(p.oid) LIKE '%public.minigame_prompts%'
       AND pg_get_functiondef(p.oid) LIKE '%ORDER BY random()%'
       AND pg_get_functiondef(p.oid) LIKE '%LIMIT 1%'
     FROM pg_proc p WHERE proname = 'reveal_minigame_prompt'),
    'reveal_minigame_prompt validates prompt_type, draws a random active prompt (ORDER BY random() LIMIT 1), and reveals'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''prompt_type''%'
       AND pg_get_functiondef(p.oid) LIKE '%''prompt''%'
       AND pg_get_functiondef(p.oid) LIKE '%state || jsonb_build_object%'
     FROM pg_proc p WHERE proname = 'reveal_minigame_prompt'),
    'reveal_minigame_prompt persists prompt_type + prompt into the state payload'
);

SELECT has_function('advance_minigame_turn', ARRAY['uuid', 'jsonb'],
    'advance_minigame_turn(p_session_id uuid, p_round jsonb) exists (150_minigame_play)');
SELECT is_definer('public', 'advance_minigame_turn', ARRAY['uuid', 'jsonb'],
    'advance_minigame_turn is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'advance_minigame_turn'),
    'advance_minigame_turn sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'advance_minigame_turn', ARRAY['uuid', 'jsonb']::name[], 'public', ARRAY[]::name[],
    'advance_minigame_turn is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'advance_minigame_turn', ARRAY['uuid', 'jsonb']::name[], 'authenticated', ARRAY['EXECUTE'],
    'advance_minigame_turn is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%rounds || ARRAY[%'
        AND pg_get_functiondef(p.oid) LIKE '%random()%'
        AND pg_get_functiondef(p.oid) LIKE '%participants%'
        AND pg_get_functiondef(p.oid) LIKE '%judge_index%'
        AND pg_get_functiondef(p.oid) LIKE '%subject_id%'
      FROM pg_proc p WHERE proname = '_minigame_advance_round'),
    '_minigame_advance_round appends the round, rotates the judge round-robin, and picks a RANDOM next subject (202)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%rounds || ARRAY[%'
        AND pg_get_functiondef(p.oid) LIKE '%prompt_type%'
        AND pg_get_functiondef(p.oid) LIKE '%''phase''%'
        AND pg_get_functiondef(p.oid) LIKE '%v_round + 1%'
       FROM pg_proc p WHERE proname = '_minigame_advance_round'),
    '_minigame_advance_round bumps the round, clears prompt_type/prompt, and keeps phase=playing (202)'
);

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'complete_minigame_game'),
    'complete_minigame_game is dropped (201_minigame_voting replaces it with finish_minigame_game)'
);

-- 49c-d: realtime publication membership
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'minigame_game_state'
    ),
    'minigame_game_state joins the supabase_realtime publication (game state streams live to participants)'
);

-- 49c-e: authenticated client-RPC inventory extends to the play RPCs
SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('get_minigame_game_state', 'init_minigame_game_state',
                         'reveal_minigame_prompt', 'advance_minigame_turn',
                         'submit_minigame_reaction', 'abandon_minigame_game')
       AND has_function_privilege('authenticated', p.oid, 'EXECUTE')) = 6,
    'authenticated can EXECUTE the 6 play-engine RPCs (finish is server-only)'
);
SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prosecdef
       AND has_function_privilege('anon', p.oid, 'EXECUTE')
       AND p.proname NOT IN ('check_signup_email', 'is_group_member', 'is_chat_participant', 'upsert_signup_tracker')) = 0,
    'anon cannot EXECUTE any SECURITY DEFINER function (play RPCs included)'
);

-- ============================================================
-- SECTION 51: Blocked-user view exclusion + assert_safe_group_update
-- (migration 20260814000002) — user_search_view hides blocked pairs and the
-- group-update gate is refreshed.
-- ============================================================
SELECT ok(
    (SELECT pg_get_viewdef('user_search_view') LIKE '%blocked%'),
    'user_search_view excludes blocked friendships (20260814000002)'
);
SELECT has_function('public', 'assert_safe_group_update', ARRAY[]::name[],
    'assert_safe_group_update exists (refreshed by 20260814000002)');
SELECT ok(
    (SELECT 'search_path=""' = ANY(proconfig) FROM pg_proc WHERE proname = 'assert_safe_group_update'),
    'assert_safe_group_update sets search_path = '''' (I-31 pattern)'
);

-- ============================================================
-- SECTION 52: notifications producer helper (migration 20260814000003)
-- ============================================================
SELECT has_function('insert_notification',
    ARRAY['uuid', 'text', 'text', 'text', 'jsonb'],
    'insert_notification(p_user_id, p_type, p_title, p_body, p_data) exists');
SELECT is((SELECT prosecdef FROM pg_proc WHERE proname = 'insert_notification'),
    true, 'insert_notification is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY(proconfig) FROM pg_proc WHERE proname = 'insert_notification'),
    'insert_notification sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'insert_notification',
    ARRAY['uuid', 'text', 'text', 'text', 'jsonb']::name[], 'anon', ARRAY[]::name[],
    'anon has NO EXECUTE on insert_notification');
SELECT function_privs_are('public', 'insert_notification',
    ARRAY['uuid', 'text', 'text', 'text', 'jsonb']::name[], 'authenticated', ARRAY[]::name[],
    'authenticated has NO EXECUTE on insert_notification (trigger/CLI only)');

-- ============================================================
-- SECTION 54: Notification producer triggers (migration 20260814000005)
-- Kept features only: friend requests, minigame invites, feature requests.
-- (The event/message producers stay attached to their retained tables, but
-- those features are removed and no client can reach them.)
-- ============================================================
SELECT has_function('notify_friend_request', ARRAY[]::name[],
    'notify_friend_request exists (NTRG #2)');
SELECT has_trigger('friendships', 'notify_friend_request_trigger',
    'friendships has notify_friend_request_trigger');
SELECT has_function('notify_minigame_invite', ARRAY[]::name[],
    'notify_minigame_invite exists (NTRG #7)');
SELECT has_trigger('minigame_invites', 'notify_minigame_invite_trigger',
    'minigame_invites has notify_minigame_invite_trigger (140_minigame_invites — notifies the INVITEE, not the creator)');
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'notify_minigame_invite_trigger'
          AND tgrelid = 'public.minigame_sessions'::regclass
    ),
    'notify_minigame_invite_trigger no longer fires on minigame_sessions INSERT (moved to minigame_invites)'
);
SELECT has_function('notify_feature_request', ARRAY[]::name[],
    'notify_feature_request exists (NTRG #8)');
SELECT has_trigger('feature_requests', 'notify_feature_request_trigger',
    'feature_requests has notify_feature_request_trigger');

-- ============================================================
-- SECTION 54b: Device tokens + push bookkeeping (migration 223_device_tokens)
-- ============================================================
SELECT has_table('public', 'device_tokens', 'device_tokens exists (223)');
SELECT has_column('public', 'notifications', 'push_sent_at',
    'notifications.push_sent_at exists (223)');
SELECT has_function('public', 'register_device_token', ARRAY['text', 'text']::name[],
    'register_device_token(text, text) exists (223)');
SELECT is_definer('public', 'register_device_token', ARRAY['text', 'text']::name[],
    'register_device_token is SECURITY DEFINER');
SELECT function_privs_are('public', 'register_device_token',
    ARRAY['text', 'text']::name[], 'anon', ARRAY[]::name[],
    'anon has NO EXECUTE on register_device_token');
SELECT function_privs_are('public', 'register_device_token',
    ARRAY['text', 'text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'authenticated can EXECUTE register_device_token');
SELECT has_function('public', 'unregister_device_token', ARRAY['text']::name[],
    'unregister_device_token(text) exists (223)');
SELECT function_privs_are('public', 'unregister_device_token',
    ARRAY['text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'authenticated can EXECUTE unregister_device_token');
SELECT has_function('notify_minigame_turn', ARRAY[]::name[],
    'notify_minigame_turn exists (224 — generic minigame turn)');
SELECT has_trigger('minigame_game_state', 'notify_minigame_turn_trigger',
    'minigame_game_state has notify_minigame_turn_trigger (224)');

-- ============================================================
-- SECTION 55: Group chain of command (migration 20260816000001)
-- ============================================================
SELECT has_function('public', 'transfer_host', ARRAY['uuid', 'uuid']::name[],
    'transfer_host exists (OPT-009 — atomic host handover)');
SELECT is_definer('public', 'transfer_host', ARRAY['uuid', 'uuid']::name[],
    'transfer_host is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'transfer_host'),
    'transfer_host sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'transfer_host', ARRAY['uuid', 'uuid']::name[], 'public', ARRAY[]::name[],
    'transfer_host is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'transfer_host', ARRAY['uuid', 'uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'transfer_host is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%staff%'
       AND pg_get_functiondef(p.oid) LIKE '%not_host%'
       AND pg_get_functiondef(p.oid) LIKE '%role = ''host''%'
     FROM pg_proc p WHERE proname = 'transfer_host'),
    'transfer_host is host-only and demotes self + promotes successor'
);
SELECT has_function('public', 'promote_next_member', ARRAY['uuid']::name[],
    'promote_next_member exists (OPT-009 — successor pick)');
SELECT is_definer('public', 'promote_next_member', ARRAY['uuid']::name[],
    'promote_next_member is SECURITY DEFINER');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%role = ''staff''%'
       AND pg_get_functiondef(p.oid) LIKE '%random()%'
       AND pg_get_functiondef(p.oid) LIKE '%status = ''active''%'
     FROM pg_proc p WHERE proname = 'promote_next_member'),
    'promote_next_member prefers staff, random pick, active-only'
);
SELECT has_function('public', 'reassign_group_host', ARRAY[]::name[],
    'reassign_group_host exists (OPT-009 — ban/delete leadership pass)');
SELECT is_definer('public', 'reassign_group_host', ARRAY[]::name[],
    'reassign_group_host is SECURITY DEFINER');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%banned_at%'
       AND pg_get_functiondef(p.oid) LIKE '%deleted_at%'
       AND pg_get_functiondef(p.oid) LIKE '%promote_next_member%'
     FROM pg_proc p WHERE proname = 'reassign_group_host'),
    'reassign_group_host demotes banned/deleted hosts and passes leadership'
);
SELECT has_trigger('group_members', 'reassign_group_host_delete_trigger',
    'group_members has the host-reassignment delete trigger');
SELECT has_trigger('users', 'reassign_group_host_user_trigger',
    'users has the host-reassignment ban/delete trigger');

-- ============================================================
-- SECTION 56: group realtime + friend-request acceptance
--   56a. 20260817000001 — group_members realtime (publication + REPLICA
--        IDENTITY FULL) drives the live member roster.
--   56d. 20260817000004 — accept_friend_request RPC (addressee-only,
--        pending-only, authenticated-only) belongs to the kept friends
--        feature; the chat-side parts of these migrations are removed.
-- ============================================================

-- 56a: group_members realtime (20260817000001)
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'group_members'
    ),
    'group_members is in the supabase_realtime publication (20260817000001)'
);
SELECT is(
    (SELECT relreplident FROM pg_class WHERE oid = 'public.group_members'::regclass),
    'f',
    'group_members has REPLICA IDENTITY FULL (realtime full-row delivery, 20260817000001)'
);

-- ============================================================
-- SECTION 60: users profile-RPC lockdown (baseline 020_core/02_users.sql,
-- 2026-08-25 directive: clients may NEVER write the table directly).
--   50a. users_username_shape CHECK (name-anchored) + NFKC clause.
--   50b. Helper functions exist: sanitize_free_text / sanitize_username /
--        assert_username_shape / assert_date_of_birth.
--   50c. The 7 client-facing RPCs (create_my_profile, update_my_profile,
--        delete_my_account, set_avatar_url, set_discovery_opt_in,
--        set_read_receipts_enabled, set_profile_public): SECURITY DEFINER +
--        empty search_path + PUBLIC-revoked + authenticated-EXECUTABLE.
--   50d. Table privilege lockdown: anon/authenticated hold NO INSERT/UPDATE;
--        authenticated keeps SELECT; service_role keeps everything.
--   50e. Behavioral matrix under authenticated-style JWT claims: happy
--        create (defaults + shard_ledger grant), duplicate, username policy
--        raises, DOB rules (required/adult/set-once), bio set/clear/cap,
--        tombstone rename + re-create block, CHECK rejects raw writes even
--        from privileged roles, direct client writes denied (42501).
-- ============================================================

-- 60a: constraint
SELECT ok(
    (SELECT count(*) = 1 FROM pg_constraint
     WHERE conrelid = 'public.users'::regclass
       AND conname = 'users_username_shape'
       AND contype = 'c'),
    'users.users_username_shape CHECK exists (profile-RPC lockdown)'
);
SELECT ok(
    (SELECT pg_get_constraintdef(oid) ~* 'normalize\(.*NFKC'
     FROM pg_constraint
     WHERE conrelid = 'public.users'::regclass
       AND conname = 'users_username_shape'),
    'users_username_shape enforces NFKC stability'
);

-- 60b: helpers
SELECT has_function('sanitize_free_text', ARRAY['text', 'integer'],
    'sanitize_free_text(p_raw, p_max_length) exists');
SELECT has_function('sanitize_username', ARRAY['text'],
    'sanitize_username(p_raw) exists');
SELECT has_function('assert_username_shape', ARRAY['text'],
    'assert_username_shape(p_value) exists');
SELECT has_function('assert_date_of_birth', ARRAY['date'],
    'assert_date_of_birth(p_dob) exists');

-- 60c: the RPC family
SELECT has_function('create_my_profile', ARRAY['text', 'date'],
    'create_my_profile(p_username, p_date_of_birth) exists');
SELECT has_function('update_my_profile', ARRAY['text', 'date'],
    'update_my_profile(p_bio, p_date_of_birth) exists');
SELECT has_function('delete_my_account', ARRAY[]::name[],
    'delete_my_account() exists');
SELECT has_function('set_avatar_url', ARRAY['text'],
    'set_avatar_url(p_avatar_url) exists');
SELECT has_function('set_discovery_opt_in', ARRAY['boolean'],
    'set_discovery_opt_in(p_value) exists');
SELECT has_function('set_read_receipts_enabled', ARRAY['boolean'],
    'set_read_receipts_enabled(p_value) exists');
SELECT has_function('set_profile_public', ARRAY['boolean'],
    'set_profile_public(p_value) exists');

SELECT is_definer('public', 'create_my_profile', ARRAY['text', 'date'],
    'create_my_profile is SECURITY DEFINER');
SELECT is_definer('public', 'update_my_profile', ARRAY['text', 'date'],
    'update_my_profile is SECURITY DEFINER');
SELECT is_definer('public', 'delete_my_account', ARRAY[]::name[],
    'delete_my_account is SECURITY DEFINER');
SELECT is_definer('public', 'set_avatar_url', ARRAY['text'],
    'set_avatar_url is SECURITY DEFINER');
SELECT is_definer('public', 'set_discovery_opt_in', ARRAY['boolean'],
    'set_discovery_opt_in is SECURITY DEFINER');
SELECT is_definer('public', 'set_read_receipts_enabled', ARRAY['boolean'],
    'set_read_receipts_enabled is SECURITY DEFINER');
SELECT is_definer('public', 'set_profile_public', ARRAY['boolean'],
    'set_profile_public is SECURITY DEFINER');

SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'create_my_profile'),
    'create_my_profile sets search_path = empty');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'update_my_profile'),
    'update_my_profile sets search_path = empty');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'delete_my_account'),
    'delete_my_account sets search_path = empty');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'set_avatar_url'),
    'set_avatar_url sets search_path = empty');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'set_discovery_opt_in'),
    'set_discovery_opt_in sets search_path = empty');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'set_read_receipts_enabled'),
    'set_read_receipts_enabled sets search_path = empty');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'set_profile_public'),
    'set_profile_public sets search_path = empty');

SELECT function_privs_are('public', 'create_my_profile', ARRAY['text','date']::name[], 'public', ARRAY[]::name[],
    'create_my_profile is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'update_my_profile', ARRAY['text','date']::name[], 'public', ARRAY[]::name[],
    'update_my_profile is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'delete_my_account', ARRAY[]::name[], 'public', ARRAY[]::name[],
    'delete_my_account is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'set_avatar_url', ARRAY['text']::name[], 'public', ARRAY[]::name[],
    'set_avatar_url is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'set_discovery_opt_in', ARRAY['boolean']::name[], 'public', ARRAY[]::name[],
    'set_discovery_opt_in is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'set_read_receipts_enabled', ARRAY['boolean']::name[], 'public', ARRAY[]::name[],
    'set_read_receipts_enabled is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'set_profile_public', ARRAY['boolean']::name[], 'public', ARRAY[]::name[],
    'set_profile_public is not PUBLIC-EXECUTABLE');

SELECT function_privs_are('public', 'create_my_profile', ARRAY['text','date']::name[], 'authenticated', ARRAY['EXECUTE'],
    'create_my_profile is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'update_my_profile', ARRAY['text','date']::name[], 'authenticated', ARRAY['EXECUTE'],
    'update_my_profile is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'delete_my_account', ARRAY[]::name[], 'authenticated', ARRAY['EXECUTE'],
    'delete_my_account is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'set_avatar_url', ARRAY['text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'set_avatar_url is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'set_discovery_opt_in', ARRAY['boolean']::name[], 'authenticated', ARRAY['EXECUTE'],
    'set_discovery_opt_in is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'set_read_receipts_enabled', ARRAY['boolean']::name[], 'authenticated', ARRAY['EXECUTE'],
    'set_read_receipts_enabled is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'set_profile_public', ARRAY['boolean']::name[], 'authenticated', ARRAY['EXECUTE'],
    'set_profile_public is authenticated-EXECUTABLE');

-- 60d: table privilege lockdown
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.users', 'INSERT')
        AND NOT has_table_privilege('authenticated', 'public.users', 'UPDATE'),
    'authenticated holds NO INSERT/UPDATE on users (RPC-mediated writes only)'
);
SELECT ok(
    NOT has_table_privilege('anon', 'public.users', 'INSERT')
        AND NOT has_table_privilege('anon', 'public.users', 'UPDATE'),
    'anon holds NO INSERT/UPDATE on users'
);
SELECT ok(
    has_table_privilege('authenticated', 'public.users', 'SELECT'),
    'authenticated keeps own-row SELECT (RLS-gated)'
);
SELECT ok(
    has_table_privilege('service_role', 'public.users', 'UPDATE')
        AND has_table_privilege('service_role', 'public.users', 'INSERT'),
    'service_role keeps full access (admin CLI / cron / seeds)'
);

-- 60e: behavioral matrix (JWT-claims style of Sections 37/44)
-- UID family unique to this section.
SELECT set_config('request.jwt.claims',
    '{"sub":"47474747-4747-4747-4747-474747474701","role":"authenticated"}', false);

SELECT lives_ok(
    $$SELECT public.create_my_profile('  Sofia  ', DATE '2000-01-15')$$,
    'create_my_profile happy path sanitizes + inserts'
);
SELECT ok(
    (SELECT username = 'Sofia'
        AND personal_shards >= 0
        AND preshards = 0
        AND subscription_tier = 'free'
        AND bio IS NULL
        AND avatar_url IS NULL
        AND banned_at IS NULL
        AND deleted_at IS NULL
     FROM public.users
     WHERE id = '47474747-4747-4747-4747-474747474701'),
    'created row carries sanitized username + economy defaults'
);
SELECT ok(
    (SELECT l.delta = COALESCE(
        (SELECT value::integer FROM public.app_config WHERE key = 'economy.user_signup_shards'), 0)
        AND l.reason = 'admin_grant'
     FROM public.shard_ledger l
     WHERE l.user_id = '47474747-4747-4747-4747-474747474701'),
    'signup shard_ledger grant written atomically by the RPC'
);
SELECT throws_ok(
    $$SELECT public.create_my_profile('other', DATE '2000-01-15')$$,
    'P0001', 'Tu perfil ya existe.',
    'duplicate profile creation raises'
);
SELECT throws_ok(
    $$SELECT public.create_my_profile('abc', DATE '2000-01-15')$$,
    'P0001', 'Debe tener al menos 5 caracteres.',
    'username below minimum raises the client-parity message'
);
SELECT throws_ok(
    $$SELECT public.create_my_profile(repeat('x', 65), DATE '2000-01-15')$$,
    'P0001', 'El nombre de usuario es demasiado largo.',
    'username above the code-point ceiling raises'
);
SELECT throws_ok(
    $$SELECT public.create_my_profile('validname', DATE '2020-01-01')$$,
    'P0001', 'Debes tener 18 años para usar Samay.',
    'underage date_of_birth raises'
);
SELECT throws_ok(
    $$SELECT public.create_my_profile(NULL, DATE '2000-01-15')$$,
    'P0001', 'El nombre de usuario es obligatorio.',
    'NULL username raises'
);

-- bio: sanitize-on-write, cap at 160 code points, '' clears
SELECT lives_ok(
    $$SELECT public.update_my_profile(E'  Hola \u200B mundo ', NULL)$$,
    'update_my_profile accepts a bio (control chars stripped server-side)'
);
SELECT is(
    (SELECT bio FROM public.users WHERE id = '47474747-4747-4747-4747-474747474701'),
    'Hola  mundo',
    'bio stored control-char-free and trimmed (inner spacing preserved — client parity)'
);
SELECT throws_ok(
    $$SELECT public.update_my_profile(repeat('b', 161), NULL)$$,
    'P0001', 'El texto no puede superar 160 caracteres.',
    'bio above 160 code points raises'
);
SELECT lives_ok(
    $$SELECT public.update_my_profile('', NULL)$$,
    'empty-string bio clears the field'
);
SELECT ok(
    (SELECT bio IS NULL FROM public.users WHERE id = '47474747-4747-4747-4747-474747474701'),
    'cleared bio persists as NULL'
);

-- Q17: DOB is NOT NULL and adult-checked on every write. Legacy rows use the
-- documented sentinel+flag path instead of NULL.
SELECT throws_ok(
    $$UPDATE public.users SET date_of_birth = NULL
      WHERE id = '47474747-4747-4747-4747-474747474701'$$,
    'P0001', 'La fecha de nacimiento es obligatoria.',
    'privileged NULL DOB is rejected by the Q17 trigger'
);
SELECT lives_ok(
    $$UPDATE public.users SET date_of_birth = DATE '1900-01-01',
             date_of_birth_backfilled = true
      WHERE id = '47474747-4747-4747-4747-474747474701'$$,
    'legacy backfill sentinel + flag written (documented validation path)'
);
SELECT lives_ok(
    $$SELECT public.update_my_profile(NULL, DATE '1999-05-05')$$,
    'backfilled account may correct its DOB once through the RPC'
);
SELECT ok(
    (SELECT date_of_birth = DATE '1999-05-05'
        AND date_of_birth_backfilled = false
     FROM public.users WHERE id = '47474747-4747-4747-4747-474747474701'),
    'corrected DOB persisted and the backfill flag cleared'
);
SELECT throws_ok(
    $$UPDATE public.users SET date_of_birth = DATE '2020-01-01'
      WHERE id = '47474747-4747-4747-4747-474747474701'$$,
    'P0001', 'Debes tener 18 años para usar Samay.',
    '18+ trigger rejects an underage raw UPDATE (all roles)'
);
SELECT lives_ok(
    $$SELECT public.update_my_profile(NULL, DATE '1999-05-05')$$,
    'identical DOB re-submission is an allowed no-op (set-once semantics)'
);
SELECT throws_ok(
    $$SELECT public.update_my_profile(NULL, DATE '1999-06-06')$$,
    'P0001', 'La fecha de nacimiento no puede modificarse.',
    'changing an existing DOB raises (age gate stays unfarmable)'
);

-- Q1 delete: immediate hard delete, no tombstone/restore
SELECT lives_ok(
    $$SELECT public.delete_my_account()$$,
    'delete_my_account hard-deletes the own row immediately'
);
SELECT is(
    (SELECT count(*) FROM public.users
      WHERE id = '47474747-4747-4747-4747-474747474701'),
    0::bigint,
    'Q1 hard delete removes the users row (no tombstone)'
);
SELECT lives_ok(
    $$SELECT public.create_my_profile('sofia2', DATE '2000-01-15')$$,
    'Q1: the freed identity can create a fresh profile (no restore row)'
);

-- CHECK constraint fires even for PRIVILEGED raw writers
SELECT throws_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('47474747-4747-4747-4747-474747474702', 'abc', DATE '1990-01-01')$$,
    '23514', 'new row for relation "users" violates check constraint "users_username_shape"',
    'users_username_shape rejects a short RAW write (any role)'
);
SELECT throws_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('47474747-4747-4747-4747-474747474703', 'ｓｏｆｉａ', DATE '1990-01-01')$$,
    '23514', 'new row for relation "users" violates check constraint "users_username_shape"',
    'users_username_shape rejects non-NFKC usernames (any role)'
);
SELECT lives_ok(
    $$INSERT INTO public.users (id, username, date_of_birth, deleted_at) VALUES
        ('47474747-4747-4747-4747-474747474704',
         'deleted_user_' || repeat('y', 70), DATE '1990-01-01', now())$$,
    'tombstone rows are exempt from the username shape CHECK'
);

-- clients cannot bypass the RPCs — the core lockdown pin
SET ROLE authenticated;
SELECT throws_ok(
    $$UPDATE public.users SET bio = 'hacked' WHERE id = auth.uid()$$,
    '42501', 'permission denied for table users',
    'authenticated direct UPDATE is DENIED (no table privilege)'
);
RESET ROLE;
SET ROLE anon;
SELECT throws_ok(
    $$INSERT INTO public.users (id, username) VALUES
        ('47474747-4747-4747-4747-474747474705', 'hacker')$$,
    '42501', 'permission denied for table users',
    'anon direct INSERT is DENIED (no table privilege)'
);
RESET ROLE;

-- setters persist through the scoped RPCs (back on the tombstone? no —
-- setters target the live row; use a second fresh identity)
SELECT set_config('request.jwt.claims',
    '{"sub":"47474747-4747-4747-4747-474747474706","role":"authenticated"}', false);
SELECT lives_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('47474747-4747-4747-4747-474747474706', 'setteruser', DATE '1990-01-01')$$,
    'second fixture inserted (privileged, CHECK-compliant)'
);
SELECT lives_ok($$SELECT public.set_avatar_url('https://cdn.example/a.png')$$,
    'set_avatar_url accepts an https URL');
SELECT throws_ok(
    $$SELECT public.set_avatar_url('http://insecure.example/a.png')$$,
    'P0001', 'La URL del avatar no es válida.',
    'set_avatar_url rejects non-https URLs'
);
SELECT lives_ok($$SELECT public.set_avatar_url(NULL)$$,
    'set_avatar_url(NULL) clears the avatar');
SELECT lives_ok($$SELECT public.set_discovery_opt_in(true)$$,
    'set_discovery_opt_in persists');
SELECT lives_ok($$SELECT public.set_read_receipts_enabled(false)$$,
    'set_read_receipts_enabled persists');
SELECT lives_ok($$SELECT public.set_profile_public(true)$$,
    'set_profile_public persists');
SELECT ok(
    (SELECT avatar_url IS NULL
        AND discovery_opt_in IS TRUE
        AND read_receipts_enabled IS FALSE
        AND profile_public IS TRUE
     FROM public.users
     WHERE id = '47474747-4747-4747-4747-474747474706'),
    'all four setter effects persisted on the own row'
);

-- helper sanity: sanitizer parity with the Dart client
SELECT is(
    public.sanitize_username(E'\uFF33\uFF4F\uFF46\uFF49\uFF41'),
    'Sofia',
    'sanitize_username NFKC-folds fullwidth forms (client parity)'
);
SELECT is(
    public.sanitize_free_text(E'line1\u000Aline2', 160),
    'line1line2',
    'sanitize_free_text strips control characters'
);
SELECT is(
    public.sanitize_free_text(NULL, 160),
    NULL,
    'sanitize_free_text(NULL) is NULL'
);

-- restore a clean claims context for any later sections
SELECT set_config('request.jwt.claims', '', true);

-- ============================================================
-- SECTION 61: search abuse protection (baseline 130_search/01_search_rpc.sql,
-- OWASP API4 hardening of the user-search endpoint).
--   61a. search_users(p_query text): SECURITY DEFINER + empty search_path +
--        PUBLIC-revoked + authenticated-EXECUTABLE.
--   61b. search_rate_limits counter table: PK/FK shape, defaults, RLS
--        enabled + FORCED, zero client privileges.
--   61c. idx_users_username_prefix uses text_pattern_ops (allowed searches
--        must be index scans).
--   61d. Behavioral matrix under JWT claims: prefix match with caller
--        exclusion, SR002 on short/long queries, SR003 for anon, SR001 once
--        the 60/rolling-minute quota is exceeded, window-expiry reset,
--        LIKE-wildcard escaping.
-- ============================================================

-- 61a: RPC shape + privileges
SELECT has_function('search_users', ARRAY['text'],
    'search_users(p_query text) exists (130_search)');
SELECT is_definer('public', 'search_users', ARRAY['text'],
    'search_users is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'search_users'),
    'search_users sets search_path = '''' (130_search)'
);
SELECT function_privs_are('public', 'search_users', ARRAY['text']::name[], 'public', ARRAY[]::name[],
    'search_users is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'search_users', ARRAY['text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'search_users is authenticated-EXECUTABLE');

-- 61b: counter table
SELECT has_table('search_rate_limits',
    'search_rate_limits exists (130_search)');
SELECT has_pk('search_rate_limits',
    'search_rate_limits has a primary key (user_id)');
SELECT col_type_is('search_rate_limits', 'user_id', 'uuid',
    'search_rate_limits.user_id is uuid');
SELECT col_not_null('search_rate_limits', 'user_id',
    'search_rate_limits.user_id is NOT NULL');
SELECT col_type_is('search_rate_limits', 'window_start', 'timestamp with time zone',
    'search_rate_limits.window_start is timestamptz');
SELECT col_not_null('search_rate_limits', 'window_start',
    'search_rate_limits.window_start is NOT NULL');
SELECT col_default_is('search_rate_limits', 'window_start', 'now()',
    'search_rate_limits.window_start defaults now()');
SELECT col_type_is('search_rate_limits', 'search_count', 'integer',
    'search_rate_limits.search_count is integer');
SELECT col_not_null('search_rate_limits', 'search_count',
    'search_rate_limits.search_count is NOT NULL');
SELECT col_default_is('search_rate_limits', 'search_count', '0',
    'search_rate_limits.search_count defaults 0');
SELECT fk_ok('search_rate_limits', ARRAY['user_id'::name], 'users', ARRAY['id'::name],
    'search_rate_limits.user_id cascades from users.id (ON DELETE CASCADE)');
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.search_rate_limits'::regclass),
    'search_rate_limits has RLS enabled'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.search_rate_limits'::regclass),
    'search_rate_limits has FORCE ROW LEVEL SECURITY'
);
SELECT ok(
    NOT has_table_privilege('anon', 'public.search_rate_limits', 'SELECT'),
    'anon holds NO privilege on search_rate_limits'
);
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.search_rate_limits', 'INSERT'),
    'authenticated holds NO write privilege on search_rate_limits'
);

-- 61c: prefix index
SELECT ok(
    (SELECT count(*) = 1 FROM pg_indexes
     WHERE indexname = 'idx_users_username_prefix'
       AND indexdef ILIKE '%text_pattern_ops%'),
    'idx_users_username_prefix uses text_pattern_ops (ILIKE-prefix index scans)'
);

-- 61d: behavior under JWT claims
SELECT lives_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('88888888-8888-8888-8888-888888881101', 'pgtapsearcha', DATE '1990-06-01')$$,
    'search fixture A inserted (privileged, CHECK-compliant)'
);
SELECT lives_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('88888888-8888-8888-8888-888888881102', 'pgtapsearchb', DATE '1990-06-02')$$,
    'search fixture B inserted'
);
SELECT set_config('request.jwt.claims',
    '{"sub":"88888888-8888-8888-8888-888888881101","role":"authenticated"}', false);
-- Q8: set B public for the prefix test; keep A private for the exact test.
UPDATE public.users SET profile_public = true
 WHERE id = '88888888-8888-8888-8888-888888881102';
SELECT is(
    (SELECT count(*) FROM public.search_users('pgtapsea')),
    1::bigint,
    'prefix match returns only the OTHER opted-in user (caller excluded)'
);
UPDATE public.users SET profile_public = false
 WHERE id = '88888888-8888-8888-8888-888888881102';
SELECT is(
    (SELECT count(*) FROM public.search_users('pgtapsea')),
    0::bigint,
    'private profile is NOT returned by a prefix (Q8)'
);
SELECT is(
    (SELECT count(*) FROM public.search_users('PGTAPSEARCHB')),
    1::bigint,
    'private profile is found by exact username, case-insensitively (Q8)'
);
SELECT throws_ok($$SELECT public.search_users('pgta')$$,
    'SR002', 'invalid_query_length',
    'sub-5-char query rejected (SR002)');
SELECT throws_ok(
    $$SELECT public.search_users('pgtapsearchapgtapsearchapgtapsearchapgtapsearchapgtapsea')$$,
    'SR002', 'invalid_query_length',
    '51-char query rejected (SR002)'
);
SELECT set_config('request.jwt.claims', '', false);
SELECT throws_ok($$SELECT public.search_users('pgtapsea')$$,
    'SR003', 'not_authenticated',
    'anon caller rejected (SR003)');
SELECT set_config('request.jwt.claims',
    '{"sub":"88888888-8888-8888-8888-888888881101","role":"authenticated"}', false);
SELECT lives_ok(
    $$INSERT INTO public.search_rate_limits (user_id, window_start, search_count)
      VALUES ('88888888-8888-8888-8888-888888881101', now(), 60)
      ON CONFLICT (user_id) DO UPDATE SET search_count = 60, window_start = now()$$,
    'quota counter seeded to 60 (service-side, mirrors opt-015)'
);
SELECT throws_ok($$SELECT public.search_users('pgtapsea')$$,
    'SR001', 'search_rate_limit_exceeded',
    '61st search inside the window raises SR001');
UPDATE public.search_rate_limits
   SET window_start = now() - interval '2 minutes'
 WHERE user_id = '88888888-8888-8888-8888-888888881101';
SELECT lives_ok($$SELECT public.search_users('pgtapsea')$$,
    'expired window resets the quota (call succeeds again)');
SELECT is(
    (SELECT count(*) FROM public.search_users('pgtapsea_%')),
    0::bigint,
    'LIKE wildcards in the query are escaped (no %/_ expansion)'
);
SELECT set_config('request.jwt.claims', '', true);

-- ============================================================
-- SECTION 49d: Minigame partida names (migration 160_minigame_names) —
-- a player may name their partida (or fall back to the auto "partida-XX"
-- display): minigame_sessions.name carries the optional title and
-- create_minigame_session stores the nullable p_name.
-- ============================================================
SELECT has_column('minigame_sessions', 'name',
    'minigame_sessions.name exists (160_minigame_names)');
SELECT col_is_null('minigame_sessions', 'name',
    'minigame_sessions.name is NULLABLE (null/empty = auto "partida-XX" display, 160_minigame_names)');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%INSERT INTO public.minigame_sessions%'
       AND pg_get_functiondef(p.oid) LIKE '%p_name%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session stores p_name on the session row (160_minigame_names)'
);

-- ============================================================
-- SECTION 49e: get_friend_profiles(uuid[]) — batched accepted-friend profile
-- resolution for the on-device friends cache (130_search/02_get_friend_profiles,
-- 2026-08-30). SECURITY DEFINER + empty search_path + PUBLIC-revoked +
-- authenticated-EXECUTABLE, scoped to auth.uid()'s accepted friendships only.
-- ============================================================
SELECT has_function('get_friend_profiles', ARRAY['uuid[]'],
    'get_friend_profiles(uuid[]) exists (130_search/02_get_friend_profiles)');
SELECT is_definer('public', 'get_friend_profiles', ARRAY['uuid[]'],
    'get_friend_profiles is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'get_friend_profiles'),
    'get_friend_profiles sets search_path = '''' '
);
SELECT function_privs_are('public', 'get_friend_profiles', ARRAY['uuid[]']::name[], 'public', ARRAY[]::name[],
    'get_friend_profiles is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'get_friend_profiles', ARRAY['uuid[]']::name[], 'authenticated', ARRAY['EXECUTE'],
    'get_friend_profiles is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%user_search_view%'
       AND pg_get_functiondef(p.oid) LIKE '%auth.uid()%'
     FROM pg_proc p WHERE proname = 'get_friend_profiles'),
    'get_friend_profiles reads user_search_view scoped by auth.uid() (accepted friends only)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%status = ''accepted''%'
     FROM pg_proc p WHERE proname = 'get_friend_profiles'),
    'get_friend_profiles returns only ACCEPTED friendships'
);

-- ============================================================
-- SECTION 49f: Minigame invite badges (migration 170_minigame_invite_badges,
-- 2026-08-30) — invitee-side "partida-N" + per-game feed badges:
--   * minigame_sessions.auto_name — the server-computed partida-N running
--     number per game_type among ACTIVE sessions, stored so creator AND
--     invitee resolve the SAME canonical name from the row in isolation
--     (160 kept the auto-name client-side from a list index, which is not
--     resolvable for a session shown alone). Duplicates allowed.
--   * create_minigame_session computes + stores auto_name at creation.
--   * notify_minigame_invite now fires for BOTH direct and group sessions
--     (the 140 early-return for group_id IS NULL is gone) and carries
--     gameType + sessionName in the notification data so the client groups
--     the per-game badge without an extra query.
-- ============================================================
SELECT has_column('minigame_sessions', 'auto_name',
    'minigame_sessions.auto_name exists (170_minigame_invite_badges)');
SELECT col_is_null('minigame_sessions', 'auto_name',
    'minigame_sessions.auto_name is NULLABLE (fallback when no auto name was computed)');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%auto_name%'
       AND pg_get_functiondef(p.oid) LIKE '%partida-''%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session computes and stores the server-side partida-N auto_name (170_minigame_invite_badges)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%INSERT INTO public.minigame_sessions%'
       AND pg_get_functiondef(p.oid) LIKE '%auto_name%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session inserts the auto_name column (170_minigame_invite_badges)'
);
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'notify_minigame_invite_trigger'
          AND tgrelid = 'public.minigame_sessions'::regclass
    ),
    'notify_minigame_invite_trigger stays on minigame_invites (170 keeps the 140 placement)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%gameType%'
       AND pg_get_functiondef(p.oid) LIKE '%sessionName%'
     FROM pg_proc p WHERE proname = 'notify_minigame_invite'),
    'notify_minigame_invite payload carries gameType + sessionName (170_minigame_invite_badges)'
);
SELECT ok(
    NOT (SELECT pg_get_functiondef(p.oid) LIKE '%v_group_id IS NULL THEN%'
             AND pg_get_functiondef(p.oid) LIKE '%RETURN NEW;%'
         FROM pg_proc p WHERE proname = 'notify_minigame_invite'),
    'notify_minigame_invite no longer early-returns for DIRECT sessions (170 fires for both scopes)'
);

-- ============================================================
-- SECTION 49g: Minigame partida lobby (migration
-- 180_minigame_lobby, 2026-08-30) — realtime participant list, per-player
-- Ready, creator-only Start, creator removal:
--   * minigame_game_state.ready — the authoritative jsonb ready map
--     ({participant_id: bool}), written ONLY through set_minigame_ready and
--     streamed live via the existing minigame_game_state realtime
--     subscription.
--   * set_minigame_ready(uuid, boolean) — SECURITY DEFINER intent handler:
--     standing gate (participant/invitee/group-member) + active-session
--     gate, then upserts the caller's flag into the ready map.
--   * get_minigame_participants(uuid) — SECURITY DEFINER roster resolution
--     (id/username/avatar_url) through user_search_view, works for
--     NON-friends, I-57 typed-jsonb-status contract.
--   * remove_minigame_participant(uuid, uuid) — SECURITY DEFINER
--     CREATOR-ONLY removal: refunds the wager escrow (minigame_refund),
--     drops the participant, deletes their invite, clears their ready flag.
--   * init_minigame_game_state — CREATE OR REPLACE with a SERVER-SIDE
--     creator gate (participants[0] only → not_creator) so Start is
--     backend-enforced, never just a UI rule; ready map clears on init.
--   * minigame_sessions JOINS supabase_realtime so participant join/remove
--     UPDATEs stream LIVE to the lobby.
-- ============================================================
SELECT has_column('minigame_game_state', 'ready',
    'minigame_game_state.ready exists (180_minigame_lobby)');
SELECT col_is_null('minigame_game_state', 'ready',
    'minigame_game_state.ready is NULLABLE (absent = nobody ready)');

SELECT has_function('set_minigame_ready', ARRAY['uuid', 'boolean'],
    'set_minigame_ready(p_session_id uuid, p_ready boolean) exists (180_minigame_lobby)');
SELECT is_definer('public', 'set_minigame_ready', ARRAY['uuid', 'boolean'],
    'set_minigame_ready is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'set_minigame_ready'),
    'set_minigame_ready sets search_path = '''' (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%jsonb_build_object(auth.uid()::text, p_ready)%'
       AND pg_get_functiondef(p.oid) LIKE '%ready%'
     FROM pg_proc p WHERE proname = 'set_minigame_ready'),
    'set_minigame_ready upserts the caller''s flag into the ready map keyed by auth.uid()'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''not_allowed''%'
       AND pg_get_functiondef(p.oid) LIKE '%public.minigame_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%public.group_members%'
     FROM pg_proc p WHERE proname = 'set_minigame_ready'),
    'set_minigame_ready gates by participant / invitee / group-member standing (not_allowed)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''session_not_active''%'
     FROM pg_proc p WHERE proname = 'set_minigame_ready'),
    'set_minigame_ready rejects toggles on finished sessions (session_not_active)'
);
SELECT function_privs_are('public', 'set_minigame_ready', ARRAY['uuid', 'boolean']::name[], 'public', ARRAY[]::name[],
    'set_minigame_ready is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'set_minigame_ready', ARRAY['uuid', 'boolean']::name[], 'authenticated', ARRAY['EXECUTE'],
    'set_minigame_ready is authenticated-EXECUTABLE');

SELECT has_function('get_minigame_participants', ARRAY['uuid'],
    'get_minigame_participants(p_session_id uuid) exists (180_minigame_lobby)');
SELECT is_definer('public', 'get_minigame_participants', ARRAY['uuid'],
    'get_minigame_participants is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'get_minigame_participants'),
    'get_minigame_participants sets search_path = '''' (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.user_search_view%'
     FROM pg_proc p WHERE proname = 'get_minigame_participants'),
    'get_minigame_participants resolves the roster through user_search_view (works for non-friends)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%jsonb_build_object(%''id'', usv.id%'
       AND pg_get_functiondef(p.oid) LIKE '%jsonb_agg%'
     FROM pg_proc p WHERE proname = 'get_minigame_participants'),
    'get_minigame_participants returns the I-57 typed jsonb roster (id/username/avatar_url)'
);
SELECT function_privs_are('public', 'get_minigame_participants', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'get_minigame_participants is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'get_minigame_participants', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'get_minigame_participants is authenticated-EXECUTABLE');

SELECT has_function('remove_minigame_participant', ARRAY['uuid', 'uuid'],
    'remove_minigame_participant(p_session_id uuid, p_user_id uuid) exists (180_minigame_lobby)');
SELECT is_definer('public', 'remove_minigame_participant', ARRAY['uuid', 'uuid'],
    'remove_minigame_participant is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'remove_minigame_participant'),
    'remove_minigame_participant sets search_path = '''' (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) NOT LIKE '%minigame_refund%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%personal_shards%'
     FROM pg_proc p WHERE proname = 'remove_minigame_participant'),
    'remove_minigame_participant removes without a wager refund (wagers removed)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%DELETE FROM public.minigame_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%ready - p_user_id::text%'
     FROM pg_proc p WHERE proname = 'remove_minigame_participant'),
    'remove_minigame_participant closes the invite and clears the ready flag'
);
SELECT function_privs_are('public', 'remove_minigame_participant', ARRAY['uuid', 'uuid']::name[], 'public', ARRAY[]::name[],
    'remove_minigame_participant is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'remove_minigame_participant', ARRAY['uuid', 'uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'remove_minigame_participant is authenticated-EXECUTABLE');

SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''not_creator''%'
       AND pg_get_functiondef(p.oid) LIKE '%v_participants[1] <> auth.uid()%'
     FROM pg_proc p WHERE proname = 'init_minigame_game_state'),
    'init_minigame_game_state is CREATOR-ONLY, backend-enforced via participants[0] (not_creator, 180_minigame_lobby)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%ready%'
       AND pg_get_functiondef(p.oid) LIKE '%''{}''::jsonb%'
     FROM pg_proc p WHERE proname = 'init_minigame_game_state'),
    'init_minigame_game_state seeds an empty ready map on start (lobby roster resets)'
);
SELECT ok(
    EXISTS (SELECT 1 FROM pg_publication_tables
            WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_sessions'),
    'minigame_sessions joins supabase_realtime (participant join/remove streams live to the lobby, 180_minigame_lobby)'
);
SELECT ok(
    (SELECT relreplident = 'f' FROM pg_class WHERE oid = 'public.minigame_sessions'::regclass),
    'minigame_sessions has REPLICA IDENTITY FULL (full-row realtime UPDATE payloads — the roster diff always has the authoritative participants array, 2026-09-02)'
);

-- SECTION 49h: Minigame game-state at creation (migration
-- 191_minigame_game_state_at_creation, 2026-08-30) — the minigame_game_state
-- row exists FROM session creation so every ready toggle is an UPDATE
-- (streamed by the update-only realtime subscription from the first one).
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%INSERT INTO public.minigame_game_state (session_id, game_type, state, ready)%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session seeds the minigame_game_state row at creation (191)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%UPDATE public.minigame_game_state%'
       AND NOT pg_get_functiondef(p.oid) LIKE '%ON CONFLICT (session_id) DO UPDATE%'
     FROM pg_proc p WHERE proname = 'set_minigame_ready'),
    'set_minigame_ready is a plain UPDATE (row exists at creation, 191)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%jsonb_build_object(auth.uid()::text, p_ready)%'
     FROM pg_proc p WHERE proname = 'set_minigame_ready'),
    'set_minigame_ready still upserts the caller''s ready flag keyed by auth.uid()'
);

-- SECTION 49i: Minigame invite notice (migration 200_minigame_invite_notice,
-- 2026-08-30) — the invite notification states the cost (FREE while wagers are
-- retired by 300_slim/03_remove_wagers) and identifies the inviter (the
-- username for a DIRECT session, or the group name for a GROUP session):
--   * The body states the cost: "FREE" for the wager-free game.
--   * The data payload keeps the "wager" key (0) plus "inviterName"
--     (user_search_view) and "groupName" (the group row, null for direct) —
--     the RLS-invisible who-invited context the accept surfaces must show.
--     gameType + sessionName + sessionId + inviteId stay intact.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%FREE%'
       AND pg_get_functiondef(p.oid) LIKE '%''wager''%'
     FROM pg_proc p WHERE proname = 'notify_minigame_invite'),
    'notify_minigame_invite body states the cost explicitly (FREE while wagers are retired)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%inviterName%'
       AND pg_get_functiondef(p.oid) LIKE '%user_search_view%'
     FROM pg_proc p WHERE proname = 'notify_minigame_invite'),
    'notify_minigame_invite resolves the inviter username via user_search_view (200_minigame_invite_notice)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%groupName%'
       AND pg_get_functiondef(p.oid) LIKE '%public.groups%'
     FROM pg_proc p WHERE proname = 'notify_minigame_invite'),
    'notify_minigame_invite resolves the group name for group sessions (200_minigame_invite_notice)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%gameType%'
       AND pg_get_functiondef(p.oid) LIKE '%sessionName%'
     FROM pg_proc p WHERE proname = 'notify_minigame_invite'),
    'notify_minigame_invite keeps gameType + sessionName in the payload (170 stays intact)'
);

-- SECTION 49j: Minigame rounds + reaction voting + leaderboard (migration
-- 201_minigame_voting, 2026-08-30) — the round target, the paid-position
-- count N, the realtime emoji voting, and the harmonic leaderboard payout:
--   * minigame_sessions.round_target (int) + prize_positions (int, default 3)
--     frozen at creation by create_minigame_session (p_rounds,
--     p_prize_positions).
--   * minigame_reactions — one vote per (session, round, voter), FORCE RLS,
--     reads by participants/invitees/group members, writes ONLY through
--     submit_minigame_reaction.
--   * minigame_results — the settle-once leaderboard row, FORCE RLS, written
--     ONLY by finish_minigame_game.
--   * submit_minigame_reaction(uuid, text) — SECURITY DEFINER, idempotent
--     upsert + realtime mirror into state.reactions.
--   * finish_minigame_game(uuid) — SECURITY DEFINER settlement replacing
--     finish_minigame_session + complete_minigame_game: HARMONIC prize split
--     (1/rank weights, integer-exact, sum == pot).
--   * advance_minigame_turn (CREATE OR REPLACE) scores the round server-side
--     and AUTO-FINISHES at round_target.
SELECT has_column('minigame_sessions', 'round_target',
    'minigame_sessions.round_target exists (201_minigame_voting)');
SELECT col_is_null('minigame_sessions', 'round_target',
    'minigame_sessions.round_target is NULLABLE (legacy open-ended games)');
SELECT has_column('minigame_sessions', 'prize_positions',
    'minigame_sessions.prize_positions exists (201_minigame_voting)');
SELECT col_not_null('minigame_sessions', 'prize_positions',
    'minigame_sessions.prize_positions is NOT NULL (default 3)');
SELECT col_has_default('minigame_sessions', 'prize_positions',
    'minigame_sessions.prize_positions defaults to 3');

SELECT has_table('minigame_reactions',
    'minigame_reactions exists (201_minigame_voting)');
SELECT col_not_null('minigame_reactions', 'voter_id',
    'minigame_reactions.voter_id is NOT NULL (one vote per voter per round)');
SELECT has_table('minigame_results',
    'minigame_results exists (201_minigame_voting)');

SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'minigame_reactions'::regclass),
    'minigame_reactions has FORCE ROW LEVEL SECURITY (201_minigame_voting)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'minigame_results'::regclass),
    'minigame_results has FORCE ROW LEVEL SECURITY (201_minigame_voting)'
);
SELECT policies_are('minigame_reactions', ARRAY['mgs_reactions_read', 'active_users_only'
],
    'minigame_reactions has exactly the participant-read policy (201_minigame_voting)');
SELECT policies_are('minigame_results', ARRAY['mgs_results_read', 'active_users_only'
],
    'minigame_results has exactly the participant-read policy (201_minigame_voting)');

SELECT has_function('submit_minigame_reaction', ARRAY['uuid', 'text'],
    'submit_minigame_reaction(p_session_id uuid, p_reaction text) exists (201_minigame_voting)');
SELECT is_definer('public', 'submit_minigame_reaction', ARRAY['uuid', 'text'],
    'submit_minigame_reaction is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction sets search_path = '''' (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.minigame_reactions%'
       AND pg_get_functiondef(p.oid) LIKE '%ON CONFLICT (session_id, round, voter_id) DO UPDATE%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction upserts one vote per (session, round, voter)'
);

SELECT function_privs_are('public', 'submit_minigame_reaction', ARRAY['uuid', 'text']::name[], 'public', ARRAY[]::name[],
    'submit_minigame_reaction is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'submit_minigame_reaction', ARRAY['uuid', 'text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'submit_minigame_reaction is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'finish_minigame_game', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'finish_minigame_game is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'finish_minigame_game', ARRAY['uuid']::name[], 'authenticated', ARRAY[]::name[],
    'finish_minigame_game is server-only (authenticated cannot settle)');
SELECT function_privs_are('public', 'finish_minigame_game', ARRAY['uuid']::name[], 'service_role', ARRAY['EXECUTE'],
    'finish_minigame_game is service_role-EXECUTABLE');

SELECT has_function('finish_minigame_game', ARRAY['uuid'],
    'finish_minigame_game(p_session_id uuid) exists (201_minigame_voting)');
SELECT is_definer('public', 'finish_minigame_game', ARRAY['uuid'],
    'finish_minigame_game is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'finish_minigame_game'),
    'finish_minigame_game sets search_path = '''' (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.minigame_results%'
       AND pg_get_functiondef(p.oid) LIKE '%gcd%'
     FROM pg_proc p WHERE proname = 'finish_minigame_game'),
    'finish_minigame_game writes minigame_results with harmonic (gcd) weights'
);

-- SECTION 49u: Full leaderboard ranking (migration 218_minigame_full_ranking,
-- 2026-09-20) — the settle-once leaderboard now carries EVERY participant with
-- their row_number() rank + real score; only the top N = prize_positions are
-- PAID (rank > N writes prize 0):
--   * the two per-branch `WHERE sc.rank <= v_prize_positions` filters are GONE,
--     so the result set is the FULL ranked roster.
--   * the harmonic weights still cap the PAID ranks at prize_positions.
--   * minigame_sessions has NO column `n`: the app's session select + pool
--     breakdown must read `prize_positions` (a client selecting `n` 400s the
--     whole session read — regression guard for the 2026-09-20 breakage).
SELECT ok(
    (SELECT position('sc.rank <= v_prize_positions' IN pg_get_functiondef(p.oid)) = 0
       AND pg_get_functiondef(p.oid) LIKE '%row_number() OVER%'
     FROM pg_proc p WHERE proname = 'finish_minigame_game'),
    'finish_minigame_game ranks ALL participants (no prize-position WHERE filter, 218_minigame_full_ranking)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%LEAST(COALESCE(v_prize_positions, 3), v_player_count)%'
       AND pg_get_functiondef(p.oid) LIKE '%public.minigame_results%'
     FROM pg_proc p WHERE proname = 'finish_minigame_game'),
    'finish_minigame_game still caps the PAID ranks at prize_positions (218_minigame_full_ranking)'
);
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'minigame_sessions'
          AND column_name = 'n'
    ),
    'minigame_sessions has no column "n" — clients must read prize_positions (2026-09-20 regression guard)'
);

-- The legacy settlement seams are REPLACED (201 user directive): the only
-- settlement RPC left is finish_minigame_game.
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'finish_minigame_session'),
    'finish_minigame_session is dropped (201 replaces the winner-takes-all seam)'
);
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'complete_minigame_game'),
    'complete_minigame_game is dropped (201 replaces the draw-only seam)'
);

-- The auto-finish at the total-turn target lives in the round-advance helper
-- (202 moved the advance out of advance_minigame_turn into _minigame_advance_round).
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%round_target%'
       AND pg_get_functiondef(p.oid) LIKE '%finish_minigame_game%'
     FROM pg_proc p WHERE proname = '_minigame_advance_round'),
    '_minigame_advance_round auto-finishes via finish_minigame_game at round_target (202)'
);

-- Realtime membership for the live votes + settled leaderboard.
SELECT ok(
    EXISTS (SELECT 1 FROM pg_publication_tables
            WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_reactions'),
    'minigame_reactions joins supabase_realtime (votes stream live, 201_minigame_voting)'
);
SELECT ok(
    EXISTS (SELECT 1 FROM pg_publication_tables
            WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_results'),
    'minigame_results joins supabase_realtime (leaderboard streams live, 201_minigame_voting)'
);

-- SECTION 49k: Minigame play engine v2 (migration 202_minigame_play_v2,
-- 2026-08-30) — answer-first, modes, anonymous, E2EE answers:
--   * minigame_sessions + play_mode (by_turns|async), + anonymous bool,
--     + async_rounds_per_player (default 1), + async_ends_at (settable at
--     creation, no override).
--   * minigame_aliases — (session, participant) temp nickname, FORCE RLS,
--     read by participants, written ONLY through set_minigame_alias.
--   * minigame_answers — E2EE answer store (ciphertext only), FORCE RLS,
--     written ONLY through submit_minigame_answer / submit_minigame_pasar /
--     submit_minigame_async_answer.
--   * minigame_e2ee_bundles — sender-key distribution delivery rows (own-row
--     INSERT + recipient-read SELECT policies).
--   * submit_minigame_answer(uuid, text, text) / submit_minigame_pasar(uuid) /
--     submit_minigame_async_answer(uuid, text, text, text) /
--     react_minigame_round(uuid, integer, text) / set_minigame_alias(uuid,
--     text) — SECURITY DEFINER, authenticated-only EXECUTE.
SELECT has_column('minigame_sessions', 'play_mode',
    'minigame_sessions.play_mode exists (202_minigame_play_v2)');
SELECT col_has_check('minigame_sessions', 'play_mode',
    'minigame_sessions.play_mode has a CHECK (by_turns|async)');
SELECT has_column('minigame_sessions', 'anonymous',
    'minigame_sessions.anonymous exists (202_minigame_play_v2)');
SELECT col_not_null('minigame_sessions', 'anonymous',
    'minigame_sessions.anonymous is NOT NULL (default false)');
SELECT has_column('minigame_sessions', 'async_rounds_per_player',
    'minigame_sessions.async_rounds_per_player exists (202_minigame_play_v2)');
SELECT has_column('minigame_sessions', 'async_ends_at',
    'minigame_sessions.async_ends_at exists (202_minigame_play_v2)');
SELECT col_is_null('minigame_sessions', 'async_ends_at',
    'minigame_sessions.async_ends_at is NULLABLE (NULL for by_turns)');

SELECT has_table('minigame_aliases',
    'minigame_aliases exists (202_minigame_play_v2)');
SELECT has_table('minigame_answers',
    'minigame_answers exists (202_minigame_play_v2)');
SELECT has_table('minigame_e2ee_bundles',
    'minigame_e2ee_bundles exists (202_minigame_play_v2)');

SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'minigame_aliases'::regclass),
    'minigame_aliases has FORCE ROW LEVEL SECURITY (202_minigame_play_v2)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'minigame_answers'::regclass),
    'minigame_answers has FORCE ROW LEVEL SECURITY (202_minigame_play_v2)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'minigame_e2ee_bundles'::regclass),
    'minigame_e2ee_bundles has FORCE ROW LEVEL SECURITY (202_minigame_play_v2)'
);
SELECT policies_are('minigame_aliases', ARRAY['mgs_aliases_read', 'active_users_only'
],
    'minigame_aliases has exactly the participant-read policy (202_minigame_play_v2)');
SELECT policies_are('minigame_answers', ARRAY['mgs_answers_read', 'active_users_only'
],
    'minigame_answers has exactly the participant-read policy (202_minigame_play_v2)');
SELECT policies_are('minigame_e2ee_bundles', ARRAY['mgs_bundles_insert_own', 'mgs_bundles_update_own', 'mgs_bundles_read_recipient', 'active_users_only'
],
    'minigame_e2ee_bundles has the own-insert + own-update + recipient-read policies (202_minigame_play_v2)');
-- The upsert-conflict leg of putE2eeBundle needs UPDATE privilege + policy
-- (2026-08-31 on-device 42501 fix). DELETE stays withheld — bundles are
-- additive/retained (no-wipe directive).
SELECT ok(
    (SELECT bool_and(privilege_type IN ('SELECT', 'INSERT', 'UPDATE'))
     FROM information_schema.role_table_grants
     WHERE table_schema = 'public' AND table_name = 'minigame_e2ee_bundles'
       AND grantee = 'authenticated'),
    'authenticated has exactly SELECT/INSERT/UPDATE on minigame_e2ee_bundles (no DELETE, 202)'
);
-- Supabase RLS rule "UPDATE requires a SELECT policy": the sender must be able
-- to SELECT its own outbound row for the upsert-conflict UPDATE (and for the
-- host's self-heal of its own minted keys). recipient-only read silently
-- no-oped every re-delivery (2026-08-31 on-device fix).
SELECT ok(
    (SELECT qual
       FROM pg_policies
      WHERE tablename = 'minigame_e2ee_bundles' AND policyname = 'mgs_bundles_read_recipient') LIKE '%sender_id = auth.uid()%',
    'mgs_bundles_read_recipient lets the SENDER read own outbound rows (UPDATE pre-SELECT + self-heal)'
);

SELECT has_function('submit_minigame_answer', ARRAY['uuid', 'text', 'text'],
    'submit_minigame_answer(p_session_id uuid, p_answer_ciphertext text, p_image_storage_path text) exists (202_minigame_play_v2)');
SELECT is_definer('public', 'submit_minigame_answer', ARRAY['uuid', 'text', 'text'],
    'submit_minigame_answer is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'submit_minigame_answer'),
    'submit_minigame_answer sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'submit_minigame_answer', ARRAY['uuid', 'text', 'text']::name[], 'public', ARRAY[]::name[],
    'submit_minigame_answer is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'submit_minigame_answer', ARRAY['uuid', 'text', 'text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'submit_minigame_answer is authenticated-EXECUTABLE');

SELECT has_function('submit_minigame_pasar', ARRAY['uuid'],
    'submit_minigame_pasar(p_session_id uuid) exists (202_minigame_play_v2)');
SELECT is_definer('public', 'submit_minigame_pasar', ARRAY['uuid'],
    'submit_minigame_pasar is SECURITY DEFINER');

SELECT has_function('submit_minigame_async_answer', ARRAY['uuid', 'text', 'text', 'text'],
    'submit_minigame_async_answer(p_session_id uuid, p_prompt_type text, p_answer_ciphertext text, p_image_storage_path text) exists (202_minigame_play_v2)');
SELECT is_definer('public', 'submit_minigame_async_answer', ARRAY['uuid', 'text', 'text', 'text'],
    'submit_minigame_async_answer is SECURITY DEFINER');

SELECT has_function('react_minigame_round', ARRAY['uuid', 'integer', 'text'],
    'react_minigame_round(p_session_id uuid, p_round integer, p_reaction text) exists (202_minigame_play_v2)');
SELECT is_definer('public', 'react_minigame_round', ARRAY['uuid', 'integer', 'text'],
    'react_minigame_round is SECURITY DEFINER');

SELECT has_function('set_minigame_alias', ARRAY['uuid', 'text'],
    'set_minigame_alias(p_session_id uuid, p_alias text) exists (202_minigame_play_v2)');
SELECT is_definer('public', 'set_minigame_alias', ARRAY['uuid', 'text'],
    'set_minigame_alias is SECURITY DEFINER');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.minigame_aliases%'
       AND pg_get_functiondef(p.oid) LIKE '%ON CONFLICT (session_id, participant_id) DO UPDATE%'
     FROM pg_proc p WHERE proname = 'set_minigame_alias'),
    'set_minigame_alias upserts one temp nickname per (session, participant)'
);
-- 214_minigame_alias_unique: session-unique, case-insensitive nicknames.
SELECT ok(
    to_regclass('public.minigame_aliases_session_alias_uniq') IS NOT NULL,
    'minigame_aliases has a session+alias index (214_minigame_alias_unique)');
SELECT ok(
    (SELECT indisunique FROM pg_index
      WHERE indexrelid = 'minigame_aliases_session_alias_uniq'::regclass),
    'the nickname index is UNIQUE (session_id, lower(btrim(alias))) (214_minigame_alias_unique)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%alias_taken%'
       AND pg_get_functiondef(p.oid) LIKE '%lower(btrim(alias))%'
     FROM pg_proc p WHERE proname = 'set_minigame_alias'),
    'set_minigame_alias rejects a taken nickname (case-insensitive, 214_minigame_alias_unique)'
);

-- The answer-first reaction gate (202): the subject cannot react to their own
-- round and reactions open only after the answer (ciphertext) is submitted.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%own_round%'
       AND pg_get_functiondef(p.oid) LIKE '%answer_pending%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction enforces the own-round + answer-first gates (202_minigame_play_v2)'
);

-- The by_turns advance waits for every non-subject participant to react
-- (all-reacted contract) and lets the creator force-advance.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%waiting_reactions%'
       AND pg_get_functiondef(p.oid) LIKE '%v_required_count%'
       AND pg_get_functiondef(p.oid) LIKE '%distinct%'
       AND pg_get_functiondef(p.oid) LIKE '%_minigame_advance_round%'
     FROM pg_proc p WHERE proname = 'advance_minigame_turn'),
    'advance_minigame_turn waits for all reactions unless the creator forces (202_minigame_play_v2)'
);

-- The async timer auto-finish: pg_cron job + the lazy read flip.
SELECT ok(
    EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'minigames-async-finish'),
    'minigames-async-finish pg_cron job settles async sessions past their deadline (202_minigame_play_v2)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%async_ends_at%'
       AND pg_get_functiondef(p.oid) LIKE '%finish_minigame_game%'
     FROM pg_proc p WHERE proname = 'get_minigame_game_state'),
    'get_minigame_game_state lazy-flips an expired async timer to finished (202_minigame_play_v2)'
);

-- ======================================================================
-- SECTION 49m: host-device-confirmed countdown (203_minigame_host_start,
-- 2026-08-31) — start_minigame_match flips countdown → playing, creator-only.
-- ======================================================================
SELECT has_function('start_minigame_match', ARRAY['uuid'],
    'start_minigame_match(p_session_id uuid) exists (203_minigame_host_start)');
SELECT is_definer('public', 'start_minigame_match', ARRAY['uuid'],
    'start_minigame_match is SECURITY DEFINER');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%not_creator%'
       AND pg_get_functiondef(p.oid) LIKE '%''playing''%'
       AND pg_get_functiondef(p.oid) LIKE '%''countdown''%'
     FROM pg_proc p WHERE proname = 'start_minigame_match'),
    'start_minigame_match is creator-only (not_creator) and flips countdown → playing'
);
SELECT function_privs_are('public', 'start_minigame_match', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'start_minigame_match is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'start_minigame_match', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'start_minigame_match is authenticated-EXECUTABLE');

-- There is NO countdown_ends_at deadline (the countdown is host-device based):
-- init must not seed it and get must not lazy-flip on it.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) NOT LIKE '%countdown_ends_at%'
     FROM pg_proc p WHERE proname = 'init_minigame_game_state'),
    'init_minigame_game_state does NOT seed countdown_ends_at (host-device countdown, 203)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) NOT LIKE '%countdown_ends_at%'
     FROM pg_proc p WHERE proname = 'get_minigame_game_state'),
    'get_minigame_game_state has NO countdown lazy-flip (host confirms via start_minigame_match, 203)'
);

-- Realtime membership for the live aliases + answers.
SELECT ok(
    EXISTS (SELECT 1 FROM pg_publication_tables
            WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_aliases'),
    'minigame_aliases joins supabase_realtime (nicknames stream live, 202_minigame_play_v2)'
);
SELECT ok(
    EXISTS (SELECT 1 FROM pg_publication_tables
            WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_answers'),
    'minigame_answers joins supabase_realtime (answers stream live, 202_minigame_play_v2)'
);

-- ======================================================================
-- SECTION 49k (cont.): play-engine security hardening (2026-08-31) —
-- active-only group members, participant-only writers/bundles, distinct-
-- voter reaction counts (TODO.md §3.7 findings A–E).
-- ======================================================================

-- Finding A: the RLS read policies require gm.status='active' + not-deleted
-- (the ms_read_group_member / mgs_*_read status-less EXISTS was the hole).
SELECT ok(
    (SELECT pg_get_expr(polqual, polrelid) LIKE '%gm.status = ''active''%'
     FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
     WHERE p.polname = 'ms_read_group_member'),
    'ms_read_group_member requires gm.status = ''active'' (2026-08-31 hardening)'
);
SELECT ok(
    (SELECT pg_get_expr(polqual, polrelid) LIKE '%gm.status = ''active''%'
     FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
     WHERE p.polname = 'mgs_answers_read'),
    'mgs_answers_read requires gm.status = ''active'' (2026-08-31 hardening)'
);

-- Finding B: the play RPC group-member gates carry gm.status = 'active'.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%gm.status = ''active''%'
     FROM pg_proc p WHERE proname = 'get_minigame_game_state'),
    'get_minigame_game_state group-member gate requires gm.status = ''active'' (2026-08-31 hardening)'
);

-- Finding C: the reaction WRITER is participant-only.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%auth.uid() = ANY (v_participants)%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%minigame_invites mi%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction is participant-only (no invitee/group-member union) (2026-08-31 hardening)'
);

-- Finding D: mgs_bundles_insert_own dropped the invitee clause.
SELECT ok(
    NOT (SELECT pg_get_expr(polwithcheck, polrelid) LIKE '%minigame_invites%'
         FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
         WHERE p.polname = 'mgs_bundles_insert_own'),
    'mgs_bundles_insert_own no longer references minigame_invites (participant-only, 2026-08-31 hardening)'
);
SELECT ok(
    (SELECT pg_get_expr(polwithcheck, polrelid) LIKE '%recipient_id = ANY (s.participants)%'
     FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
     WHERE p.polname = 'mgs_bundles_insert_own'),
    'mgs_bundles_insert_own requires sender AND recipient to be participants (2026-08-31 hardening)'
);

-- Finding E + mirror shape: distinct-voter count + {"list","count"} mirror.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%count(distinct voter_id)%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction counts DISTINCT voters for the auto-advance gate (2026-08-31 hardening)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''list''%'
       AND pg_get_functiondef(p.oid) LIKE '%''count''%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction mirrors {"list": [...], "count": N} (2026-08-31 hardening)'
);

-- ======================================================================
-- SECTION 49l: encrypted image storage (2026-08-31) — TODO.md §4.6
-- Minigame image answers move from a DB column to a PRIVATE storage bucket:
--   * minigame_answers drops image_ciphertext and gains image_storage_path
--     (nullable; the bucket object path of the ENCRYPTED image bytes — the
--     server never sees plaintext or keys).
--   * submit_minigame_answer / submit_minigame_async_answer accept
--     p_image_storage_path text DEFAULT NULL and store that path (both on the
--     row and in the state mirror key 'image_storage_path').
--   * storage: private 'minigame_images' bucket + participant-gated SELECT
--     (storage_objects_minigame_images_select) + participant-only INSERT
--     (storage_objects_minigame_images_insert, session from path[1]).
-- ======================================================================

-- Column contract: image_storage_path replaces image_ciphertext.
SELECT ok(
    (SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
     WHERE c.relname = 'minigame_answers' AND a.attname = 'image_storage_path') = 1,
    'minigame_answers has image_storage_path (nullable bucket path, 2026-08-31)'
);
SELECT ok(
    (SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
     WHERE c.relname = 'minigame_answers' AND a.attname = 'image_ciphertext') = 0,
    'minigame_answers no longer has image_ciphertext (moved to storage, 2026-08-31)'
);
SELECT col_is_null('minigame_answers', 'image_storage_path',
    'minigame_answers.image_storage_path is NULLABLE (optional image answer, 2026-08-31)');

-- The by_turns answer RPC stores the storage path.
SELECT has_function('submit_minigame_answer', ARRAY['uuid', 'text', 'text'],
    'submit_minigame_answer(p_session_id uuid, p_answer_ciphertext text, p_image_storage_path text) exists (2026-08-31)');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%image_storage_path%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%image_ciphertext%'
     FROM pg_proc p WHERE proname = 'submit_minigame_answer'),
    'submit_minigame_answer stores image_storage_path and no longer references image_ciphertext (2026-08-31)'
);

-- The async answer RPC stores the storage path too.
SELECT has_function('submit_minigame_async_answer', ARRAY['uuid', 'text', 'text', 'text'],
    'submit_minigame_async_answer(p_session_id uuid, p_prompt_type text, p_answer_ciphertext text, p_image_storage_path text) exists (2026-08-31)');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%image_storage_path%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%image_ciphertext%'
     FROM pg_proc p WHERE proname = 'submit_minigame_async_answer'),
    'submit_minigame_async_answer stores image_storage_path and no longer references image_ciphertext (2026-08-31)'
);

-- The storage bucket is private + participant-gated object access.
SELECT ok(
    EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'minigame_images'),
    'minigame_images bucket exists (private encrypted-image storage, 2026-08-31)'
);
SELECT ok(
    NOT (SELECT public FROM storage.buckets WHERE id = 'minigame_images'),
    'minigame_images bucket is private (public=false, signed-URL retrieval only, 2026-08-31)'
);
SELECT ok(
    (SELECT count(*) = 6
       FROM pg_policies
      WHERE schemaname = 'storage' AND tablename = 'objects'
        AND policyname IN ('storage_objects_delete_own',
                           'storage_objects_insert_own',
                           'storage_objects_update_own',
                           'storage_objects_public_read_avatars_groups',
                           'storage_objects_minigame_images_select',
                           'storage_objects_minigame_images_insert')),
    'storage.objects carries the 6 kept policies (minigame-images select/insert, own writes, public read)'
);

-- The insert policy must read the object PATH (storage.objects.name), NOT the
-- correlated minigame_sessions.name column (partida name — NULL/empty for most
-- sessions). The 2026-09-01 column-shadow bug made foldername(name) resolve to
-- the session name → ''::uuid cast fails → every dare-with-image upload 403'd.
SELECT ok(
    (SELECT with_check FROM pg_policies
      WHERE schemaname = 'storage'
        AND tablename = 'objects'
        AND policyname = 'storage_objects_minigame_images_insert')
        ~ 'storage\.foldername\((storage\.)?objects\.name\)',
    'storage_objects_minigame_images_insert qualifies objects.name in the path foldername (2026-09-01)'
);

-- ======================================================================
-- SECTION 49o: lobby invite RPC (migration 205_minigame_invite_lobby,
-- 2026-09-01) — invite_minigame_players(p_session_id, p_invitees) invites
-- players into an ALREADY-CREATED session from the partida lobby (the
-- 2026-09-01 flow: create with zero invitees, then the HOST invites while
-- waiting). Mirrors the create-time validation block (blocked/deleted +
-- friends-only privacy, player-cap re-check) but is CREATOR-ONLY
-- (`participants[1]` gate, like Start/Remove) and idempotent (skips
-- self / already-participant / already-pending invitees — the
-- (session_id, invitee_id) UNIQUE keeps the table clean). The existing
-- notify_minigame_invite AFTER-INSERT trigger fires for each new row, so
-- notifications work unchanged.
-- ======================================================================
SELECT has_function('invite_minigame_players', ARRAY['uuid', 'uuid[]'],
    'invite_minigame_players(p_session_id uuid, p_invitees uuid[]) exists (205_minigame_invite_lobby)');
SELECT is_definer('public', 'invite_minigame_players', ARRAY['uuid', 'uuid[]']::name[],
    'invite_minigame_players is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'invite_minigame_players'),
    'invite_minigame_players sets search_path = "" (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''not_authenticated''%'
       AND pg_get_functiondef(p.oid) LIKE '%''session_not_found''%'
       AND pg_get_functiondef(p.oid) LIKE '%''session_not_active''%'
     FROM pg_proc p WHERE proname = 'invite_minigame_players'),
    'invite_minigame_players returns typed lifecycle statuses (I-57 contract)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''not_creator''%'
       AND pg_get_functiondef(p.oid) LIKE '%participants[1] <> v_current_user%'
     FROM pg_proc p WHERE proname = 'invite_minigame_players'),
    'invite_minigame_players is CREATOR-ONLY via participants[1] (not_creator)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.friendships%'
       AND pg_get_functiondef(p.oid) LIKE '%minigame_invite_friends_only%'
       AND pg_get_functiondef(p.oid) LIKE '%''invitee_friends_only''%'
     FROM pg_proc p WHERE proname = 'invite_minigame_players'),
    'invite_minigame_players enforces blocked + friends-only invite privacy server-side'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%v_player_limit%'
       AND pg_get_functiondef(p.oid) LIKE '%''player_limit_reached''%'
     FROM pg_proc p WHERE proname = 'invite_minigame_players'),
    'invite_minigame_players re-checks the frozen player cap (player_limit_reached)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.minigame_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%t.v <> ALL (v_participants)%'
       AND pg_get_functiondef(p.oid) LIKE '%t.v <> ALL (v_pending)%'
     FROM pg_proc p WHERE proname = 'invite_minigame_players'),
    'invite_minigame_players inserts pending rows and skips self / already-participant / already-pending invitees idempotently'
);
SELECT function_privs_are('public', 'invite_minigame_players', ARRAY['uuid', 'uuid[]']::name[], 'public', ARRAY[]::name[],
    'invite_minigame_players is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'invite_minigame_players', ARRAY['uuid', 'uuid[]']::name[], 'authenticated', ARRAY['EXECUTE'],
    'invite_minigame_players is authenticated-EXECUTABLE');

-- ======================================================================
-- SECTION 49n: reactor-side Pasar (migration 204_minigame_pasar,
-- 2026-09-01) — a NON-subject passes instead of emoji-reacting:
--   * minigame_reactions.reaction is NULLABLE (NULL = the pass marker) with a
--     CHECK keeping the six emoji values or NULL; the (session, round, voter)
--     PK still guarantees one action per voter per round.
--   * submit_minigame_reaction / react_minigame_round accept 'pasar' (upsert
--     a NULL-reaction row) and mirror a `pass` count into state.reactions.
--   * _minigame_advance_round scores emoji_count - pass_count/2 (integer-
--     normalized when integral; -1 when the round had ZERO emojis).
--   * finish_minigame_game settles fractional by_turns + async scores.
SELECT ok(
    (SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
     WHERE c.relname = 'minigame_reactions' AND a.attname = 'reaction' AND a.attnotnull) = 0,
    'minigame_reactions.reaction is NULLABLE (NULL = reactor Pasar, 204_minigame_pasar)'
);
SELECT col_has_check('minigame_reactions', 'reaction',
    'minigame_reactions.reaction has a CHECK (NULL or six emojis, 204_minigame_pasar)');
SELECT has_column('minigame_reactions', 'last_tap_at',
    'minigame_reactions.last_tap_at drives the server reaction spam gate (207, 2026-09-09)');
SELECT ok(
    (SELECT convalidated
       FROM pg_constraint
      WHERE conrelid = 'minigame_reactions'::regclass
        AND conname = 'mgs_reaction_value_check') = true,
    'mgs_reaction_value_check is validated (204_minigame_pasar)'
);
SELECT ok(
    (SELECT pg_get_constraintdef(oid) LIKE '%reaction IS NULL%'
       AND pg_get_constraintdef(oid) LIKE '%''disgust''%'
       AND pg_get_constraintdef(oid) LIKE '%''heart''%'
     FROM pg_constraint
     WHERE conrelid = 'minigame_reactions'::regclass
       AND conname = 'mgs_reaction_value_check'),
    'mgs_reaction_value_check allows NULL + the six emoji wire values (204_minigame_pasar)'
);

-- submit_minigame_reaction accepts 'pasar' and stores a NULL-reaction row.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''pasar''%'
       AND pg_get_functiondef(p.oid) LIKE '%NULLIF(p_reaction, ''pasar'')%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction accepts ''pasar'' and stores a NULL pass marker (204_minigame_pasar)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''pass''%'
       AND pg_get_functiondef(p.oid) LIKE '%r.reaction IS NULL%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction mirrors a ''pass'' count (reaction IS NULL) into state.reactions (204_minigame_pasar)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''pass''%'
       AND pg_get_functiondef(p.oid) LIKE '%r.reaction IS NULL%'
     FROM pg_proc p WHERE proname = 'react_minigame_round'),
    'react_minigame_round mirrors a ''pass'' count (async reactable rounds, 204_minigame_pasar)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''pasar''%'
       AND pg_get_functiondef(p.oid) LIKE '%NULLIF(p_reaction, ''pasar'')%'
     FROM pg_proc p WHERE proname = 'react_minigame_round'),
    'react_minigame_round accepts ''pasar'' (async reactable rounds, 204_minigame_pasar)'
);

-- The scoring math: emoji_count - pass_count/2, integer-normalized when
-- integral, with the -1 no-reactions penalty retained.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%FILTER (WHERE reaction IS NULL)%'
       AND pg_get_functiondef(p.oid) LIKE '%pass_count::numeric / 2%'
       AND pg_get_functiondef(p.oid) LIKE '%trunc(v_score)%'
     FROM pg_proc p WHERE proname = '_minigame_advance_round'),
    '_minigame_advance_round scores emoji_count - pass_count/2 (integer-normalized, 204_minigame_pasar)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%v_reaction_count = 0%'
       AND pg_get_functiondef(p.oid) LIKE '%v_score := -1%'
     FROM pg_proc p WHERE proname = '_minigame_advance_round'),
    '_minigame_advance_round keeps the -1 no-reactions penalty (204_minigame_pasar)'
);

-- finish_minigame_game settles fractional scores (numeric, not ::int).
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%(rr ->> ''score'')::numeric%'
     FROM pg_proc p WHERE proname = 'finish_minigame_game'),
    'finish_minigame_game reads by_turns round scores as numeric (fractional allowed, 204_minigame_pasar)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%pass_count%'
       OR pg_get_functiondef(p.oid) LIKE '%r.reaction IS NULL%'
     FROM pg_proc p WHERE proname = 'finish_minigame_game'),
    'finish_minigame_game async settlement accounts for reactor passers (204_minigame_pasar)'
);

-- ======================================================================
-- SECTION 49q: round-key request ring (migration 206_minigame_key_request,
-- 2026-09-03) — a participant whose device-local E2EE state was WIPED
-- (reinstall / data clear regenerated the identity) flags itself in
-- `state.key_requests` (jsonb uuid[] INSIDE the game-state payload), and ANY
-- other participant who still holds the key history re-wraps `K_0..K_<latest>`
-- to its CURRENT identity via the existing bundle seam, then clears the flag.
-- The server only brokers the marker — it never sees a round key.
--   * request_minigame_round_keys(uuid) — participant-only, active session;
--     appends the caller to state.key_requests (dedup).
--   * resolve_minigame_key_request(uuid, uuid) — participant-only, never
--     self-clear; removes p_requester from state.key_requests (idempotent).
-- ======================================================================
SELECT has_function('request_minigame_round_keys', ARRAY['uuid'],
    'request_minigame_round_keys(p_session_id uuid) exists (206_minigame_key_request)');
SELECT is_definer('public', 'request_minigame_round_keys', ARRAY['uuid']::name[],
    'request_minigame_round_keys is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'request_minigame_round_keys'),
    'request_minigame_round_keys sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'request_minigame_round_keys', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'request_minigame_round_keys is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'request_minigame_round_keys', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'request_minigame_round_keys is authenticated-EXECUTABLE');
SELECT has_function('resolve_minigame_key_request', ARRAY['uuid', 'uuid'],
    'resolve_minigame_key_request(p_session_id uuid, p_requester uuid) exists (206_minigame_key_request)');
SELECT is_definer('public', 'resolve_minigame_key_request', ARRAY['uuid', 'uuid']::name[],
    'resolve_minigame_key_request is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'resolve_minigame_key_request'),
    'resolve_minigame_key_request sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'resolve_minigame_key_request', ARRAY['uuid', 'uuid']::name[], 'public', ARRAY[]::name[],
    'resolve_minigame_key_request is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'resolve_minigame_key_request', ARRAY['uuid', 'uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'resolve_minigame_key_request is authenticated-EXECUTABLE');

-- The request RPC appends to the state payload's key_requests marker and is
-- participant-only on the WRITE path (an invitee / group member never flags).
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%key_requests%'
       AND pg_get_functiondef(p.oid) LIKE '%auth.uid() = ANY (v_participants)%'
       AND pg_get_functiondef(p.oid) LIKE '%''not_allowed''%'
     FROM pg_proc p WHERE proname = 'request_minigame_round_keys'),
    'request_minigame_round_keys appends to state.key_requests with a participant-only gate (206)'
);
-- The resolve RPC never lets a requester clear its own flag and removes only
-- the served peer from the marker (idempotent array rebuild).
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%self_resolve%'
       AND pg_get_functiondef(p.oid) LIKE '%jsonb_array_elements%'
       AND pg_get_functiondef(p.oid) LIKE '%auth.uid() = p_requester%'
     FROM pg_proc p WHERE proname = 'resolve_minigame_key_request'),
    'resolve_minigame_key_request is never self-clearing and rebuilds the marker without the served peer (206)'
);

-- ======================================================================
-- SECTION 49p: decline-deletes + re-invite + roster realtime hardening
-- (2026-09-02 user directive).
--   * decline_minigame_invite DELETEs the invite row — a declined invite is
--     indistinguishable from one that never existed, so the (session_id,
--     invitee_id) UNIQUE is free for a fresh re-invite and
--     invite_minigame_players fires the INSERT-time notification unchanged.
--   * invite_minigame_players therefore needs NO re-open logic: a declined
--     (or kicked, row deleted by remove_minigame_participant) invitee is a
--     plain fresh INSERT on re-invite; only a still-PENDING row is skipped
--     idempotently (205 idempotency preserved).
--   * minigame_sessions carries REPLICA IDENTITY FULL so participant
--     join/remove UPDATE payloads ship the whole row — the roster diff has
--     the authoritative participants array even on a fresh match.
-- ======================================================================
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%DELETE FROM public.minigame_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%''declined''%'
       AND pg_get_functiondef(p.oid) LIKE '%invitee_id = v_current_user%'
     FROM pg_proc p WHERE proname = 'decline_minigame_invite'),
    'decline_minigame_invite deletes the row and stays invitee-only (49p)'
);
SELECT ok(
    (SELECT NOT pg_get_functiondef(p.oid) LIKE '%UPDATE public.minigame_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%DELETE FROM public.minigame_invites%'
     FROM pg_proc p WHERE proname = 'decline_minigame_invite'),
    'decline_minigame_invite never UPDATEs a row (only DELETE — no lingering declined state, 49p)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%t.v <> ALL (v_pending)%'
       AND pg_get_functiondef(p.oid) LIKE '%INSERT INTO public.minigame_invites%'
       AND NOT pg_get_functiondef(p.oid) LIKE '%ON CONFLICT%'
       AND NOT pg_get_functiondef(p.oid) LIKE '%UPDATE public.minigame_invites%'
     FROM pg_proc p WHERE proname = 'invite_minigame_players'),
    'invite_minigame_players stays pure-INSERT idempotent (skips only pending; a deleted row is re-insertable, 49p)'
);
SELECT ok(
    (SELECT relreplident = 'f' FROM pg_class WHERE oid = 'public.minigame_sessions'::regclass),
    'minigame_sessions has REPLICA IDENTITY FULL (realtime roster reliability, 49p)'
);

-- ======================================================================
-- SECTION 49r: per-tap reaction event (migration 207_minigame_reaction_event,
-- 2026-09-03) — a same-emoji RE-TAP leaves state.reactions byte-identical
-- (the upsert keeps created_at), so the realtime mirror cannot signal "tapped
-- again" on its own. Both reaction RPCs therefore bump a monotonic
-- state.reactions_seq and record the last tap as state.reactions_event
-- {seq, round, reaction, voter_id} in the SAME atomic UPDATE that rewrites
-- the mirror — every device gets the exact tapped emoji per tap even when the
-- tally content is unchanged. The seq is session-global (never reset on round
-- advance); a round change is carried by the event's own `round` field.
-- ======================================================================
-- submit_minigame_reaction (current by_turns round): writes the seq path.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''{reactions_seq}''%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction bumps state.reactions_seq (207_minigame_reaction_event)'
);
-- …and records reactions_event with a seq key.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''{reactions_event}''%'
       AND pg_get_functiondef(p.oid) LIKE '%''seq''%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction records state.reactions_event.seq (207_minigame_reaction_event)'
);
-- …and the event carries the tapped emoji + voter (NULL for a reactor Pasar).
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''voter_id''%'
       AND pg_get_functiondef(p.oid) LIKE '%NULLIF(p_reaction, ''pasar'')%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction records the tapped emoji + voter in reactions_event (NULL on Pasar, 207_minigame_reaction_event)'
);
-- The seq bumps monotonically on EVERY write (a same-emoji re-tap included):
-- the inline formula is (old seq) + 1 evaluated against the pre-UPDATE row.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%COALESCE((state ->> ''reactions_seq'')::bigint, 0)) + 1%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction increments reactions_seq monotonically on every write (207_minigame_reaction_event)'
);

-- react_minigame_round (async reactable round): the same seq + event writes.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''{reactions_seq}''%'
       AND pg_get_functiondef(p.oid) LIKE '%COALESCE((state ->> ''reactions_seq'')::bigint, 0)) + 1%'
     FROM pg_proc p WHERE proname = 'react_minigame_round'),
    'react_minigame_round bumps state.reactions_seq monotonically (async reactable rounds, 207_minigame_reaction_event)'
);
-- …records reactions_event carrying the TARGET round (p_round — the async
-- round may differ from the session''s current round).
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''{reactions_event}''%'
       AND pg_get_functiondef(p.oid) LIKE '%''round'', p_round%'
       AND pg_get_functiondef(p.oid) LIKE '%''voter_id''%'
     FROM pg_proc p WHERE proname = 'react_minigame_round'),
    'react_minigame_round records reactions_event with the target round + voter (207_minigame_reaction_event)'
);

-- _minigame_advance_round does NOT reset the sequence: it clears only the
-- round-scoped reactions/answer fields, leaving reactions_seq monotonic and
-- the last event in place (a stale round-N event is ignored client-side by
-- its own `round` field). Asserting the advance never touches the counter.
SELECT ok(
    (SELECT NOT pg_get_functiondef(p.oid) LIKE '%reactions_seq%'
     FROM pg_proc p WHERE proname = '_minigame_advance_round'),
    '_minigame_advance_round never resets reactions_seq (session-global counter, 207_minigame_reaction_event)'
);

-- The reaction RPC bodies keep their exact 204 gates (the 207 change is
-- additive — the seq/event fold into the existing mirror UPDATE). Spot-check
-- that submit_minigame_reaction still gates on the subject answer.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%answer_pending%'
       AND pg_get_functiondef(p.oid) LIKE '%own_round%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction keeps the 202 answer-first + own-round gates (207 is additive)'
);

-- Emoji ↔ Pasar exclusivity (2026-09-04, corrected 2026-09-09): once a voter
-- has acted they cannot switch to the OTHER mode. A Pasar row stores a NULL
-- reaction, so cross-mode is detected by ROW EXISTENCE — submit_minigame_reaction
-- rejects a Pasar when the voter already holds an EMOJI row (already_reacted)
-- and rejects an emoji when the voter holds a PASS row (reaction IS NULL,
-- already_passed); fresh voters and same-mode re-votes stay allowed. The
-- per-voter last_tap_at + 250 ms `too_fast` gate bounds spam server-side.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%already_reacted%'
       AND pg_get_functiondef(p.oid) LIKE '%already_passed%'
       AND pg_get_functiondef(p.oid) LIKE '%reaction IS NULL%'
       AND pg_get_functiondef(p.oid) LIKE '%reaction IS NOT NULL%'
       AND pg_get_functiondef(p.oid) LIKE '%too_fast%'
       AND pg_get_functiondef(p.oid) LIKE '%last_tap_at%'
       AND pg_get_functiondef(p.oid) LIKE '%p_reaction = ''pasar''%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction enforces emoji ↔ Pasar exclusivity by row existence + the 250 ms spam gate (207, fixed 2026-09-09)'
);
-- The mirror carries the per-voter action map (voter_id → emoji wire or null
-- for a pass) inside state.reactions.<subject>, so clients grey out the OTHER
-- mode once a voter has acted.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''voters''%'
       AND pg_get_functiondef(p.oid) LIKE '%jsonb_object_agg(r.voter_id::text, r.reaction)%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction mirrors the per-voter action map under state.reactions.<subject>.voters (207, 2026-09-04)'
);

-- react_minigame_round (async reactable round): the SAME corrected
-- row-existence exclusivity + spam gate + per-voter voters mirror.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%already_reacted%'
       AND pg_get_functiondef(p.oid) LIKE '%already_passed%'
       AND pg_get_functiondef(p.oid) LIKE '%reaction IS NULL%'
       AND pg_get_functiondef(p.oid) LIKE '%reaction IS NOT NULL%'
       AND pg_get_functiondef(p.oid) LIKE '%too_fast%'
       AND pg_get_functiondef(p.oid) LIKE '%last_tap_at%'
     FROM pg_proc p WHERE proname = 'react_minigame_round'),
    'react_minigame_round enforces emoji ↔ Pasar exclusivity by row existence + the 250 ms spam gate (async reactable rounds, 207, fixed 2026-09-09)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''voters''%'
       AND pg_get_functiondef(p.oid) LIKE '%jsonb_object_agg(r.voter_id::text, r.reaction)%'
     FROM pg_proc p WHERE proname = 'react_minigame_round'),
    'react_minigame_round mirrors the per-voter action map (async reactable rounds, 207, 2026-09-04)'
);
-- Emoji → emoji re-votes remain possible (the upsert replaces): assert the RPC
-- still upserts rather than rejecting a same-mode change.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%ON CONFLICT (session_id, round, voter_id) DO UPDATE%'
       AND pg_get_functiondef(p.oid) LIKE '%SET reaction = EXCLUDED.reaction%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction still allows emoji → emoji re-votes (upsert replaces, 207 exclusivity is cross-mode only)'
);

-- ======================================================================
-- SECTION 49s: Two Lies One Truth (migration 208_minigame_two_lies_one_truth)
-- ======================================================================
SELECT ok(
    (SELECT count(*) = 1 FROM pg_enum WHERE enumtypid = 'public.mini_game_type'::regtype AND enumlabel = 'two_lies_one_truth'),
    'mini_game_type enum contains two_lies_one_truth (208_minigame_two_lies_one_truth)'
);
SELECT ok(
    (SELECT pg_get_constraintdef(oid) LIKE '%vote_0%'
        AND pg_get_constraintdef(oid) LIKE '%vote_1%'
        AND pg_get_constraintdef(oid) LIKE '%vote_2%'
     FROM pg_constraint
     WHERE conrelid = 'minigame_reactions'::regclass
       AND conname = 'mgs_reaction_value_check'),
    'mgs_reaction_value_check allows vote_0, vote_1, vote_2 (208_minigame_two_lies_one_truth)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%vote_0%'
        AND pg_get_functiondef(p.oid) LIKE '%vote_1%'
        AND pg_get_functiondef(p.oid) LIKE '%vote_2%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction accepts vote_0..2 (208_minigame_two_lies_one_truth)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%vote_0%'
        AND pg_get_functiondef(p.oid) LIKE '%vote_1%'
        AND pg_get_functiondef(p.oid) LIKE '%vote_2%'
     FROM pg_proc p WHERE proname = 'react_minigame_round'),
    'react_minigame_round accepts vote_0..2 (208_minigame_two_lies_one_truth)'
);
SELECT ok(
    (SELECT count(*) >= 6 FROM public.minigame_prompts WHERE game_type = 'two_lies_one_truth'),
    'minigame_prompts has seeded topic prompts for two_lies_one_truth (208_minigame_two_lies_one_truth)'
);

-- ======================================================================
-- SECTION 49t: merged PR — extra games + code-only matches (2026-09-14):
--   209_minigame_drunk_bottle, 210_minigame_bottle_pizza,
--   211_minigame_public, 212_minigame_charades, 213_charades_no_repeats,
--   239_minigame_join_codes. The public-lobby surface (is_public /
--   ms_read_public / list_public_minigames / set_minigame_public) was
--   replaced by a hashed 6-character join code; the drunk-bottle and charades
--   game RPC families are kept.
-- ======================================================================
SELECT ok(
    (SELECT count(*) = 1 FROM pg_enum
      WHERE enumtypid = 'public.mini_game_type'::regtype AND enumlabel = 'charades'),
    'mini_game_type enum contains charades (212_minigame_charades)'
);

-- Drunk-bottle spin RPC family: DEFINER, search_path='', authenticated-only.
-- 209's `set_drunk_bottle_spin(uuid,boolean,uuid)` was DROPPED by
-- 210_minigame_bottle_pizza; the live family is spin/stop_drunk_bottle(uuid).
SELECT has_function('spin_drunk_bottle', ARRAY['uuid'],
    'spin_drunk_bottle(uuid) exists (210_minigame_bottle_pizza)');
SELECT has_function('stop_drunk_bottle', ARRAY['uuid'],
    'stop_drunk_bottle(uuid) exists (210_minigame_bottle_pizza)');
SELECT is_definer('public', 'spin_drunk_bottle', ARRAY['uuid']::name[],
    'spin_drunk_bottle is SECURITY DEFINER');
SELECT is_definer('public', 'stop_drunk_bottle', ARRAY['uuid']::name[],
    'stop_drunk_bottle is SECURITY DEFINER');
SELECT ok(
    (SELECT bool_and('search_path=""' = ANY (proconfig))
     FROM pg_proc WHERE proname IN ('spin_drunk_bottle', 'stop_drunk_bottle')),
    'spin/stop_drunk_bottle set search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'spin_drunk_bottle', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'spin_drunk_bottle is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'spin_drunk_bottle', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'spin_drunk_bottle is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'stop_drunk_bottle', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'stop_drunk_bottle is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'stop_drunk_bottle', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'stop_drunk_bottle is authenticated-EXECUTABLE');

-- Code-only public matches (239_minigame_join_codes): the open lobby and
-- publish toggle are gone; discovery is a hashed 6-character code.
SELECT has_column('minigame_sessions', 'join_code_hash',
    'E4: minigame_sessions stores only the join-code hash');
SELECT has_column('minigame_sessions', 'join_code_rotated_at',
    'E4: join codes record their rotation time');
SELECT ok(
    NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'minigame_sessions'
                   AND column_name = 'is_public'),
    'E4: the is_public publish flag is dropped');
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname = 'public' AND tablename = 'minigame_sessions'
                   AND policyname = 'ms_read_public'),
    'E4: the public-lobby read policy is dropped');
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'list_public_minigames'),
    'E4: the open-lobby list RPC is dropped');
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'set_minigame_public'),
    'E4: the publish toggle RPC is dropped');
SELECT has_function('set_minigame_join_code', ARRAY['uuid'],
    'E4: the host can set/rotate a join code');
SELECT has_function('revoke_minigame_join_code', ARRAY['uuid'],
    'E4: the host can revoke a join code');
SELECT has_function('join_minigame_by_code', ARRAY['text'],
    'E4: anyone signed in can join by code');
SELECT is_definer('public', 'join_minigame_by_code', ARRAY['text']::name[],
    'E4: join_minigame_by_code is SECURITY DEFINER');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%digest%'
        AND pg_get_functiondef(p.oid) LIKE '%invalid_code%'
      FROM pg_proc p WHERE proname = 'join_minigame_by_code'),
    'E4: joins compare the hash and hide invalid codes');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) NOT LIKE '%is_public%'
      FROM pg_proc p WHERE proname = 'join_minigame_session'),
    'E4: invite/participant joins no longer read is_public');

-- Charadas turn engine (212/213).
SELECT has_function('start_charades_turn', ARRAY['uuid','text','integer'],
    'start_charades_turn(uuid,text,int) exists (212_minigame_charades)');
SELECT has_function('charades_answer', ARRAY['uuid','boolean'],
    'charades_answer(uuid,boolean) exists (212_minigame_charades)');
SELECT has_function('end_charades_turn', ARRAY['uuid'],
    'end_charades_turn(uuid) exists (212_minigame_charades)');
SELECT ok(
    (SELECT count(*) > 0 FROM public.minigame_prompts WHERE game_type = 'charades'),
    'minigame_prompts has seeded charades words (212_minigame_charades)'
);

-- ============================================================
-- SECTION 62: get_minigame_invite_context (215_minigame_invite_context,
-- 2026-09-11) — the pending-invite lobby shows ONLY the inviter
-- ("INVITADO POR" + avatar), never the participant roster, so the invitee's
-- accept surface cannot flash the player list before accepting.
--   * SECURITY DEFINER + locked search_path + invitee-scoped
--     (`invitee_id = auth.uid()`); non-invitees get `invite_not_found`.
--   * Resolves the inviter through the security-barrier `user_search_view`
--     by `created_by`; the function never reads `participants` (no roster
--     leak by construction).
-- ======================================================================
SELECT has_function('get_minigame_invite_context', ARRAY['uuid'],
    'get_minigame_invite_context(uuid) exists (215_minigame_invite_context)');

SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%SECURITY DEFINER%'
       AND pg_get_functiondef(p.oid) LIKE '%SET search_path TO ''''%'
       AND pg_get_functiondef(p.oid) LIKE '%invitee_id = auth.uid()%'
       AND pg_get_functiondef(p.oid) LIKE '%invite_not_found%'
     FROM pg_proc p WHERE proname = 'get_minigame_invite_context'),
    'get_minigame_invite_context is SECURITY DEFINER, invitee-scoped, invite_not_found on miss (215)'
);

SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%user_search_view%'
       AND pg_get_functiondef(p.oid) LIKE '%created_by%'
       AND NOT pg_get_functiondef(p.oid) LIKE '%participants%'
     FROM pg_proc p WHERE proname = 'get_minigame_invite_context'),
    'get_minigame_invite_context resolves ONLY the inviter (never the participants roster, 215)'
);

SELECT ok(
    (SELECT NOT has_function_privilege('anon', p.oid, 'EXECUTE')
       AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
     FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'get_minigame_invite_context'),
    'get_minigame_invite_context is authenticated-only (PUBLIC/anon revoked, 215)'
);

-- ============================================================
-- SECTION 63: minigame group message + member fan-out
-- (216_minigame_group_message, 2026-09-15)
--   * 2a — create_minigame_session fans out an invite to EVERY active group
--     member (creator excluded) for a group session.
--   * 2b — a group session insert drops a notice via the
--     `minigame_group_messages` table (E2EE messages cannot carry it). The
--     table and its trigger are retained; the client read grant was revoked
--     with the chat surface (300_slim/05_revoke_removed.sql).
-- ============================================================
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%group_members%'
       AND pg_get_functiondef(p.oid) LIKE '%status = ''active''%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session fans out to every active group member (2a, 216)'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = 'minigame_sessions'
          AND t.tgname = 'minigame_group_message_trigger'
    ),
    'minigame_sessions has the group-message trigger (2b, 216)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%SECURITY DEFINER%'
       AND pg_get_functiondef(p.oid) LIKE '%minigame_group_messages%'
     FROM pg_proc p WHERE proname = 'notify_minigame_group_message'),
    'notify_minigame_group_message is SECURITY DEFINER and writes the notice (2b, 216)'
);
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM public.minigame_prompts
        WHERE game_type = 'drunk_bottle'
          AND (body ILIKE '%tomas%' OR body ILIKE '%toman%')
    ),
    'drinking dares rephrased out of the bottle bank (227)'
);

-- ============================================================
-- SECTION 66: Wave 0 trust boundary (229_wave0_trust_boundary)
-- Minimal invariants: the critical abuse paths are closed.
-- ============================================================
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.user_search_view', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.user_search_view', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.user_search_view', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.user_search_view', 'DELETE')
    AND NOT has_table_privilege('anon', 'public.user_search_view', 'SELECT'),
    'SEC-001/Q8 user_search_view is RPC-only (no client SELECT/enumeration)'
);
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.shard_ledger', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.preshard_ledger', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.group_shard_contributions', 'INSERT'),
    'SEC-002 clients cannot mint shard/group ledger rows'
);
SELECT ok(
    NOT has_function_privilege('authenticated', 'public.finish_minigame_game(uuid)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.abandon_minigame_game(uuid)', 'EXECUTE'),
    'SEC-004 settlement is server-only; abandonment is the client path'
);
SELECT ok(
    (SELECT pg_get_expr(polwithcheck, polrelid) FROM pg_policy
      WHERE polname = 'friendships_insert_own' AND polrelid = 'public.friendships'::regclass)
        LIKE '%pending%'
    AND (SELECT pg_get_expr(polwithcheck, polrelid) FROM pg_policy
          WHERE polname = 'friendships_insert_own' AND polrelid = 'public.friendships'::regclass)
        LIKE '%blocked%',
    'SEC-006 friendship insert cannot forge an accepted row'
);

-- ============================================================
-- SECTION 67: Wave 0 safety (230_wave0_safety)
-- ============================================================
SELECT has_function('is_active_user', ARRAY['uuid'],
    'SEC-008 is_active_user(uuid) exists');
SELECT ok(
    (SELECT prosecdef FROM pg_proc WHERE proname = 'is_active_user')
    AND has_function_privilege('authenticated', 'public.is_active_user(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.is_active_user(uuid)', 'EXECUTE'),
    'SEC-008 is_active_user is SECURITY DEFINER, authenticated-only'
);
SELECT has_function('moderate_report', ARRAY['uuid', 'text', 'uuid'],
    'SEC-009 moderate_report(uuid,text,uuid) exists');
SELECT has_table('moderation_evidence',
    'SEC-009 moderation_evidence table exists');
SELECT ok(
    (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='moderation_evidence') = 0
    AND EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        WHERE c.relname = 'device_tokens' AND t.tgname = 'active_actor_guard'
    ),
    'SEC-008/009 evidence is service-only and the kept write tables carry the active-actor guard'
);

-- ============================================================
-- SECTION 68: Wave 1 DB hardening (231_wave1_hardening)
-- ============================================================
SELECT ok(
    (SELECT pg_get_expr(polqual, polrelid) LIKE '%status = ''active''%'
     FROM pg_policy
      WHERE polname = 'groups_read_member'
        AND polrelid = 'public.groups'::regclass),
    'SEC-018 group read requires active membership (231)'
);
SELECT ok(
    (SELECT pg_get_expr(polqual, polrelid) LIKE '%status = ''active''%'
       AND pg_get_expr(polwithcheck, polrelid) LIKE '%status = ''active''%'
     FROM pg_policy
      WHERE polname = 'groups_update_host'
        AND polrelid = 'public.groups'::regclass),
    'SEC-018 group update requires active host/staff (231)'
);
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.deleted_messages', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.deleted_messages', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.deleted_messages', 'DELETE')
    AND NOT has_table_privilege('anon', 'public.deleted_messages', 'INSERT')
    AND has_table_privilege('service_role', 'public.deleted_messages', 'INSERT'),
    'SEC-015 deleted_messages direct client writes are revoked (231)'
);
SELECT ok(
    has_column_privilege('authenticated', 'public.notifications', 'read', 'UPDATE')
    AND NOT has_column_privilege('authenticated', 'public.notifications', 'title', 'UPDATE')
    AND NOT has_column_privilege('authenticated', 'public.notifications', 'push_sent_at', 'UPDATE'),
    'SEC-019 owners may update only notifications.read (231)'
);
SELECT ok(
    NOT has_column_privilege('anon', 'public.notifications', 'read', 'UPDATE')
    AND has_column_privilege('service_role', 'public.notifications', 'push_sent_at', 'UPDATE'),
    'SEC-019 anon cannot update notifications; push_sent_at stays service-only (231)'
);
SELECT ok(
    (SELECT count(*) = 2
     FROM pg_constraint
      WHERE conrelid = 'public.device_tokens'::regclass
        AND conname IN ('device_tokens_token_length', 'device_tokens_token_charset')),
    'SEC-020 device tokens carry length + charset constraints (231)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%token_owned_by_another_user%'
       AND pg_get_functiondef(p.oid) LIKE '%token_limit_reached%'
     FROM pg_proc p WHERE proname = 'register_device_token'),
    'SEC-020 token registration blocks re-homing and caps at 10 (231)'
);
SELECT ok(
    has_table_privilege('authenticated', 'public.device_tokens', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.device_tokens', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.device_tokens', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.device_tokens', 'DELETE'),
    'SEC-020 device tokens stay RPC-write-only (231)'
);
SELECT ok(
    (SELECT bool_and(allowed_mime_types @> ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]
                     AND NOT (allowed_mime_types && ARRAY['text/html', 'image/svg+xml']::text[])
                     AND file_size_limit IS NOT NULL)
     FROM storage.buckets
      WHERE id IN ('avatars', 'groups')),
    'SEC-030 image buckets allow only raster image MIME types with a size cap (231)'
);
SELECT ok(
    (SELECT allowed_mime_types = ARRAY['application/octet-stream']::text[]
            AND file_size_limit IS NOT NULL
     FROM storage.buckets
      WHERE id = 'minigame_images'),
    'SEC-030 minigame_images accepts only encrypted octets with a size cap (231)'
);

-- ============================================================
-- SECTION 68b: Identity, privacy and age assurance (233_identity_privacy)
--   Q17: DOB is now nullable for guest rows (300_slim); the 18+ trigger stays
--        for non-guest accounts.
--   Q8: private profiles exact-username only; no bio/avatar.
--   Q1: immediate hard delete, pseudonymized ledger retention, restricted
--       report evidence, no restore path, complete export.
-- ============================================================

-- 62a: Q17 — the former NOT NULL DOB contract was relaxed for guest rows by
-- 300_slim/01_onboarding.sql.
SELECT ok(
    (SELECT is_nullable = 'YES' FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'users'
        AND column_name = 'date_of_birth'),
    'Q17 users.date_of_birth is nullable so guest rows can omit DOB (300_slim)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%is_guest%'
       AND pg_get_functiondef(p.oid) LIKE '%La fecha de nacimiento es obligatoria.%'
     FROM pg_proc p WHERE proname = 'assert_adult_dob'),
    'Q17 assert_adult_dob still requires a DOB for non-guest rows (300_slim)'
);
SELECT has_column('users', 'date_of_birth_backfilled',
    'Q17 users.date_of_birth_backfilled exists');
SELECT col_not_null('users', 'date_of_birth_backfilled',
    'Q17 date_of_birth_backfilled is NOT NULL');
SELECT has_trigger('users', 'users_adult_dob_trigger',
    'Q17 adult-DOB trigger exists on users');
SELECT has_function('assert_adult_dob', ARRAY[]::name[],
    'Q17 assert_adult_dob() exists');
SELECT ok(
    (SELECT pg_get_constraintdef(oid) LIKE '%1900-01-01%'
       FROM pg_constraint
      WHERE conrelid = 'public.users'::regclass
        AND conname = 'users_date_of_birth_range'),
    'Q17 users_date_of_birth_range CHECK exists'
);

-- 62b: Q8
SELECT columns_are('user_search_view',
    ARRAY['id', 'username', 'avatar_url', 'bio', 'profile_public'],
    'Q8 user_search_view exposes profile_public for the server-side filter');
SELECT has_function('get_public_profiles', ARRAY['uuid[]'],
    'Q8 get_public_profiles(uuid[]) exists');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%NOT usv.profile_public%'
            AND pg_get_functiondef(p.oid) LIKE '%lower(usv.username) = lower(v_trimmed)%'
       FROM pg_proc p WHERE proname = 'search_users'),
    'Q8 search_users uses exact username for private rows'
);

-- 62c: Q1 schema + RPC shape
SELECT hasnt_function('restore_my_account',
    'Q1 restore_my_account is removed (no 30-day restore)');
SELECT hasnt_function('account_deletion_grace_days',
    'Q1 grace-period helper is removed');
SELECT has_table('retention_matrix',
    'Q1 retention_matrix exists');
SELECT has_table('account_deletion_audit',
    'Q1/SEC-049 account_deletion_audit exists');
SELECT has_table('auth_cleanup_queue',
    'Q1/SEC-049 auth_cleanup_queue exists');
SELECT has_column('reports', 'reporter_pseudonym',
    'Q1 reports.reporter_pseudonym exists');
SELECT has_column('reports', 'retention_until',
    'Q1 reports.retention_until exists');
-- 62e: Q1 hard delete keeps only pseudonymized facts / restricted evidence
SELECT lives_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('62626262-6262-4262-8262-626262626210', 'pgtapowner',
         DATE '1990-09-01'),
        ('62626262-6262-4262-8262-626262626211', 'pgtapdeleted',
         DATE '1990-09-02')$$,
    'Q1 deletion fixtures inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.shard_ledger (user_id, delta, reason) VALUES
        ('62626262-6262-4262-8262-626262626211', 7, 'admin_grant')$$,
    'Q1 ledger fixture inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.reports (reporter_id, target_type, target_id, reason)
      VALUES ('62626262-6262-4262-8262-626262626211', 'user',
              '62626262-6262-4262-8262-626262626210', 'pgtap evidence')$$,
    'Q1 report evidence fixture inserted'
);
SELECT set_config('request.jwt.claims',
    '{"sub":"62626262-6262-4262-8262-626262626211","role":"authenticated"}', false);
SELECT lives_ok($$SELECT public.delete_my_account()$$,
    'Q1 delete_my_account purges immediately');
SELECT set_config('request.jwt.claims', '', false);
SELECT is(
    (SELECT count(*) FROM public.users
      WHERE id = '62626262-6262-4262-8262-626262626211'),
    0::bigint,
    'Q1 users row is hard-deleted'
);
SELECT is(
    (SELECT count(*) FROM public.reports
      WHERE target_id = '62626262-6262-4262-8262-626262626210'
        AND reporter_id IS NULL
        AND reporter_pseudonym LIKE 'deleted:%'),
    1::bigint,
    'Q1 report evidence survives with a pseudonym'
);
SELECT ok(
    (SELECT user_id IS NULL AND retention_until > now()
       FROM public.shard_ledger
      WHERE id IN (SELECT id FROM public.shard_ledger
                    WHERE pseudonymized_at IS NOT NULL)
      ORDER BY id DESC LIMIT 1),
    'Q1 ledger retained pseudonymized with a 5-year clock'
);
-- 62f: SEC-050 export completeness
SELECT lives_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('62626262-6262-4262-8262-626262626240', 'pgtapexporter',
         DATE '1990-10-01'),
        ('62626262-6262-4262-8262-626262626241', 'pgtapsender',
         DATE '1990-10-02')$$,
    'SEC-050 export fixtures inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.device_tokens (user_id, token, platform) VALUES
        ('62626262-6262-4262-8262-626262626240',
         'pgtap_device_token_1234567890', 'ios')$$,
    'SEC-050 device token inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.minigame_sessions
        (id, game_type, status, shard_wager, player_limit, participants)
      VALUES ('62626262-6262-4262-8262-626262626260',
              'two_lies_one_truth', 'active', 0, 8,
              ARRAY['62626262-6262-4262-8262-626262626240',
                    '62626262-6262-4262-8262-626262626241']::uuid[])$$,
    'SEC-050 minigame session inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.minigame_answers
        (session_id, round, subject_id, prompt_type, answer_ciphertext)
      VALUES ('62626262-6262-4262-8262-626262626260', 1,
              '62626262-6262-4262-8262-626262626240',
              'text', 'ciphertext-answer')$$,
    'SEC-050 minigame answer inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.reports (reporter_id, target_type, target_id, reason)
      VALUES ('62626262-6262-4262-8262-626262626240', 'user',
              '62626262-6262-4262-8262-626262626241', 'export evidence')$$,
    'SEC-050 report fixture inserted'
);
SELECT set_config('request.jwt.claims',
    '{"sub":"62626262-6262-4262-8262-626262626240","role":"authenticated"}', false);
SELECT ok(jsonb_exists(public.export_my_data(), 'minigame_answers'),
    'SEC-050 export includes minigame answers');
SELECT ok(jsonb_exists(public.export_my_data(), 'device_tokens'),
    'SEC-050 export includes device tokens');
SELECT ok(jsonb_exists(public.export_my_data(), 'reports'),
    'SEC-050 export includes submitted reports');
SELECT ok(jsonb_exists(public.export_my_data(), 'exclusions'),
    'SEC-050 export discloses its exclusions');
SELECT ok(jsonb_exists(public.export_my_data(), 'retention'),
    'Q1 export carries the retention matrix');
SELECT is(public.export_my_data() ->> 'schema', 'samay.export.v2',
    'SEC-050 export schema is v2');
SELECT set_config('request.jwt.claims', '', true);

-- ============================================================
-- SECTION 69: safety, moderation, block/mute, notifications
-- (234_safety_moderation)
-- ============================================================
SELECT ok(
    (SELECT public.normalize_notification_preferences('{}'::jsonb) -> 'marketing')::text = 'false'
    AND (SELECT public.normalize_notification_preferences('{}'::jsonb) -> 'chat')::text = 'true'
    AND (SELECT public.normalize_notification_preferences('{}'::jsonb) -> 'security')::text = 'true',
    'Q4a defaults: chat on, marketing off, security locked on'
);
SELECT ok(
    (SELECT public.normalize_notification_preferences(
        '{"marketing": true, "security": false}'::jsonb
    ) -> 'marketing')::text = 'true'
    AND (SELECT public.normalize_notification_preferences(
        '{"marketing": true, "security": false}'::jsonb
    ) -> 'security')::text = 'true',
    'Q4a locked categories cannot be disabled; marketing can be enabled'
);
SELECT ok(
    public.notification_category('new_message') = 'chat'
    AND public.notification_category('event_invite') = 'events'
    AND public.notification_category('friend_request') = 'friends'
    AND public.notification_category('minigame_invite') = 'minigames'
    AND public.notification_category('marketing_offer') = 'marketing'
    AND public.notification_category('report_outcome') = 'moderation',
    'Q4a notification_category maps every shipped type'
);
SELECT has_function('get_notification_preferences', ARRAY[]::text[],
    'get_notification_preferences() exists');
SELECT has_function('set_notification_preferences', ARRAY['jsonb'],
    'set_notification_preferences(jsonb) exists');
SELECT ok(
    has_function_privilege('authenticated', 'public.get_notification_preferences()', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.set_notification_preferences(jsonb)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.get_notification_preferences()', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.set_notification_preferences(jsonb)', 'EXECUTE'),
    'Q4a prefs RPCs are authenticated-only'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'notifications'
           AND column_name = 'push_allowed'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'notifications'
           AND column_name = 'category'
    ),
    'Q4a push filtering contract columns exist (category, push_allowed)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%notification_enabled%'
       AND pg_get_functiondef(p.oid) LIKE '%is_blocked_between%'
     FROM pg_proc p WHERE proname = 'insert_notification'),
    'Q4a/Q4b insert_notification enforces prefs + block/mute'
);
SELECT has_trigger('public', 'group_members', 'notify_group_invite_trigger',
    'Q4a group-invite notification trigger exists');
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_enum e
        JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'report_target_type'
          AND e.enumlabel IN ('minigame_answer', 'minigame_image', 'avatar',
                              'group_cover', 'event_description')
        GROUP BY t.typname HAVING count(*) = 5
    ),
    'Q6 new report targets exist (minigame answer/image, avatar, group cover, event description)'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_enum e
        JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'report_category'
          AND e.enumlabel IN ('csam', 'credible_threat', 'ncii', 'harassment',
                              'hate', 'spam', 'impersonation', 'other')
        GROUP BY t.typname HAVING count(*) = 8
    ),
    'Q6 report categories exist'
);
SELECT ok(
    public.report_category_priority('csam') = 0
    AND public.report_category_priority('credible_threat') = 1
    AND public.report_category_priority('ncii') = 2
    AND public.report_category_priority('other') = 100,
    'Q6 immediate categories carry the highest priority'
);
SELECT has_function('report_content', ARRAY['text', 'uuid', 'text', 'text', 'jsonb'],
    'Q6 report_content(text,uuid,text,text,jsonb) exists');
SELECT has_function('submit_appeal', ARRAY['uuid', 'text'],
    'Q6 submit_appeal(uuid,text) exists');
SELECT has_function('decide_appeal', ARRAY['uuid', 'text', 'text', 'uuid'],
    'Q6 decide_appeal(uuid,text,text,uuid) exists');
SELECT has_function('block_user', ARRAY['uuid'], 'Q4b block_user(uuid) exists');
SELECT has_function('unblock_user', ARRAY['uuid'], 'Q4b unblock_user(uuid) exists');
SELECT has_function('mute_user', ARRAY['uuid'], 'Q4b mute_user(uuid) exists');
SELECT has_function('unmute_user', ARRAY['uuid'], 'Q4b unmute_user(uuid) exists');
SELECT has_table('user_mutes', 'Q4b user_mutes table exists');
SELECT ok(
    has_function_privilege('authenticated', 'public.report_content(text,uuid,text,text,jsonb)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.report_content(text,uuid,text,text,jsonb)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.moderate_report(uuid,text,uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.decide_appeal(uuid,text,text,uuid)', 'EXECUTE'),
    'Q6 report intake is authenticated-only; moderation/appeals are service-only'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%not_allowed%'
       AND pg_get_functiondef(p.oid) LIKE '%moderation_evidence%'
     FROM pg_proc p WHERE proname = 'report_content'),
    'Q6 report_content validates participation and snapshots evidence at report time'
);
SELECT ok(
    (SELECT count(*) = 1
     FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'appeals'
        AND policyname = 'appeals_read_own'),
    'Q6 appeals are readable only by the appellant'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
        WHERE c.relname = 'friendships'
          AND t.tgname IN ('friendships_block_owner_update', 'friendships_block_owner_delete')
        GROUP BY c.relname HAVING count(*) = 2
    ),
    'Q4b block rows are immutable except to the blocker'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
        WHERE c.relname = 'group_members'
          AND t.tgname = 'group_members_no_blocked_trigger'
    ),
    'Q4b blocked pairs cannot create new group invites'
);
SELECT ok(
    NOT (SELECT attnotnull FROM pg_attribute
          WHERE attrelid = 'public.reports'::regclass AND attname = 'reporter_id'),
    'Q6 reports survive reporter erasure (reporter_id nullable)'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_indexes
         WHERE schemaname = 'public' AND indexname = 'idx_reports_queue'
    ),
    'Q6 priority-ordered report processing queue index exists'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'moderation_evidence'
           AND column_name = 'retention_until'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'moderation_evidence'
           AND column_name = 'legal_hold'
    ),
    'Q6 evidence carries retention + legal-hold columns'
);

-- ============================================================
-- SECTION 72: subscriptions — expiry, grace, overrides, retries
-- (237_subscription_expiry — E2)
-- ============================================================
INSERT INTO public.users (id, username, date_of_birth) VALUES
    ('8b000000-0000-4000-8000-000000000001', 'sub_active', '1990-01-01'),
    ('8b000000-0000-4000-8000-000000000002', 'sub_null', '1990-01-01'),
    ('8b000000-0000-4000-8000-000000000003', 'sub_expired', '1990-01-01'),
    ('8b000000-0000-4000-8000-000000000004', 'sub_grace', '1990-01-01')
ON CONFLICT (id) DO NOTHING;

-- A) Active grant.
SELECT public.apply_subscription_state(
    '8b000000-0000-4000-8000-000000000001', 'pro',
    now() + interval '30 days', 'INITIAL_PURCHASE');
SELECT ok(public.has_paid_access('8b000000-0000-4000-8000-000000000001'),
    'E2: an active paid row has paid access');
SELECT is(
    (SELECT subscription_source FROM public.users WHERE id = '8b000000-0000-4000-8000-000000000001'),
    'revenuecat', 'E2: a RevenueCat grant records its source');
SELECT ok(
    (SELECT subscription_expires_at <= now() + interval '1 year 1 minute'
       FROM public.users WHERE id = '8b000000-0000-4000-8000-000000000001'),
    'E2: an over-1-year grant is capped');

-- B) Past expiry is rejected.
SELECT throws_ok(
    $$SELECT public.apply_subscription_state(
        '8b000000-0000-4000-8000-000000000001', 'pro',
        now() - interval '1 day', 'RENEWAL')$$,
    'P0001', 'invalid_expiry', 'E2: a past expiry cannot grant paid');

-- C) NULL expiry never grants paid; auto-downgrade + audit.
UPDATE public.users SET subscription_tier = 'vip', subscription_expires_at = NULL,
    subscription_source = 'revenuecat'
 WHERE id = '8b000000-0000-4000-8000-000000000002';
SELECT is(public.has_paid_access('8b000000-0000-4000-8000-000000000002'),
    false, 'E2: a NULL expiry is never paid');
SELECT is(public.effective_tier('8b000000-0000-4000-8000-000000000002'),
    'free'::public.subscription_tier, 'E2: effective_tier folds NULL expiry to free');
SELECT ok(public.downgrade_invalid_subscriptions() >= 1,
    'E2: the downgrade sweep finds the invalid row');
SELECT is(
    (SELECT subscription_tier FROM public.users WHERE id = '8b000000-0000-4000-8000-000000000002'),
    'free'::public.subscription_tier, 'E2: the NULL-expiry row is downgraded');
SELECT is(
    (SELECT count(*) FROM public.admin_audit_log
      WHERE action = 'subscription_auto_downgrade'
        AND target_id = '8b000000-0000-4000-8000-000000000002'),
    1::bigint, 'E2: the auto-downgrade is audited');

-- D) Normal expiry keeps a 24h action grace, then downgrades.
UPDATE public.users SET subscription_tier = 'pro',
    subscription_expires_at = now() - interval '1 hour',
    subscription_source = 'revenuecat'
 WHERE id = '8b000000-0000-4000-8000-000000000003';
SELECT is(public.has_paid_access('8b000000-0000-4000-8000-000000000003'),
    true, 'E2: paid actions survive 1 hour past expiry (24h grace)');
SELECT public.downgrade_invalid_subscriptions();
SELECT is(
    (SELECT subscription_tier FROM public.users WHERE id = '8b000000-0000-4000-8000-000000000003'),
    'pro'::public.subscription_tier, 'E2: the grace window is not downgraded');
UPDATE public.users SET subscription_expires_at = now() - interval '25 hours'
 WHERE id = '8b000000-0000-4000-8000-000000000003';
SELECT is(public.has_paid_access('8b000000-0000-4000-8000-000000000003'),
    false, 'E2: access stops after the 24h grace');
SELECT public.downgrade_invalid_subscriptions();
SELECT is(
    (SELECT subscription_tier FROM public.users WHERE id = '8b000000-0000-4000-8000-000000000003'),
    'free'::public.subscription_tier, 'E2: the expired row is downgraded');

-- E) PAUSED/BILLING_ISSUE extends access 7 days past the event.
UPDATE public.users SET subscription_tier = 'pro',
    subscription_expires_at = now() - interval '10 days',
    subscription_source = 'revenuecat'
 WHERE id = '8b000000-0000-4000-8000-000000000004';
SELECT public.apply_subscription_grace(
    '8b000000-0000-4000-8000-000000000004', 'BILLING_ISSUE', now());
SELECT is(public.has_paid_access('8b000000-0000-4000-8000-000000000004'),
    true, 'E2: billing issue keeps paid actions');
SELECT ok(
    (SELECT subscription_grace_until >= now() + interval '7 days' - interval '1 minute'
       FROM public.users WHERE id = '8b000000-0000-4000-8000-000000000004'),
    'E2: grace runs at least 7 days past the event');
SELECT is(public.effective_tier('8b000000-0000-4000-8000-000000000004'),
    'pro'::public.subscription_tier, 'E2: effective_tier keeps the tier during grace');

-- F) Admin overrides: reason, 1-year cap, audit.
SELECT throws_ok(
    $$SELECT public.admin_grant_subscription(
        '8b000000-0000-4000-8000-000000000004', 'vip',
        now() + interval '30 days', '')$$,
    'P0001', 'reason_required', 'E2: an override requires a reason');
SELECT throws_ok(
    $$SELECT public.admin_grant_subscription(
        '8b000000-0000-4000-8000-000000000004', 'vip',
        now() - interval '1 day', 'test')$$,
    'P0001', 'invalid_expiry', 'E2: an override rejects a past expiry');
SELECT public.admin_grant_subscription(
    '8b000000-0000-4000-8000-000000000004', 'vip',
    now() + interval '2 years', 'e2 test grant');
SELECT ok(
    (SELECT max(expires_at) <= now() + interval '1 year 1 minute'
       FROM public.subscription_overrides
      WHERE user_id = '8b000000-0000-4000-8000-000000000004'),
    'E2: an override is capped at 1 year');
SELECT is(
    (SELECT subscription_source FROM public.users WHERE id = '8b000000-0000-4000-8000-000000000004'),
    'admin', 'E2: an override marks the admin source');
SELECT is(
    (SELECT count(*) FROM public.subscription_overrides
      WHERE user_id = '8b000000-0000-4000-8000-000000000004' AND revoked = false),
    1::bigint, 'E2: the override row exists');

-- G) SOVR: RevenueCat wins; the override returns when RC lapses.
SELECT public.apply_subscription_state(
    '8b000000-0000-4000-8000-000000000004', 'pro',
    now() + interval '30 days', 'RENEWAL');
SELECT public.reconcile_subscription_overrides();
SELECT is(
    (SELECT subscription_tier FROM public.users WHERE id = '8b000000-0000-4000-8000-000000000004'),
    'pro'::public.subscription_tier, 'E2: an active RevenueCat grant wins over the override');
SELECT public.apply_subscription_state(
    '8b000000-0000-4000-8000-000000000004', 'free', NULL, 'EXPIRATION');
SELECT public.reconcile_subscription_overrides();
SELECT is(
    (SELECT subscription_tier FROM public.users WHERE id = '8b000000-0000-4000-8000-000000000004'),
    'vip'::public.subscription_tier, 'E2: the active override returns after RC lapses');

-- H) Revoke.
SELECT public.admin_revoke_subscription(
    '8b000000-0000-4000-8000-000000000004', 'e2 test revoke');
SELECT is(
    (SELECT subscription_tier FROM public.users WHERE id = '8b000000-0000-4000-8000-000000000004'),
    'free'::public.subscription_tier, 'E2: revoking the override downgrades an admin row');
SELECT is(
    (SELECT count(*) FROM public.subscription_overrides
      WHERE user_id = '8b000000-0000-4000-8000-000000000004' AND revoked = false),
    0::bigint, 'E2: revoke flips every active override');
SELECT is(
    (SELECT count(*) FROM public.admin_audit_log
      WHERE action = 'subscription_override_revoke'
        AND target_id = '8b000000-0000-4000-8000-000000000004'),
    1::bigint, 'E2: the revoke is audited');

-- I) Immediate free (REFUND/chargeback path) clears grace.
SELECT public.apply_subscription_state(
    '8b000000-0000-4000-8000-000000000001', 'free', NULL, 'REFUND');
SELECT is(
    (SELECT subscription_source FROM public.users WHERE id = '8b000000-0000-4000-8000-000000000001'),
    'none', 'E2: an immediate downgrade clears the source');
SELECT is(public.has_paid_access('8b000000-0000-4000-8000-000000000001'),
    false, 'E2: an immediate downgrade bypasses grace');

-- J) Retry queue shape.
SELECT has_column('webhook_failures', 'next_attempt_at',
    'E2: webhook_failures carries the retry schedule');
SELECT has_column('webhook_failures', 'resolved_at',
    'E2: webhook_failures records resolution');

-- ============================================================
-- SECTION 73: limits + create_group (238_limits_contracts — E3)
-- (The rank-snapshot tier gating is removed with the rankings feature.)
-- ============================================================
INSERT INTO public.users (id, username, date_of_birth) VALUES
    ('9c000000-0000-4000-8000-000000000001', 'e3_free', '1990-01-01'),
    ('9c000000-0000-4000-8000-000000000002', 'e3_pro', '1990-01-01'),
    ('9c000000-0000-4000-8000-000000000003', 'e3_host', '1990-01-01')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.users (id, username, date_of_birth)
SELECT ('9c000000-0000-4000-8000-0000000001' || lpad(i::text, 2, '0'))::uuid,
       'e3_member_' || i, '1990-01-01'
  FROM generate_series(1, 14) AS i
ON CONFLICT (id) DO NOTHING;

SELECT is((SELECT value FROM public.app_config WHERE key = 'groups.free_hosted'),
    '5', 'E3: free hosted-group cap is 5');
SELECT is((SELECT value FROM public.app_config WHERE key = 'groups.free_max_members'),
    '14', 'E3: free group member cap is 14');
-- create_group: 5 hosted cap, transaction, host membership + chat.
SELECT set_config('request.jwt.claims',
    '{"sub":"9c000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
DO $$
DECLARE r jsonb;
BEGIN
    FOR i IN 1..5 LOOP
        r := public.create_group('e3 group ' || i);
    END LOOP;
END $$;
SELECT is(
    (SELECT count(*) FROM public.groups
      WHERE created_by_user_id = '9c000000-0000-4000-8000-000000000001'),
    5::bigint, 'E3: free creates 5 groups');
SELECT throws_ok(
    $$SELECT public.create_group('e3 group 6')$$,
    'P0001', 'group_hosted_limit', 'E3: the 6th free group is rejected');
SELECT is(
    (SELECT count(*) FROM public.group_members gm
       JOIN public.groups g ON g.id = gm.group_id
      WHERE g.created_by_user_id = '9c000000-0000-4000-8000-000000000001'
        AND gm.user_id = '9c000000-0000-4000-8000-000000000001'
        AND gm.role = 'host' AND gm.status = 'active'),
    5::bigint, 'E3: each group has its host membership');

-- Member cap (free host = 14 active).
SELECT set_config('request.jwt.claims',
    '{"sub":"9c000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
DO $$
DECLARE gid uuid;
BEGIN
    gid := (public.create_group('e3 member cap group') ->> 'id')::uuid;
    FOR i IN 1..13 LOOP
        INSERT INTO public.group_members (group_id, user_id, role, status)
        VALUES (gid,
                ('9c000000-0000-4000-8000-0000000001' || lpad(i::text, 2, '0'))::uuid,
                'member', 'active');
    END LOOP;
END $$;
SELECT is(
    (SELECT count(*) FROM public.group_members
      WHERE group_id = (SELECT id FROM public.groups WHERE name = 'e3 member cap group')
        AND status = 'active'),
    14::bigint, 'E3: a free group reaches 14 active members');
SELECT throws_ok(
    $$INSERT INTO public.group_members (group_id, user_id, role, status)
      VALUES ((SELECT id FROM public.groups WHERE name = 'e3 member cap group'),
              '9c000000-0000-4000-8000-000000000114', 'member', 'active')$$,
    'P0001', 'group_member_limit', 'E3: the 15th member is rejected');

-- Reports: 5/hour.
SELECT set_config('request.jwt.claims',
    '{"sub":"9c000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
INSERT INTO public.reports (reporter_id, target_type, target_id, reason)
SELECT '9c000000-0000-4000-8000-000000000001', 'user', gen_random_uuid(),
       'spam'
  FROM generate_series(1, 5);
SELECT is(
    (SELECT count(*) FROM public.reports
      WHERE reporter_id = '9c000000-0000-4000-8000-000000000001'),
    5::bigint, 'E3: five reports are accepted');
SELECT throws_ok(
    $$INSERT INTO public.reports (reporter_id, target_type, target_id, reason)
      VALUES ('9c000000-0000-4000-8000-000000000001', 'user',
              gen_random_uuid(), 'spam')$$,
    'P0001', 'rate_limited:report_hour', 'E3: the 6th report in an hour is rejected');

-- Device tokens: 5/user.
INSERT INTO public.device_tokens (user_id, token, platform)
SELECT '9c000000-0000-4000-8000-000000000001', repeat('e3token', 6) || i, 'android'
  FROM generate_series(1, 5) AS i;
SELECT is(
    (SELECT count(*) FROM public.device_tokens
      WHERE user_id = '9c000000-0000-4000-8000-000000000001'),
    5::bigint, 'E3: five device tokens are accepted');
SELECT throws_ok(
    $$INSERT INTO public.device_tokens (user_id, token, platform)
      VALUES ('9c000000-0000-4000-8000-000000000001', repeat('e3token', 6) || 6, 'android')$$,
    'P0001', 'device_token_limit', 'E3: the 6th device token is rejected');

-- Direct groups inserts are denied.
SET LOCAL role authenticated;
SELECT throws_ok(
    $$INSERT INTO public.groups (name, created_by_user_id)
      VALUES ('e3 direct', '9c000000-0000-4000-8000-000000000001')$$,
    '42501', NULL, 'E3: direct group inserts are denied');
RESET role;

-- ============================================================
-- SECTION 74: code-only matches (239_minigame_join_codes — E4)
-- ============================================================
INSERT INTO public.users (id, username, date_of_birth) VALUES
    ('9d000000-0000-4000-8000-000000000001', 'e4_host', '1990-01-01'),
    ('9d000000-0000-4000-8000-000000000002', 'e4_joiner', '1990-01-01'),
    ('9d000000-0000-4000-8000-000000000003', 'e4_late', '1990-01-01'),
    ('9d000000-0000-4000-8000-000000000004', 'e4_brute', '1990-01-01'),
    ('9d000000-0000-4000-8000-000000000005', 'e4_brute2', '1990-01-01')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.minigame_sessions
    (id, game_type, status, player_limit, participants)
VALUES ('9d000000-0000-4000-8000-000000000101', 'truth_dare', 'active', 4,
        ARRAY['9d000000-0000-4000-8000-000000000001']::uuid[]);

CREATE TEMP TABLE e4_code (code text);
SELECT set_config('request.jwt.claims',
    '{"sub":"9d000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
INSERT INTO e4_code
SELECT public.set_minigame_join_code('9d000000-0000-4000-8000-000000000101') ->> 'code';
SELECT ok((SELECT code ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$' FROM e4_code),
    'E4: the host receives a 6-character code from the allowed alphabet');

SELECT set_config('request.jwt.claims',
    '{"sub":"9d000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
SELECT is(
    (public.join_minigame_by_code('AAAA22') ->> 'status'),
    'invalid_code', 'E4: a wrong code is rejected without leaking a session');
SELECT is(
    (public.join_minigame_by_code((SELECT code FROM e4_code)) ->> 'status'),
    'joined', 'E4: the matching code joins the session');
SELECT ok(
    (SELECT '9d000000-0000-4000-8000-000000000002' = ANY (participants)
       FROM public.minigame_sessions
      WHERE id = '9d000000-0000-4000-8000-000000000101'),
    'E4: the joiner is appended to the participants');

-- Rotate invalidates the previous code.
SELECT set_config('request.jwt.claims',
    '{"sub":"9d000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
UPDATE e4_code
   SET code = public.set_minigame_join_code('9d000000-0000-4000-8000-000000000101') ->> 'code';
SELECT set_config('request.jwt.claims',
    '{"sub":"9d000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SELECT is(
    (public.join_minigame_by_code('AAAA22') ->> 'status'),
    'invalid_code', 'E4: rotating the code invalidates the old one');
SELECT is(
    (public.join_minigame_by_code((SELECT code FROM e4_code)) ->> 'status'),
    'joined', 'E4: the rotated code joins');

-- Revoke invalidates the code entirely.
SELECT set_config('request.jwt.claims',
    '{"sub":"9d000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
SELECT public.revoke_minigame_join_code('9d000000-0000-4000-8000-000000000101');
SELECT set_config('request.jwt.claims',
    '{"sub":"9d000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
SELECT is(
    (public.join_minigame_by_code((SELECT code FROM e4_code)) ->> 'status'),
    'invalid_code', 'E4: a revoked code cannot join');

-- Brute-force guard: 10 attempts/min/account (fresh user).
SELECT set_config('request.jwt.claims',
    '{"sub":"9d000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
DO $$
BEGIN
    FOR i IN 1..10 LOOP
        PERFORM public.join_minigame_by_code('ZZZZZ2');
    END LOOP;
END $$;
SELECT throws_ok(
    $$SELECT public.join_minigame_by_code('ZZZZZ2')$$,
    'P0001', 'rate_limited:minigame_code_join',
    'E4: the 11th code attempt in a minute is rejected');
SELECT set_config('request.jwt.claims', '', true);

-- ============================================================
-- SECTION 75: group theme — tier/control/contrast/RLS (240_group_theme — E4)
-- ============================================================
SELECT has_type('group_theme_mode');
SELECT has_table('group_themes');
SELECT has_table('group_theme_changes');
SELECT has_column('group_themes', 'control_mode');
SELECT has_column('group_themes', 'foreground_color');
SELECT has_function('set_group_theme', ARRAY['uuid', 'text', 'text', 'text']);
SELECT has_function('theme_contrast_ratio', ARRAY['text', 'text']);
SELECT policies_are('group_themes', ARRAY[
    'group_themes_read_member',
    'active_users_only'
], 'group_themes is member-read with no client write policy');
SELECT is(public.theme_best_foreground('#777777'), '#000000',
    'E4 theme: a mid-grey background picks the better (black) foreground');
SELECT ok(public.theme_contrast_ratio('#777777',
    public.theme_best_foreground('#777777')) >= 4.5,
    'E4 theme: the derived foreground meets WCAG AA (>= 4.5:1)');
SELECT is(public.theme_best_foreground(public.theme_clamp_dark('#FFFFFF')), '#FFFFFF',
    'E4 theme: a bright colour is auto-darkened so white text stays legible');
SELECT ok(public.theme_relative_luminance(public.theme_clamp_dark('#FFFFFF')) <= 0.12,
    'E4 theme: the clamped background sits at <= 0.12 relative luminance');
SELECT is((SELECT value FROM public.app_config WHERE key = 'theme.changes_per_minute'),
    '3', 'E4 theme: 3 changes/min/group');
SELECT is((SELECT value FROM public.app_config WHERE key = 'theme.changes_per_day'),
    '20', 'E4 theme: 20 changes/day/user');

INSERT INTO public.users (id, username, date_of_birth) VALUES
    ('9e000000-0000-4000-8000-000000000001', 'e4_theme_free', '1990-01-01'),
    ('9e000000-0000-4000-8000-000000000002', 'e4_theme_pro', '1990-01-01'),
    ('9e000000-0000-4000-8000-000000000003', 'e4_theme_member', '1990-01-01'),
    ('9e000000-0000-4000-8000-000000000004', 'e4_theme_out', '1990-01-01')
ON CONFLICT (id) DO NOTHING;
SELECT public.apply_subscription_state(
    '9e000000-0000-4000-8000-000000000002', 'pro',
    now() + interval '30 days', 'INITIAL_PURCHASE');
INSERT INTO public.groups (id, name, created_by_user_id) VALUES
    ('9e000000-0000-4000-8000-000000000101', 'e4 theme free',
     '9e000000-0000-4000-8000-000000000001'),
    ('9e000000-0000-4000-8000-000000000102', 'e4 theme pro',
     '9e000000-0000-4000-8000-000000000002'),
    ('9e000000-0000-4000-8000-000000000103', 'e4 theme rate',
     '9e000000-0000-4000-8000-000000000002'),
    ('9e000000-0000-4000-8000-000000000104', 'e4 theme lock',
     '9e000000-0000-4000-8000-000000000002');
INSERT INTO public.group_members (group_id, user_id, role, status) VALUES
    ('9e000000-0000-4000-8000-000000000101', '9e000000-0000-4000-8000-000000000001', 'host', 'active'),
    ('9e000000-0000-4000-8000-000000000102', '9e000000-0000-4000-8000-000000000002', 'host', 'active'),
    ('9e000000-0000-4000-8000-000000000102', '9e000000-0000-4000-8000-000000000003', 'member', 'active'),
    ('9e000000-0000-4000-8000-000000000103', '9e000000-0000-4000-8000-000000000002', 'host', 'active'),
    ('9e000000-0000-4000-8000-000000000104', '9e000000-0000-4000-8000-000000000002', 'host', 'active');

SELECT is((SELECT control_mode FROM public.group_themes
            WHERE group_id = '9e000000-0000-4000-8000-000000000101'),
    'locked'::public.group_theme_mode,
    'E4 theme: a free-hosted group defaults to locked');
SELECT is((SELECT control_mode FROM public.group_themes
            WHERE group_id = '9e000000-0000-4000-8000-000000000102'),
    'everyone'::public.group_theme_mode,
    'E4 theme: a paid-hosted group defaults to everyone');
SELECT is((SELECT background_color FROM public.group_themes
            WHERE group_id = '9e000000-0000-4000-8000-000000000101'),
    '#000000', 'E4 theme: the free palette is fixed black');

-- Non-member is rejected.
SELECT set_config('request.jwt.claims',
    '{"sub":"9e000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
SELECT throws_ok(
    $$SELECT public.set_group_theme('9e000000-0000-4000-8000-000000000102', '#1E3A8A')$$,
    'P0001', 'not_a_member', 'E4 theme: a non-member cannot set the theme');

-- A member changes the colour under `everyone` (default for a paid host).
SELECT set_config('request.jwt.claims',
    '{"sub":"9e000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SELECT is(
    (public.set_group_theme('9e000000-0000-4000-8000-000000000102', '#1e3a8a', '#facc15')
        ->> 'background_color'),
    '#1E3A8A', 'E4 theme: any member may change a paid group theme (normalized hex)');
SELECT is((SELECT foreground_color FROM public.group_themes
            WHERE group_id = '9e000000-0000-4000-8000-000000000102'),
    '#FFFFFF', 'E4 theme: the foreground is derived automatically');
SELECT is((SELECT accent_foreground_color FROM public.group_themes
            WHERE group_id = '9e000000-0000-4000-8000-000000000102'),
    '#000000', 'E4 theme: the accent foreground is derived automatically');
SELECT is((SELECT count(*) FROM public.group_theme_changes
            WHERE group_id = '9e000000-0000-4000-8000-000000000102'),
    1::bigint, 'E4 theme: the change is audited');
SELECT is((SELECT actor_id FROM public.group_theme_changes
            WHERE group_id = '9e000000-0000-4000-8000-000000000102'),
    '9e000000-0000-4000-8000-000000000003'::uuid,
    'E4 theme: the audit records the actor');
SELECT is((SELECT new_background_color FROM public.group_theme_changes
            WHERE group_id = '9e000000-0000-4000-8000-000000000102'),
    '#1E3A8A', 'E4 theme: the audit records the new colour');
SELECT is((SELECT old_control_mode FROM public.group_theme_changes
            WHERE group_id = '9e000000-0000-4000-8000-000000000102'),
    'everyone'::public.group_theme_mode,
    'E4 theme: the audit records the control mode');
SELECT is((public.get_group_theme('9e000000-0000-4000-8000-000000000102')
            ->> 'palette_tier'),
    'pro', 'E4 theme: the read RPC reports the host tier that gates the palette');
SELECT is((public.get_group_theme('9e000000-0000-4000-8000-000000000102')
            ->> 'can_change_color'),
    'true', 'E4 theme: a member may change colours under everyone');

-- Host switches to host_only.
SELECT set_config('request.jwt.claims',
    '{"sub":"9e000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
SELECT is(
    (public.set_group_theme('9e000000-0000-4000-8000-000000000102', NULL, NULL, 'host_only')
        ->> 'control_mode'),
    'host_only', 'E4 theme: the host may switch the control mode to host_only');
SELECT set_config('request.jwt.claims',
    '{"sub":"9e000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SELECT throws_ok(
    $$SELECT public.set_group_theme('9e000000-0000-4000-8000-000000000102', '#14532D')$$,
    'P0001', 'not_host', 'E4 theme: host_only rejects a member colour change');
SELECT set_config('request.jwt.claims',
    '{"sub":"9e000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
SELECT is(
    (public.set_group_theme('9e000000-0000-4000-8000-000000000102', '#14532D')
        ->> 'background_color'),
    '#14532D', 'E4 theme: host_only still lets the host change the colour');

-- Host locks the theme: nobody (the host included) changes colours until the
-- host reopens the control mode.
SELECT is(
    (public.set_group_theme('9e000000-0000-4000-8000-000000000104', NULL, NULL, 'locked')
        ->> 'control_mode'),
    'locked', 'E4 theme: the host may lock the theme');
SELECT throws_ok(
    $$SELECT public.set_group_theme('9e000000-0000-4000-8000-000000000104', '#4C1D95')$$,
    'P0001', 'theme_locked', 'E4 theme: locked rejects a colour change');

-- Free host: unlock is allowed, but the palette stays black.
SELECT set_config('request.jwt.claims',
    '{"sub":"9e000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
SELECT is(
    (public.set_group_theme('9e000000-0000-4000-8000-000000000101', NULL, NULL, 'everyone')
        ->> 'control_mode'),
    'everyone', 'E4 theme: a free host may change the control mode');
SELECT throws_ok(
    $$SELECT public.set_group_theme('9e000000-0000-4000-8000-000000000101', '#1E3A8A')$$,
    'P0001', 'theme_requires_paid', 'E4 theme: the free palette rejects RGB');
SELECT throws_ok(
    $$SELECT public.set_group_theme('9e000000-0000-4000-8000-000000000101', '#XYZ123')$$,
    'P0001', 'invalid_theme_color', 'E4 theme: malformed hex is rejected');
SELECT is(jsonb_array_length(
        public.get_group_theme('9e000000-0000-4000-8000-000000000101') -> 'palette'),
    1, 'E4 theme: a free host palette is black only');

-- Per-group rate limit: 3/min/group.
SELECT set_config('request.jwt.claims',
    '{"sub":"9e000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
SELECT is(
    (public.set_group_theme('9e000000-0000-4000-8000-000000000103', '#1E3A8A')
        ->> 'background_color'),
    '#1E3A8A', 'E4 theme: rate-limit group change 1');
SELECT is(
    (public.set_group_theme('9e000000-0000-4000-8000-000000000103', '#14532D')
        ->> 'background_color'),
    '#14532D', 'E4 theme: rate-limit group change 2');
SELECT is(
    (public.set_group_theme('9e000000-0000-4000-8000-000000000103', '#4C1D95')
        ->> 'background_color'),
    '#4C1D95', 'E4 theme: rate-limit group change 3');
SELECT throws_ok(
    $$SELECT public.set_group_theme('9e000000-0000-4000-8000-000000000103', '#991B1B')$$,
    'P0001', 'rate_limited:group_theme_group',
    'E4 theme: the 4th change in a minute is rejected');

-- RLS: members read their theme, outsiders read nothing, nobody writes direct.
SELECT set_config('request.jwt.claims',
    '{"sub":"9e000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
SET LOCAL role authenticated;
SELECT is((SELECT count(*) FROM public.group_themes
            WHERE group_id = ANY (ARRAY['9e000000-0000-4000-8000-000000000101',
                                        '9e000000-0000-4000-8000-000000000102',
                                        '9e000000-0000-4000-8000-000000000103']::uuid[])),
    0::bigint, 'E4 theme: a non-member sees no group theme');
RESET role;

SELECT set_config('request.jwt.claims',
    '{"sub":"9e000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL role authenticated;
SELECT is((SELECT count(*) FROM public.group_themes
            WHERE group_id = '9e000000-0000-4000-8000-000000000102'),
    1::bigint, 'E4 theme: an active member can read the theme');
SELECT throws_ok(
    $$INSERT INTO public.group_themes (group_id) VALUES ('9e000000-0000-4000-8000-000000000102')$$,
    '42501', NULL, 'E4 theme: direct client writes are denied');
RESET role;
SELECT set_config('request.jwt.claims', '', true);

SELECT * FROM finish();
ROLLBACK;