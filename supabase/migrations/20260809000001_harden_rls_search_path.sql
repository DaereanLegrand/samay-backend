-- Samay — Harden RLS + SECURITY DEFINER search_path (agent I-31)
-- Migration 19 of 19. Fixes:
--   SUP-02 / SEC-13 / H-19 / H-25 / G-01: FORCE ROW LEVEL SECURITY on all
--   31 RLS-enabled tables (was: ENABLE only; table owner bypassed RLS).
--   SUP-03 / SEC-14 / H-20 / H-26 / G-02: SET search_path = '' on all 12
--   unhardened SECURITY DEFINER functions (only check_signup_email was
--   already hardened, in 20260724000001) + fully-qualified object references.
--
-- ============================================================
-- 0. SERVICE_ROLE BYPASSRLS VERIFICATION (critical pre-check)
-- ============================================================
-- Does FORCE RLS break the admin CLI (Go, SUPABASE_SERVICE_ROLE_KEY via
-- PostgREST, internal/db/client.go:22) or the table owner? Postgres semantics:
--   * FORCE ROW LEVEL SECURITY forces the TABLE OWNER to obey RLS.
--   * Superusers (postgres) ALWAYS bypass RLS, FORCE or not.
--   * Roles WITH BYPASSRLS attribute ALWAYS bypass RLS, FORCE or not.
-- This repo's volumes/db/init is EMPTY (SELFHOSTING.md §5: "no auto-init SQL"),
-- so roles come from the supabase/postgres:17.4.5.2 image's baked-in
-- /docker-entrypoint-initdb.d/ scripts. Verified in the upstream source
-- (github.com/supabase/postgres, Dockerfile-17:158 COPY migrations/db
-- /docker-entrypoint-initdb.d/; migrations/db/init-scripts/
-- 00000000000000-initial-schema.sql:31, state at commit 8d3216973
-- 2025-04-23 = the 17.4.x image era, unchanged in develop):
--     create role service_role nologin noinherit bypassrls;
-- CONCLUSION: service_role HAS BYPASSRLS. FORCE RLS does NOT lock out the
-- admin CLI. No ALTER ROLE needed; pgTAP Section 38c asserts rolbypassrls
-- to keep this verified. (If the image ever drops BYPASSRLS, the admin CLI
-- would be gated by RLS policies — many of which are USING(false) for the
-- admin tables — so this must stay monitored.)

-- ============================================================
-- 1. FORCE ROW LEVEL SECURITY — all 31 RLS-enabled tables
-- ============================================================
-- The 30 ENABLE RLS statements come verbatim from 20260510000001 §6
-- (lines 578-607); signup_tracker (31st) was already FORCEd by
-- 20260724000001:73 and is re-asserted here for a complete, idempotent
-- hardening statement (FORCE is a no-op when already forced).

