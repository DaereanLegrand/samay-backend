-- Vive! Schema pgTAP Tests
BEGIN;

SELECT plan(57);

-- Extensions
SELECT has_extension('pgcrypto');
SELECT has_extension('moddatetime');
SELECT has_extension('pg_cron');

-- Enum types (17)
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
-- 3+19 = 22 tests

-- Tables (30)
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
-- 22+30 = 52 tests

-- Triggers
SELECT has_trigger('users', 'users_updated_at');
SELECT has_trigger('groups', 'groups_updated_at');
SELECT has_trigger('events', 'events_updated_at');
-- 52+3 = 55 tests

-- Seed data
SELECT ok(
    (SELECT count(*) = 1 FROM admin_users),
    'admin_users has 1 seed row (system)'
);
SELECT ok(
    (SELECT count(*) = 37 FROM app_config),
    'app_config has 37 seed rows'
);
SELECT * FROM finish();
ROLLBACK;
