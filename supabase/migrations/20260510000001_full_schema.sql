-- Samay — Full Database Schema
-- Migration 1 of 1: Extensions, Enums, Tables, Triggers, RLS, Cron, Seeds

-- ============================================================
-- 1. EXTENSIONS
-- ============================================================
CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS "moddatetime" WITH SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "extensions";

-- ============================================================
-- 2. ENUMS
-- ============================================================
CREATE TYPE subscription_tier AS ENUM ('free', 'pro', 'vip');
CREATE TYPE friendship_status AS ENUM ('pending', 'accepted', 'blocked');
CREATE TYPE group_role AS ENUM ('member', 'promotor', 'co_promotor');
CREATE TYPE size_tier AS ENUM ('micro', 'small', 'medium', 'large');
CREATE TYPE rank_bracket AS ENUM ('b0_20', 'b20_40', 'b40_60', 'b60_80', 'b80_90', 'b90_100');
CREATE TYPE event_type AS ENUM ('casual', 'juerga', 'tono');
CREATE TYPE event_status AS ENUM ('draft', 'upcoming', 'live', 'ended', 'cancelled');
CREATE TYPE join_mode AS ENUM ('open', 'approval');
CREATE TYPE event_role AS ENUM ('promotor', 'co_promotor');
CREATE TYPE invite_status AS ENUM ('pending', 'accepted', 'declined', 'attended');
CREATE TYPE cosmetic_type AS ENUM ('avatar_frame', 'profile_bg', 'badge', 'group_cover', 'group_badge');
CREATE TYPE chat_type AS ENUM ('event', 'group', 'direct');
CREATE TYPE mini_game_type AS ENUM ('poke_chain', 'questions', 'truth_dare', 'drunk_bottle', 'challenge');
CREATE TYPE mini_game_status AS ENUM ('active', 'finished');
CREATE TYPE shard_reason AS ENUM ('event_attendance', 'cosmetic_purchase', 'group_donation', 'minigame_wager', 'minigame_win', 'minigame_refund', 'subscription_grant', 'admin_grant', 'feed_post');
CREATE TYPE preshard_reason AS ENUM ('purchased', 'subscription_grant', 'event_pool_set', 'event_pool_consumed', 'event_pool_returned', 'admin_grant');
CREATE TYPE report_target_type AS ENUM ('message', 'photo', 'user', 'event');
CREATE TYPE report_status AS ENUM ('pending', 'reviewed', 'actioned', 'dismissed');
CREATE TYPE admin_role AS ENUM ('super_admin', 'moderator');
CREATE TYPE preshard_remainder_action AS ENUM ('return', 'redistribute');
CREATE TYPE feature_request_status AS ENUM ('pending', 'approved', 'rejected');

-- ============================================================
-- 3. TABLES
-- ============================================================

-- 3.1 users
CREATE TABLE users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username text UNIQUE,
    display_name text,
    avatar_url text,
    date_of_birth date,
    bio text,
    banned_at timestamptz,
    ban_reason text,
    deleted_at timestamptz,
    personal_shards integer NOT NULL DEFAULT 0,
    preshards integer NOT NULL DEFAULT 0,
    subscription_tier subscription_tier NOT NULL DEFAULT 'free',
    subscription_expires_at timestamptz,
    notification_preferences jsonb NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- 3.2 cosmetics
CREATE TABLE cosmetics (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    type cosmetic_type NOT NULL,
    asset_url text NOT NULL,
    shard_cost integer NOT NULL,
    tier_requirement subscription_tier NOT NULL DEFAULT 'free',
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.3 user_cosmetics
CREATE TABLE user_cosmetics (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    cosmetic_id uuid NOT NULL REFERENCES cosmetics(id) ON DELETE CASCADE,
    equipped boolean NOT NULL DEFAULT false,
    purchased_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, cosmetic_id)
);

-- 3.4 group_cosmetics
CREATE TABLE group_cosmetics (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id uuid NOT NULL,
    cosmetic_id uuid NOT NULL REFERENCES cosmetics(id) ON DELETE CASCADE,
    equipped boolean NOT NULL DEFAULT true,
    purchased_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (group_id, cosmetic_id)
);