ALTER TABLE public.users FORCE ROW LEVEL SECURITY;
ALTER TABLE public.user_cosmetics FORCE ROW LEVEL SECURITY;
ALTER TABLE public.cosmetics FORCE ROW LEVEL SECURITY;
ALTER TABLE public.group_cosmetics FORCE ROW LEVEL SECURITY;
ALTER TABLE public.friendships FORCE ROW LEVEL SECURITY;
ALTER TABLE public.groups FORCE ROW LEVEL SECURITY;
ALTER TABLE public.group_members FORCE ROW LEVEL SECURITY;
ALTER TABLE public.group_shard_contributions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.group_rank_snapshots FORCE ROW LEVEL SECURITY;
ALTER TABLE public.events FORCE ROW LEVEL SECURITY;
ALTER TABLE public.event_promotores FORCE ROW LEVEL SECURITY;
ALTER TABLE public.event_invites FORCE ROW LEVEL SECURITY;
ALTER TABLE public.event_qr_tokens FORCE ROW LEVEL SECURITY;
ALTER TABLE public.event_attendances FORCE ROW LEVEL SECURITY;
ALTER TABLE public.event_photos FORCE ROW LEVEL SECURITY;
ALTER TABLE public.event_photo_likes FORCE ROW LEVEL SECURITY;
ALTER TABLE public.chats FORCE ROW LEVEL SECURITY;
ALTER TABLE public.messages FORCE ROW LEVEL SECURITY;
ALTER TABLE public.chat_participants FORCE ROW LEVEL SECURITY;
ALTER TABLE public.shard_ledger FORCE ROW LEVEL SECURITY;
ALTER TABLE public.preshard_ledger FORCE ROW LEVEL SECURITY;
ALTER TABLE public.minigame_sessions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.notifications FORCE ROW LEVEL SECURITY;
ALTER TABLE public.feature_requests FORCE ROW LEVEL SECURITY;
ALTER TABLE public.reports FORCE ROW LEVEL SECURITY;
ALTER TABLE public.app_config FORCE ROW LEVEL SECURITY;
ALTER TABLE public.admin_users FORCE ROW LEVEL SECURITY;
ALTER TABLE public.admin_audit_log FORCE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_overrides FORCE ROW LEVEL SECURITY;
ALTER TABLE public.processed_webhooks FORCE ROW LEVEL SECURITY;
ALTER TABLE public.signup_tracker FORCE ROW LEVEL SECURITY;

