-- Samay Schema pgTAP Tests — Comprehensive
-- Covers all 16 migrations (20260510000001 through 20260520000001).
BEGIN;

SELECT plan(125);

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
-- SECTION 6: Migration 20260513000002 — signup_tracker table
-- ============================================================
SELECT has_table('signup_tracker');
SELECT has_column('signup_tracker', 'email');
SELECT has_column('signup_tracker', 'profile_created');
SELECT has_column('signup_tracker', 'created_at');
SELECT has_column('signup_tracker', 'updated_at');
SELECT col_is_pk('signup_tracker', 'email');

-- signup_tracker RLS is enabled (wide-open, accepted for MVP)
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'signup_tracker'::regclass),
    'signup_tracker has RLS enabled'
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
-- SECTION 10: RPC — donate_shards_to_group (migration 20260512000001)
-- ============================================================
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
-- SECTION 15: RLS Policies — signup_tracker (wide-open, accepted)
-- ============================================================
SELECT policies_are('signup_tracker', ARRAY[
    'Anyone can select signup_tracker',
    'Anyone can insert signup_tracker',
    'Anyone can update signup_tracker',
    'Anyone can delete signup_tracker'
], 'signup_tracker has 4 wide-open RLS policies');

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
-- ============================================================
SELECT policies_are('groups', ARRAY[
    'groups_read_member',
    'groups_read_own',
    'groups_update_promotor',
    'groups_insert_own'
], 'groups has expected RLS policies');

-- ============================================================
-- SECTION 18: RLS Policies — group_members (no recursion)
-- ============================================================
SELECT policies_are('group_members', ARRAY[
    'group_members_read_own',
    'group_members_insert_creator',
    'group_members_delete_own',
    'group_members_delete_promotor',
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
-- ============================================================
SELECT policies_are('chats', ARRAY[
    'chats_insert_related',
    'chats_read_participant'
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
-- ============================================================
SELECT ok(
    (SELECT count(*) = 1 FROM admin_users),
    'admin_users has 1 seed row (system admin)'
);
SELECT ok(
    (SELECT count(*) = 37 FROM app_config),
    'app_config has 37 seed rows'
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

SELECT * FROM finish();
ROLLBACK;