-- 3.5 friendships
CREATE TABLE friendships (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    requester_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    addressee_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status friendship_status NOT NULL DEFAULT 'pending',
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.6 groups
CREATE TABLE groups (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    description text,
    cover_url text,
    created_by_user_id uuid NOT NULL REFERENCES users(id),
    group_shards integer NOT NULL DEFAULT 0,
    size_tier size_tier,
    rank_bracket rank_bracket,
    frozen_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE group_cosmetics ADD FOREIGN KEY (group_id) REFERENCES groups(id) ON DELETE CASCADE;

-- 3.7 group_members
CREATE TABLE group_members (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role group_role NOT NULL DEFAULT 'member',
    joined_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (group_id, user_id)
);

-- 3.8 group_shard_contributions
CREATE TABLE group_shard_contributions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    shards_contributed integer NOT NULL,
    contributed_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL
);

-- 3.9 group_rank_snapshots
CREATE TABLE group_rank_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    size_tier size_tier NOT NULL,
    rank_bracket rank_bracket NOT NULL,
    rank_position integer NOT NULL,
    score integer NOT NULL,
    member_count integer NOT NULL,
    calculated_at timestamptz NOT NULL DEFAULT now()
);

-- 3.10 events
CREATE TABLE events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    description text,
    cover_url text,
    type event_type NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES users(id),
    group_id uuid REFERENCES groups(id),
    location_name text,
    location_lat numeric,
    location_lng numeric,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    join_mode join_mode,
    preshards_pool integer NOT NULL DEFAULT 0,
    preshards_distributed boolean NOT NULL DEFAULT false,
    preshards_cap_per_user integer,
    preshards_remainder_action preshard_remainder_action,
    dynamic_qr_enabled boolean NOT NULL DEFAULT false,
    invite_token text UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
    status event_status NOT NULL DEFAULT 'draft',
    featured boolean NOT NULL DEFAULT false,
    featured_until timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT check_casual_no_preshards CHECK (type != 'casual' OR preshards_pool = 0)
);

-- 3.11 event_promotores
CREATE TABLE event_promotores (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role event_role NOT NULL DEFAULT 'promotor',
    preshards_contributed integer NOT NULL DEFAULT 0,
    added_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id, user_id)
);

-- 3.12 event_invites
CREATE TABLE event_invites (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    invited_by_user_id uuid NOT NULL REFERENCES users(id),
    status invite_status NOT NULL DEFAULT 'pending',
    invited_at timestamptz NOT NULL DEFAULT now(),
    responded_at timestamptz,
    UNIQUE (event_id, user_id)
);