-- ============================================================
-- 2. HARDEN SECURITY DEFINER FUNCTIONS — SET search_path = ''
-- ============================================================
-- Pattern (Juega + 20260724000001's check_signup_email):
--   * SET search_path = '' — no implicit schema resolution, so callers can
--     never hijack unqualified references with a poisoned search_path.
--   * Every table/type/function reference inside the body is fully qualified
--     (public.<object>; auth.uid() for the auth schema).
--   * pg_catalog builtins (now(), GREATEST, floor, jsonb_build_object, ...)
--     need no qualification — pg_catalog is implicitly searched.
-- CREATE OR REPLACE preserves existing EXECUTE grants and trigger bindings
-- (same OID), so no REVOKE/GRANT or trigger changes are required.

-- 2.1 update_group_size_tier (trigger fn — 20260510000001:449, cast fix 20260512000007)
CREATE OR REPLACE FUNCTION public.update_group_size_tier()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    member_count integer;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT COUNT(*) INTO member_count FROM public.group_members WHERE group_id = NEW.group_id;
    ELSE
        SELECT COUNT(*) INTO member_count FROM public.group_members WHERE group_id = OLD.group_id;
    END IF;

    UPDATE public.groups SET size_tier = CASE
        WHEN member_count >= 257 THEN 'large'::public.size_tier
        WHEN member_count >= 51  THEN 'medium'::public.size_tier
        WHEN member_count >= 15  THEN 'small'::public.size_tier
        ELSE 'micro'::public.size_tier
    END WHERE id = COALESCE(NEW.group_id, OLD.group_id);

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- 2.2 set_dynamic_qr_enabled (trigger fn — 20260510000001:476; no object refs)
CREATE OR REPLACE FUNCTION public.set_dynamic_qr_enabled()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    NEW.dynamic_qr_enabled = (NEW.preshards_pool > 0);
    RETURN NEW;
END;
$$;

-- 2.3 enforce_message_cap (trigger fn — 20260510000001:489; refs app_config, messages)
CREATE OR REPLACE FUNCTION public.enforce_message_cap()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    chat_limit integer;
    msg_count integer;
BEGIN
    SELECT COALESCE(
        (SELECT value::integer FROM public.app_config WHERE key = 'chat.message_cap'),
        1000
    ) INTO chat_limit;

    SELECT COUNT(*) INTO msg_count FROM public.messages WHERE chat_id = NEW.chat_id;

    IF msg_count > chat_limit THEN
        DELETE FROM public.messages WHERE id IN (
            SELECT id FROM public.messages
            WHERE chat_id = NEW.chat_id
            ORDER BY created_at ASC
            LIMIT (msg_count - chat_limit)
        );
    END IF;

    RETURN NEW;
END;
$$;

-- 2.4 increment_group_shards (trigger fn — 20260510000001:520; refs groups)
CREATE OR REPLACE FUNCTION public.increment_group_shards()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    UPDATE public.groups SET group_shards = group_shards + NEW.shards_contributed
    WHERE id = NEW.group_id;
    RETURN NEW;
END;
$$;

-- 2.5 update_photo_likes_count (trigger fn — 20260510000001:534; refs event_photos, event_photo_likes)
CREATE OR REPLACE FUNCTION public.update_photo_likes_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    target_photo_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        target_photo_id := NEW.photo_id;
    ELSE
        target_photo_id := OLD.photo_id;
    END IF;

    UPDATE public.event_photos SET likes_count = (
        SELECT COUNT(*) FROM public.event_photo_likes WHERE photo_id = target_photo_id
    ) WHERE id = target_photo_id;

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- 2.6 dispatch_shard_distribution (trigger fn — 20260510000001:559; no object refs)
CREATE OR REPLACE FUNCTION public.dispatch_shard_distribution()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    -- TODO: Replace with pg_net HTTP call to shard-distribution Edge Function
    -- See docs/specs/steps/phase-05-events/EEDG-edge-functions-event-lifecycle.md
    RAISE LOG 'shard distribution needed for event %', NEW.id;
    RETURN NEW;
END;
$$;

-- 2.7 hard_delete_expired_users (cron fn — 20260510000002:7; refs users, ledgers, messages, members, events)
CREATE OR REPLACE FUNCTION public.hard_delete_expired_users()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    expired_user RECORD;
BEGIN
    FOR expired_user IN SELECT id, username FROM public.users WHERE deleted_at < now() - interval '30 days'
    LOOP
        -- Anonymize ledger entries (preserve for integrity)
        UPDATE public.shard_ledger SET user_id = NULL WHERE user_id = expired_user.id;
        UPDATE public.preshard_ledger SET user_id = NULL WHERE user_id = expired_user.id;

        -- Anonymize messages
        UPDATE public.messages SET sender_id = NULL, content = '[deleted]' WHERE sender_id = expired_user.id;

        -- Remove group memberships
        DELETE FROM public.group_members WHERE user_id = expired_user.id;

        -- Remove event associations
        DELETE FROM public.event_promotores WHERE user_id = expired_user.id;
        DELETE FROM public.event_invites WHERE user_id = expired_user.id;

        -- Delete user (cascade handles remaining)
        DELETE FROM public.users WHERE id = expired_user.id;
    END LOOP;
END;
$$;

-- 2.8 donate_shards_to_group (RPC — 20260512000001, auth.uid() guard 20260724000002;
--     auth.uid() resolves in the auth schema by explicit qualification)
CREATE OR REPLACE FUNCTION public.donate_shards_to_group(
    p_group_id uuid,
    p_user_id uuid,
    p_amount integer,
    p_expires_at timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF auth.uid() != p_user_id THEN
        RAISE EXCEPTION 'Not authorized';
    END IF;

    UPDATE public.users SET personal_shards = personal_shards - p_amount
    WHERE id = p_user_id AND personal_shards >= p_amount;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Insufficient shards';
    END IF;

    INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
    VALUES (p_user_id, -p_amount, 'group_donation', p_group_id);

    INSERT INTO public.group_shard_contributions (group_id, user_id, shards_contributed, expires_at)
    VALUES (p_group_id, p_user_id, p_amount, p_expires_at);
END;
$$;

-- 2.9 grant_shards (admin RPC — 20260520000001:8; refs users, shard_ledger)
CREATE OR REPLACE FUNCTION public.grant_shards(
    p_user_id uuid,
    p_amount integer,
    p_reason text DEFAULT 'admin_grant'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    UPDATE public.users SET personal_shards = personal_shards + p_amount
    WHERE id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;

    INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
    VALUES (p_user_id, p_amount, p_reason, NULL);
END;
$$;

-- 2.10 grant_preshards (admin RPC — 20260520000001:33; refs users, preshard_ledger)
CREATE OR REPLACE FUNCTION public.grant_preshards(
    p_user_id uuid,
    p_amount integer,
    p_reason text DEFAULT 'admin_grant'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    UPDATE public.users SET preshards = preshards + p_amount
    WHERE id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;

    INSERT INTO public.preshard_ledger (user_id, delta, reason, reference_id)
    VALUES (p_user_id, p_amount, p_reason, NULL);
END;
$$;

-- 2.11 distribute_shards (admin RPC — 20260520000001:60; refs events, invites,
--      attendances, promotores, users, ledgers)
CREATE OR REPLACE FUNCTION public.distribute_shards(
    p_event_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_event RECORD;
    v_promotor RECORD;
    v_attendee RECORD;
    v_total_invitees INT;
    v_confirmed_attendees INT;
    v_per_user INT;
    v_distributed_total INT;
    v_remainder INT;
    v_extra INT;
    v_return_amount INT;
    v_result jsonb;
BEGIN
    SELECT * INTO v_event FROM public.events WHERE id = p_event_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Event not found: %', p_event_id;
    END IF;

    IF v_event.preshards_distributed THEN
        RETURN jsonb_build_object('status', 'skipped', 'reason', 'already distributed');
    END IF;

    SELECT COUNT(*) INTO v_total_invitees FROM public.event_invites WHERE event_id = p_event_id;
    SELECT COUNT(*) INTO v_confirmed_attendees FROM public.event_attendances WHERE event_id = p_event_id;

    IF v_confirmed_attendees = 0 THEN
        FOR v_promotor IN
            SELECT user_id, preshards_contributed
            FROM public.event_promotores
            WHERE event_id = p_event_id AND preshards_contributed > 0
        LOOP
            UPDATE public.users SET preshards = preshards + v_promotor.preshards_contributed
            WHERE id = v_promotor.user_id;
            INSERT INTO public.preshard_ledger (user_id, delta, reason, reference_id)
            VALUES (v_promotor.user_id, v_promotor.preshards_contributed, 'event_pool_returned', p_event_id);
        END LOOP;
        UPDATE public.events SET preshards_pool = 0, preshards_distributed = true WHERE id = p_event_id;
        RETURN jsonb_build_object('status', 'completed', 'attendees', 0, 'action', 'full_return');
    END IF;

    v_per_user := floor(v_event.preshards_pool / v_total_invitees);
    IF v_event.preshards_cap_per_user IS NOT NULL AND v_per_user > v_event.preshards_cap_per_user THEN
        v_per_user := v_event.preshards_cap_per_user;
    END IF;

    v_distributed_total := v_per_user * v_confirmed_attendees;
    IF v_distributed_total > v_event.preshards_pool THEN
        v_distributed_total := v_event.preshards_pool;
        v_per_user := floor(v_event.preshards_pool / v_confirmed_attendees);
    END IF;

    FOR v_attendee IN SELECT ea.user_id FROM public.event_attendances ea WHERE ea.event_id = p_event_id LOOP
        UPDATE public.users SET personal_shards = personal_shards + v_per_user WHERE id = v_attendee.user_id;
        UPDATE public.event_attendances SET shards_received = v_per_user WHERE event_id = p_event_id AND user_id = v_attendee.user_id;
        INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id) VALUES (v_attendee.user_id, v_per_user, 'event_attendance', p_event_id);
    END LOOP;

    v_remainder := v_event.preshards_pool - v_distributed_total;

    IF v_remainder > 0 THEN
        IF v_event.preshards_remainder_action = 'redistribute' THEN
            v_extra := floor(v_remainder / v_confirmed_attendees);
            FOR v_attendee IN SELECT ea.user_id FROM public.event_attendances ea WHERE ea.event_id = p_event_id LOOP
                UPDATE public.users SET personal_shards = personal_shards + v_extra WHERE id = v_attendee.user_id;
                UPDATE public.event_attendances SET shards_received = shards_received + v_extra WHERE event_id = p_event_id AND user_id = v_attendee.user_id;
            END LOOP;
        ELSE
            FOR v_promotor IN SELECT user_id, preshards_contributed FROM public.event_promotores WHERE event_id = p_event_id AND preshards_contributed > 0 LOOP
                v_return_amount := floor(v_remainder * v_promotor.preshards_contributed / NULLIF(v_event.preshards_pool, 0));
                IF v_return_amount > 0 THEN
                    UPDATE public.users SET preshards = preshards + v_return_amount WHERE id = v_promotor.user_id;
                    INSERT INTO public.preshard_ledger (user_id, delta, reason, reference_id) VALUES (v_promotor.user_id, v_return_amount, 'event_pool_returned', p_event_id);
                END IF;
            END LOOP;
        END IF;
    END IF;

    FOR v_promotor IN SELECT user_id, preshards_contributed FROM public.event_promotores WHERE event_id = p_event_id AND preshards_contributed > 0 LOOP
        INSERT INTO public.preshard_ledger (user_id, delta, reason, reference_id) VALUES (v_promotor.user_id, -v_promotor.preshards_contributed, 'event_pool_consumed', p_event_id);
    END LOOP;

    UPDATE public.events SET preshards_pool = 0, preshards_distributed = true WHERE id = p_event_id;

    v_result := jsonb_build_object('status', 'completed', 'attendees', v_confirmed_attendees, 'per_user', v_per_user, 'remainder_action', v_event.preshards_remainder_action, 'remainder', v_remainder);
    RETURN v_result;
END;
$$;

-- 2.12 recalculate_ranks (admin RPC — 20260520000001:160; refs groups,
--      group_rank_snapshots, group_members; enum types fully qualified)
CREATE OR REPLACE FUNCTION public.recalculate_ranks(
    p_tier text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_tiers text[] := ARRAY['micro', 'small', 'medium', 'large'];
    v_tier text;
    v_group RECORD;
    v_rank INT;
    v_total INT;
    v_percentile NUMERIC;
    v_bracket public.rank_bracket;
BEGIN
    IF p_tier IS NOT NULL THEN v_tiers := ARRAY[p_tier]; END IF;

    FOREACH v_tier IN ARRAY v_tiers LOOP
        SELECT COUNT(*) INTO v_total FROM public.groups WHERE size_tier = v_tier::public.size_tier;
        IF v_total = 0 THEN CONTINUE; END IF;

        v_rank := 0;
        FOR v_group IN SELECT id, group_shards FROM public.groups WHERE size_tier = v_tier::public.size_tier ORDER BY group_shards DESC LOOP
            v_rank := v_rank + 1;
            v_percentile := ((v_total - v_rank)::NUMERIC / GREATEST(v_total, 1)) * 100;

            v_bracket := CASE
                WHEN v_percentile >= 90 THEN 'b90_100'::public.rank_bracket
                WHEN v_percentile >= 80 THEN 'b80_90'::public.rank_bracket
                WHEN v_percentile >= 60 THEN 'b60_80'::public.rank_bracket
                WHEN v_percentile >= 40 THEN 'b40_60'::public.rank_bracket
                WHEN v_percentile >= 20 THEN 'b20_40'::public.rank_bracket
                ELSE 'b0_20'::public.rank_bracket
            END;

            UPDATE public.groups SET rank_bracket = v_bracket WHERE id = v_group.id;

            INSERT INTO public.group_rank_snapshots (group_id, size_tier, rank_bracket, rank_position, score, member_count)
            SELECT v_group.id, v_tier::public.size_tier, v_bracket, v_rank, v_group.group_shards,
                   COUNT(gm.id) FILTER (WHERE gm.status = 'active')
            FROM public.group_members gm WHERE gm.group_id = v_group.id;
        END LOOP;
    END LOOP;

    DELETE FROM public.group_rank_snapshots WHERE calculated_at < now() - INTERVAL '30 days';
END;
$$;