-- 3.13 event_qr_tokens
CREATE TABLE event_qr_tokens (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token text UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
    expires_at timestamptz NOT NULL,
    scanned_at timestamptz,
    attendance_confirmed boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.14 event_attendances
CREATE TABLE event_attendances (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    confirmed_at timestamptz NOT NULL DEFAULT now(),
    shards_received integer NOT NULL DEFAULT 0,
    UNIQUE (event_id, user_id)
);

-- 3.15 event_photos
CREATE TABLE event_photos (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    uploaded_by_user_id uuid NOT NULL REFERENCES users(id),
    storage_path text NOT NULL,
    likes_count integer NOT NULL DEFAULT 0,
    reported boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.16 event_photo_likes
CREATE TABLE event_photo_likes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    photo_id uuid NOT NULL REFERENCES event_photos(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (photo_id, user_id)
);

-- 3.17 chats
CREATE TABLE chats (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    type chat_type NOT NULL,
    reference_id uuid,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.18 messages
CREATE TABLE messages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    chat_id uuid NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    sender_id uuid NOT NULL REFERENCES users(id),
    content text NOT NULL,
    media_url text,
    reported boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.19 chat_participants
CREATE TABLE chat_participants (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    chat_id uuid NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (chat_id, user_id)
);

-- 3.20 shard_ledger
CREATE TABLE shard_ledger (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    delta integer NOT NULL,
    reason shard_reason NOT NULL,
    reference_id uuid,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.21 preshard_ledger
CREATE TABLE preshard_ledger (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    delta integer NOT NULL,
    reason preshard_reason NOT NULL,
    reference_id uuid,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.22 minigame_sessions
CREATE TABLE minigame_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    game_type mini_game_type NOT NULL,
    status mini_game_status NOT NULL DEFAULT 'active',
    shard_wager integer NOT NULL DEFAULT 0,
    participants uuid[] NOT NULL DEFAULT '{}',
    winner_id uuid REFERENCES users(id),
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.23 notifications
CREATE TABLE notifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type text NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    data jsonb,
    read boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.24 feature_requests
CREATE TABLE feature_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    requested_by_user_id uuid NOT NULL REFERENCES users(id),
    contact_info text NOT NULL,
    desired_duration_days integer NOT NULL,
    notes text,
    status feature_request_status NOT NULL DEFAULT 'pending',
    featured_until timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.25 reports
CREATE TABLE reports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter_id uuid NOT NULL REFERENCES users(id),
    target_type report_target_type NOT NULL,
    target_id uuid NOT NULL,
    reason text NOT NULL,
    status report_status NOT NULL DEFAULT 'pending',
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.26 admin_users
CREATE TABLE admin_users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email text UNIQUE NOT NULL,
    display_name text NOT NULL,
    role admin_role NOT NULL DEFAULT 'moderator',
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.27 admin_audit_log
CREATE TABLE admin_audit_log (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_user_id uuid NOT NULL REFERENCES admin_users(id),
    action text NOT NULL,
    target_type text NOT NULL,
    target_id text NOT NULL,
    details jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.28 subscription_overrides
CREATE TABLE subscription_overrides (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    admin_user_id uuid NOT NULL REFERENCES admin_users(id),
    tier subscription_tier NOT NULL,
    expires_at timestamptz NOT NULL,
    reason text,
    revoked boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 3.29 app_config
CREATE TABLE app_config (
    key text PRIMARY KEY,
    value text NOT NULL,
    description text,
    default_value text,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- 3.30 processed_webhooks
CREATE TABLE processed_webhooks (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id text UNIQUE NOT NULL,
    event_type text NOT NULL,
    processed_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 4. INDEXES
-- ============================================================
CREATE INDEX idx_users_username ON users(username);
CREATE INDEX idx_users_deleted_at ON users(deleted_at);
CREATE INDEX idx_users_subscription_tier ON users(subscription_tier);
CREATE INDEX idx_friendships_requester ON friendships(requester_id);
CREATE INDEX idx_friendships_addressee ON friendships(addressee_id);
CREATE INDEX idx_friendships_status ON friendships(status);
CREATE INDEX idx_group_members_group ON group_members(group_id);
CREATE INDEX idx_group_members_user ON group_members(user_id);
CREATE INDEX idx_group_shard_contributions_group ON group_shard_contributions(group_id);
CREATE INDEX idx_group_shard_contributions_expires ON group_shard_contributions(expires_at);
CREATE INDEX idx_group_rank_snapshots_group ON group_rank_snapshots(group_id);
CREATE INDEX idx_group_rank_snapshots_calculated ON group_rank_snapshots(calculated_at);
CREATE INDEX idx_events_status ON events(status);
CREATE INDEX idx_events_starts_at ON events(starts_at);
CREATE INDEX idx_events_group ON events(group_id);
CREATE INDEX idx_events_invite_token ON events(invite_token);
CREATE INDEX idx_event_promotores_event ON event_promotores(event_id);
CREATE INDEX idx_event_promotores_user ON event_promotores(user_id);
CREATE INDEX idx_event_invites_event ON event_invites(event_id);
CREATE INDEX idx_event_invites_user ON event_invites(user_id);
CREATE INDEX idx_event_qr_tokens_event ON event_qr_tokens(event_id);
CREATE INDEX idx_event_qr_tokens_user ON event_qr_tokens(user_id);
CREATE INDEX idx_event_qr_tokens_token ON event_qr_tokens(token);
CREATE INDEX idx_event_qr_tokens_expires ON event_qr_tokens(expires_at);
CREATE INDEX idx_event_attendances_event ON event_attendances(event_id);
CREATE INDEX idx_event_attendances_user ON event_attendances(user_id);
CREATE INDEX idx_event_photos_event ON event_photos(event_id);
CREATE INDEX idx_event_photo_likes_photo ON event_photo_likes(photo_id);
CREATE INDEX idx_messages_chat ON messages(chat_id);
CREATE INDEX idx_messages_created ON messages(created_at);
CREATE INDEX idx_chat_participants_chat ON chat_participants(chat_id);
CREATE INDEX idx_chat_participants_user ON chat_participants(user_id);
CREATE INDEX idx_shard_ledger_user ON shard_ledger(user_id);
CREATE INDEX idx_preshard_ledger_user ON preshard_ledger(user_id);
CREATE INDEX idx_notifications_user ON notifications(user_id);
CREATE INDEX idx_notifications_read ON notifications(read);
CREATE INDEX idx_notifications_created ON notifications(created_at);
CREATE INDEX idx_feature_requests_event ON feature_requests(event_id);
CREATE INDEX idx_feature_requests_status ON feature_requests(status);
CREATE INDEX idx_reports_status ON reports(status);
CREATE INDEX idx_reports_target ON reports(target_type, target_id);
CREATE INDEX idx_admin_audit_log_created ON admin_audit_log(created_at);
CREATE INDEX idx_subscription_overrides_user ON subscription_overrides(user_id);
CREATE INDEX idx_processed_webhooks_event ON processed_webhooks(event_id);

-- ============================================================
-- 5. TRIGGERS (auto `updated_at` via moddatetime)
-- ============================================================
CREATE TRIGGER users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION extensions.moddatetime(updated_at);

CREATE TRIGGER groups_updated_at BEFORE UPDATE ON groups
    FOR EACH ROW EXECUTE FUNCTION extensions.moddatetime(updated_at);

CREATE TRIGGER events_updated_at BEFORE UPDATE ON events
    FOR EACH ROW EXECUTE FUNCTION extensions.moddatetime(updated_at);

-- 5.1 group_size_tier: AFTER INSERT OR DELETE ON group_members
CREATE OR REPLACE FUNCTION update_group_size_tier()
RETURNS trigger AS $$
DECLARE
    member_count integer;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT COUNT(*) INTO member_count FROM group_members WHERE group_id = NEW.group_id;
    ELSE
        SELECT COUNT(*) INTO member_count FROM group_members WHERE group_id = OLD.group_id;
    END IF;

    UPDATE groups SET size_tier = CASE
        WHEN member_count >= 257 THEN 'large'
        WHEN member_count >= 51 THEN 'medium'
        WHEN member_count >= 15 THEN 'small'
        ELSE 'micro'
    END WHERE id = COALESCE(NEW.group_id, OLD.group_id);

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER group_size_tier_trigger
    AFTER INSERT OR DELETE ON group_members
    FOR EACH ROW EXECUTE FUNCTION update_group_size_tier();

-- 5.2 dynamic_qr_enabled: BEFORE INSERT OR UPDATE OF preshards_pool ON events
CREATE OR REPLACE FUNCTION set_dynamic_qr_enabled()
RETURNS trigger AS $$
BEGIN
    NEW.dynamic_qr_enabled = (NEW.preshards_pool > 0);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER dynamic_qr_enabled_trigger
    BEFORE INSERT OR UPDATE OF preshards_pool ON events
    FOR EACH ROW EXECUTE FUNCTION set_dynamic_qr_enabled();

-- 5.3 message_cap: AFTER INSERT ON messages
CREATE OR REPLACE FUNCTION enforce_message_cap()
RETURNS trigger AS $$
DECLARE
    chat_limit integer;
    msg_count integer;
BEGIN
    SELECT COALESCE(
        (SELECT value::integer FROM app_config WHERE key = 'chat.message_cap'),
        1000
    ) INTO chat_limit;

    SELECT COUNT(*) INTO msg_count FROM messages WHERE chat_id = NEW.chat_id;

    IF msg_count > chat_limit THEN
        DELETE FROM messages WHERE id IN (
            SELECT id FROM messages
            WHERE chat_id = NEW.chat_id
            ORDER BY created_at ASC
            LIMIT (msg_count - chat_limit)
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER message_cap_trigger
    AFTER INSERT ON messages
    FOR EACH ROW EXECUTE FUNCTION enforce_message_cap();

-- 5.4 group_shard_contributions_increment: AFTER INSERT ON group_shard_contributions
CREATE OR REPLACE FUNCTION increment_group_shards()
RETURNS trigger AS $$
BEGIN
    UPDATE groups SET group_shards = group_shards + NEW.shards_contributed
    WHERE id = NEW.group_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER group_shards_increment_trigger
    AFTER INSERT ON group_shard_contributions
    FOR EACH ROW EXECUTE FUNCTION increment_group_shards();

-- 5.5 photo_likes_count: AFTER INSERT OR DELETE ON event_photo_likes
CREATE OR REPLACE FUNCTION update_photo_likes_count()
RETURNS trigger AS $$
DECLARE
    target_photo_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        target_photo_id := NEW.photo_id;
    ELSE
        target_photo_id := OLD.photo_id;
    END IF;

    UPDATE event_photos SET likes_count = (
        SELECT COUNT(*) FROM event_photo_likes WHERE photo_id = target_photo_id
    ) WHERE id = target_photo_id;

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER photo_likes_count_trigger
    AFTER INSERT OR DELETE ON event_photo_likes
    FOR EACH ROW EXECUTE FUNCTION update_photo_likes_count();

-- 5.6 shard_distribution_dispatch: AFTER UPDATE OF status ON events
-- Placeholder: will invoke Edge Function when EEDG is deployed (Phase 05)
CREATE OR REPLACE FUNCTION dispatch_shard_distribution()
RETURNS trigger AS $$
BEGIN
    -- TODO: Replace with pg_net HTTP call to shard-distribution Edge Function
    -- See docs/specs/steps/phase-05-events/EEDG-edge-functions-event-lifecycle.md
    RAISE LOG 'shard distribution needed for event %', NEW.id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER shard_distribution_dispatch_trigger
    AFTER UPDATE OF status ON events
    FOR EACH ROW
    WHEN (NEW.status = 'ended')
    EXECUTE FUNCTION dispatch_shard_distribution();

-- ============================================================
-- 6. RLS POLICIES
-- ============================================================
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_cosmetics ENABLE ROW LEVEL SECURITY;
ALTER TABLE cosmetics ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_cosmetics ENABLE ROW LEVEL SECURITY;
ALTER TABLE friendships ENABLE ROW LEVEL SECURITY;
ALTER TABLE groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_shard_contributions ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_rank_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_promotores ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_qr_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_attendances ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_photo_likes ENABLE ROW LEVEL SECURITY;
ALTER TABLE chats ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE shard_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE preshard_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE minigame_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE feature_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscription_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE processed_webhooks ENABLE ROW LEVEL SECURITY;

-- users
CREATE POLICY users_read_own ON users FOR SELECT USING (id = auth.uid());
CREATE POLICY users_update_own ON users FOR UPDATE USING (id = auth.uid())
    WITH CHECK (id = auth.uid());

-- user_cosmetics
CREATE POLICY user_cosmetics_read_own ON user_cosmetics FOR SELECT USING (user_id = auth.uid());
CREATE POLICY user_cosmetics_insert_own ON user_cosmetics FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY user_cosmetics_update_own ON user_cosmetics FOR UPDATE USING (user_id = auth.uid());

-- cosmetics (catalog — public read)
CREATE POLICY cosmetics_read_all ON cosmetics FOR SELECT USING (true);

-- group_cosmetics
CREATE POLICY group_cosmetics_select ON group_cosmetics FOR SELECT USING (true);

-- friendships
CREATE POLICY friendships_read_involving ON friendships FOR SELECT USING (requester_id = auth.uid() OR addressee_id = auth.uid());
CREATE POLICY friendships_insert_own ON friendships FOR INSERT WITH CHECK (requester_id = auth.uid());
CREATE POLICY friendships_update_own ON friendships FOR UPDATE USING (requester_id = auth.uid() OR addressee_id = auth.uid());

-- groups
CREATE POLICY groups_read_member ON groups FOR SELECT USING (
    EXISTS (SELECT 1 FROM group_members WHERE group_id = id AND user_id = auth.uid())
);
CREATE POLICY groups_update_promotor ON groups FOR UPDATE USING (
    EXISTS (SELECT 1 FROM group_members WHERE group_id = id AND user_id = auth.uid() AND role IN ('promotor', 'co_promotor'))
);
CREATE POLICY groups_insert_own ON groups FOR INSERT WITH CHECK (created_by_user_id = auth.uid());

-- group_members
CREATE POLICY group_members_read_same ON group_members FOR SELECT USING (
    EXISTS (SELECT 1 FROM group_members gm2 WHERE gm2.group_id = group_id AND gm2.user_id = auth.uid())
);
CREATE POLICY group_members_insert ON group_members FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM group_members gm2 WHERE gm2.group_id = group_members.group_id AND gm2.user_id = auth.uid() AND gm2.role IN ('promotor', 'co_promotor'))
    OR NOT EXISTS (SELECT 1 FROM group_members gm3 WHERE gm3.group_id = group_members.group_id) -- first member (creator)
);
CREATE POLICY group_members_delete_own ON group_members FOR DELETE USING (user_id = auth.uid());
CREATE POLICY group_members_delete_promotor ON group_members FOR DELETE USING (
    EXISTS (SELECT 1 FROM group_members gm2 WHERE gm2.group_id = group_members.group_id AND gm2.user_id = auth.uid() AND gm2.role IN ('promotor', 'co_promotor'))
);

-- group_shard_contributions
CREATE POLICY gsc_read_member ON group_shard_contributions FOR SELECT USING (
    EXISTS (SELECT 1 FROM group_members WHERE group_id = group_shard_contributions.group_id AND user_id = auth.uid())
);

-- group_rank_snapshots (public leaderboard)
CREATE POLICY grs_read_all ON group_rank_snapshots FOR SELECT USING (true);

-- events
CREATE POLICY events_read_access ON events FOR SELECT USING (
    group_id IS NULL -- public
    OR EXISTS (SELECT 1 FROM group_members WHERE group_id = events.group_id AND user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM event_invites WHERE event_id = events.id AND user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM event_promotores WHERE event_id = events.id AND user_id = auth.uid())
);
CREATE POLICY events_update_promotor ON events FOR UPDATE USING (
    EXISTS (SELECT 1 FROM event_promotores WHERE event_id = id AND user_id = auth.uid())
);
CREATE POLICY events_insert_own ON events FOR INSERT WITH CHECK (created_by_user_id = auth.uid());

-- event_promotores
CREATE POLICY ep_read_access ON event_promotores FOR SELECT USING (
    EXISTS (SELECT 1 FROM events WHERE id = event_id AND (
        group_id IS NULL
        OR EXISTS (SELECT 1 FROM group_members WHERE group_id = events.group_id AND user_id = auth.uid())
    ))
);
CREATE POLICY ep_insert_promotor ON event_promotores FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM event_promotores ep2 WHERE ep2.event_id = event_promotores.event_id AND ep2.user_id = auth.uid() AND ep2.role = 'promotor')
);

-- event_invites
CREATE POLICY ei_read_own ON event_invites FOR SELECT USING (user_id = auth.uid());
CREATE POLICY ei_update_own ON event_invites FOR UPDATE USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- event_qr_tokens
CREATE POLICY eqt_read_own ON event_qr_tokens FOR SELECT USING (user_id = auth.uid());
-- No INSERT/UPDATE — Edge Function only

-- event_attendances
CREATE POLICY ea_read_access ON event_attendances FOR SELECT USING (
    user_id = auth.uid()
    OR EXISTS (SELECT 1 FROM events WHERE id = event_id AND (
        EXISTS (SELECT 1 FROM group_members WHERE group_id = events.group_id AND user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM event_promotores WHERE event_id = events.id AND user_id = auth.uid())
    ))
);

-- event_photos
CREATE POLICY eph_read_access ON event_photos FOR SELECT USING (
    EXISTS (SELECT 1 FROM events WHERE id = event_id AND (
        group_id IS NULL
        OR EXISTS (SELECT 1 FROM group_members WHERE group_id = events.group_id AND user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM event_invites WHERE event_id = events.id AND user_id = auth.uid())
    ))
);
CREATE POLICY eph_insert_own ON event_photos FOR INSERT WITH CHECK (uploaded_by_user_id = auth.uid());

-- event_photo_likes
CREATE POLICY epl_read_access ON event_photo_likes FOR SELECT USING (
    EXISTS (SELECT 1 FROM event_photos WHERE id = photo_id AND (
        EXISTS (SELECT 1 FROM events WHERE id = event_photos.event_id AND (
            group_id IS NULL
            OR EXISTS (SELECT 1 FROM group_members WHERE group_id = events.group_id AND user_id = auth.uid())
            OR EXISTS (SELECT 1 FROM event_invites WHERE event_id = events.id AND user_id = auth.uid())
            OR EXISTS (SELECT 1 FROM event_promotores WHERE event_id = events.id AND user_id = auth.uid())
        ))
    ))
);
CREATE POLICY epl_insert_own ON event_photo_likes FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY epl_delete_own ON event_photo_likes FOR DELETE USING (user_id = auth.uid());

-- chats
CREATE POLICY chats_insert_related ON chats FOR INSERT WITH CHECK (
    (type = 'event' AND EXISTS (SELECT 1 FROM events WHERE id = reference_id AND created_by_user_id = auth.uid()))
    OR (type = 'group' AND EXISTS (SELECT 1 FROM groups WHERE id = reference_id AND created_by_user_id = auth.uid()))
    OR (type = 'direct' AND auth.uid() IN (SELECT user_id FROM chat_participants WHERE chat_id = id AND user_id = auth.uid()))
);
CREATE POLICY chats_read_participant ON chats FOR SELECT USING (
    (type = 'direct' AND EXISTS (SELECT 1 FROM chat_participants WHERE chat_id = id AND user_id = auth.uid()))
    OR (type = 'group' AND EXISTS (SELECT 1 FROM group_members WHERE group_id = reference_id AND user_id = auth.uid()))
    OR (type = 'event' AND (
        EXISTS (SELECT 1 FROM event_invites WHERE event_id = reference_id AND user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM event_promotores WHERE event_id = reference_id AND user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM group_members gm JOIN events e ON e.group_id = gm.group_id WHERE e.id = reference_id AND gm.user_id = auth.uid())
    ))
);

-- messages
CREATE POLICY messages_read_participant ON messages FOR SELECT USING (
    EXISTS (SELECT 1 FROM chats WHERE id = chat_id AND (
        (type = 'direct' AND EXISTS (SELECT 1 FROM chat_participants WHERE chat_id = chats.id AND user_id = auth.uid()))
        OR (type = 'group' AND EXISTS (SELECT 1 FROM group_members WHERE group_id = chats.reference_id AND user_id = auth.uid()))
        OR (type = 'event' AND (
            EXISTS (SELECT 1 FROM event_invites WHERE event_id = chats.reference_id AND user_id = auth.uid())
            OR EXISTS (SELECT 1 FROM event_promotores WHERE event_id = chats.reference_id AND user_id = auth.uid())
        ))
    ))
);
CREATE POLICY messages_insert_own ON messages FOR INSERT WITH CHECK (sender_id = auth.uid());

-- chat_participants
CREATE POLICY cp_read_own ON chat_participants FOR SELECT USING (user_id = auth.uid());

-- shard_ledger
CREATE POLICY sl_read_own ON shard_ledger FOR SELECT USING (user_id = auth.uid());

-- preshard_ledger
CREATE POLICY pl_read_own ON preshard_ledger FOR SELECT USING (user_id = auth.uid());

-- minigame_sessions
CREATE POLICY ms_read_group_member ON minigame_sessions FOR SELECT USING (
    EXISTS (SELECT 1 FROM group_members WHERE group_id = minigame_sessions.group_id AND user_id = auth.uid())
);

-- notifications
CREATE POLICY notif_read_own ON notifications FOR SELECT USING (user_id = auth.uid());
CREATE POLICY notif_update_own ON notifications FOR UPDATE USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid() AND read IS NOT NULL);

-- feature_requests
CREATE POLICY fr_read_own ON feature_requests FOR SELECT USING (requested_by_user_id = auth.uid());
CREATE POLICY fr_insert_own ON feature_requests FOR INSERT WITH CHECK (requested_by_user_id = auth.uid());

-- reports (insert only — read is admin-only via service_role)
CREATE POLICY reports_insert_own ON reports FOR INSERT WITH CHECK (reporter_id = auth.uid());

-- app_config (public read, no client write)
CREATE POLICY app_config_read_all ON app_config FOR SELECT USING (true);

-- Admin-only tables: no client access (service_role only)
CREATE POLICY admin_users_no_access ON admin_users FOR ALL USING (false);
CREATE POLICY admin_audit_log_no_access ON admin_audit_log FOR ALL USING (false);
CREATE POLICY subscription_overrides_no_access ON subscription_overrides FOR ALL USING (false);
CREATE POLICY processed_webhooks_no_access ON processed_webhooks FOR ALL USING (false);

-- ============================================================
-- 7. SEED DATA — NO DATA INSERTs IN MIGRATIONS
-- ============================================================
-- Seed data (admin_users system row + app_config keys) lives EXCLUSIVELY in
-- supabase/seed.sql — the single source of truth (SUP-04, agent I-33).
-- It is applied after migrations by:
--   * `supabase db reset` / `supabase db start` (config.toml [db.seed] sql_paths = ["./seed.sql"])
--   * supabase/reset.sh  (line: psql -f seed.sql)
--   * supabase/migrate.sh (line: psql -f seed.sql — idempotent ON CONFLICT DO NOTHING)
-- Migrations must contain schema changes only — never data INSERTs.
-- See docs/to-fix/categories/06-SUPABASE-BACKEND.md SUP-04.
