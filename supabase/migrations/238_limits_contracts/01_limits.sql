-- ============================================================================
-- 238_limits_contracts/01_limits.sql — E3 limits, group RPC, rank gating
--
-- Final limits (14-wave2-decisions §3 E3):
--   events created   free 3/day, pro 10/day, vip 100/day
--   rapid events     3/minute hard
--   groups hosted    free 5, pro 20, vip 100
--   group members    free 14, pro 256, vip unlimited
--   event invites    50 pending/user; 1000/day/user
--   group invites    20 pending/group; 100/day/user
--   group joins      50/day/user
--   reports          5/hour; 20/day; 1 per target per 24h
--   photo uploads    100/day/user; 50/event/day
--   device tokens    5/user
--   push             suppress beyond 100/hour/user
--   messages         60/minute/chat; 300/hour/user
--
-- Limits are enforced in SECURITY DEFINER triggers (so the RPC and a direct
-- PostgREST insert hit the same gate). Service role / privileged seeds skip
-- them (auth.uid() IS NULL). Group creation becomes one transactional RPC and
-- direct `groups` inserts are revoked.
--
-- Group rank visibility: free -> micro; pro -> micro/small/medium; vip -> all.
--
-- Rollback: drop the triggers/functions/table and restore `grs_read_all` +
-- `GRANT INSERT ON groups`. Forward-fix only for limits (never raise them
-- without an owner decision).
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Counter infrastructure + config keys.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.action_rate_limits (
    user_id uuid NOT NULL,
    action text NOT NULL,
    scope text NOT NULL DEFAULT '',
    window_start timestamp with time zone NOT NULL DEFAULT now(),
    count integer NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, action, scope)
);

ALTER TABLE ONLY public.action_rate_limits FORCE ROW LEVEL SECURITY;
ALTER TABLE public.action_rate_limits ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS action_rate_limits_no_access ON public.action_rate_limits;
CREATE POLICY action_rate_limits_no_access ON public.action_rate_limits USING (false);

-- Increments the fixed-window counter and raises once the limit is exceeded.
CREATE OR REPLACE FUNCTION public.consume_action_limit(
    p_user uuid,
    p_action text,
    p_scope text,
    p_limit integer,
    p_window interval
) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_count integer;
BEGIN
    IF p_user IS NULL OR p_limit IS NULL OR p_limit < 0 THEN
        RETURN 0;
    END IF;

    INSERT INTO public.action_rate_limits AS a
        (user_id, action, scope, window_start, count)
    VALUES (p_user, p_action, COALESCE(p_scope, ''), now(), 1)
    ON CONFLICT (user_id, action, scope) DO UPDATE
        SET window_start = CASE
                WHEN a.window_start < now() - p_window THEN now()
                ELSE a.window_start
            END,
            count = CASE
                WHEN a.window_start < now() - p_window THEN 1
                ELSE a.count + 1
            END
    RETURNING a.count INTO v_count;

    IF v_count > p_limit THEN
        RAISE EXCEPTION 'rate_limited:%', p_action USING ERRCODE = 'P0001';
    END IF;
    RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.consume_action_limit(uuid, text, text, integer, interval)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_action_limit(uuid, text, text, integer, interval)
    TO service_role;
GRANT ALL ON TABLE public.action_rate_limits TO service_role;

INSERT INTO public.app_config (key, value, description, default_value) VALUES
    ('events.free_daily_limit', '3',   'Max events a free user can create per day', '3'),
    ('events.pro_daily_limit',  '10',  'Max events a PRO user can create per day', '10'),
    ('events.vip_daily_limit',  '100', 'Max events a VIP user can create per day', '100'),
    ('groups.free_hosted',      '5',   'Max groups hosted by a free user', '5'),
    ('groups.pro_hosted',       '20',  'Max groups hosted by a PRO user', '20'),
    ('groups.vip_hosted',       '100', 'Max groups hosted by a VIP user', '100'),
    ('groups.free_max_members', '14',  'Max active members in a free-hosted group', '14'),
    ('groups.pro_max_members',  '256', 'Max active members in a PRO-hosted group', '256'),
    ('groups.vip_max_members',  '0',   'Max active members in a VIP-hosted group (0 = unlimited)', '0')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Event creation caps.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_event_creation_limits()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid := auth.uid();
    v_tier public.subscription_tier;
    v_limit integer;
    v_today integer;
BEGIN
    IF v_uid IS NULL THEN
        RETURN NEW;
    END IF;
    IF NEW.created_by_user_id IS DISTINCT FROM v_uid THEN
        RAISE EXCEPTION 'event_creator_mismatch' USING ERRCODE = 'P0001';
    END IF;

    v_tier := public.effective_tier(v_uid);
    SELECT COALESCE(value::integer, 3) INTO v_limit
      FROM public.app_config
     WHERE key = CASE v_tier
         WHEN 'vip'::public.subscription_tier THEN 'events.vip_daily_limit'
         WHEN 'pro'::public.subscription_tier THEN 'events.pro_daily_limit'
         ELSE 'events.free_daily_limit'
     END;
    v_limit := COALESCE(v_limit, 3);

    SELECT count(*) INTO v_today
      FROM public.events
     WHERE created_by_user_id = v_uid
       AND created_at >= date_trunc('day', now());
    IF v_today >= v_limit THEN
        RAISE EXCEPTION 'event_daily_limit' USING ERRCODE = 'P0001';
    END IF;

    PERFORM public.consume_action_limit(
        v_uid, 'event_create', '', 3, interval '1 minute');

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_event_creation_limits() FROM PUBLIC;
DROP TRIGGER IF EXISTS events_creation_limits ON public.events;
CREATE TRIGGER events_creation_limits
    BEFORE INSERT ON public.events
    FOR EACH ROW EXECUTE FUNCTION public.enforce_event_creation_limits();

-- ---------------------------------------------------------------------------
-- 3. Groups: counts, members, invites, joins.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_group_member_limits()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid := auth.uid();
    v_host uuid;
    v_tier public.subscription_tier;
    v_cap integer;
    v_hosted integer;
    v_hosted_limit integer;
    v_pending integer;
BEGIN
    IF v_uid IS NULL THEN
        RETURN NEW;
    END IF;

    IF NEW.status = 'invited' THEN
        SELECT count(*) INTO v_pending
          FROM public.group_members
         WHERE group_id = NEW.group_id AND status = 'invited';
        IF v_pending >= 20 THEN
            RAISE EXCEPTION 'group_invite_pending_limit' USING ERRCODE = 'P0001';
        END IF;
        PERFORM public.consume_action_limit(
            v_uid, 'group_invite', '', 100, interval '1 day');
        RETURN NEW;
    END IF;

    IF NEW.status <> 'active' THEN
        RETURN NEW;
    END IF;

    -- Member cap comes from the group host's effective tier.
    SELECT gm.user_id INTO v_host
      FROM public.group_members gm
     WHERE gm.group_id = NEW.group_id
       AND gm.role = 'host'
       AND gm.status = 'active'
     LIMIT 1;

    IF v_host IS NOT NULL THEN
        v_tier := public.effective_tier(v_host);
        SELECT COALESCE(value::integer, 14) INTO v_cap
          FROM public.app_config
         WHERE key = CASE v_tier
             WHEN 'vip'::public.subscription_tier THEN 'groups.vip_max_members'
             WHEN 'pro'::public.subscription_tier THEN 'groups.pro_max_members'
             ELSE 'groups.free_max_members'
         END;
        v_cap := COALESCE(v_cap, 14);
        IF v_cap > 0 AND (
            SELECT count(*) FROM public.group_members
             WHERE group_id = NEW.group_id AND status = 'active'
        ) >= v_cap THEN
            RAISE EXCEPTION 'group_member_limit' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    -- A new host must stay inside its hosted-group cap.
    IF NEW.role = 'host' THEN
        v_tier := public.effective_tier(v_uid);
        SELECT COALESCE(value::integer, 5) INTO v_hosted_limit
          FROM public.app_config
         WHERE key = CASE v_tier
             WHEN 'vip'::public.subscription_tier THEN 'groups.vip_hosted'
             WHEN 'pro'::public.subscription_tier THEN 'groups.pro_hosted'
             ELSE 'groups.free_hosted'
         END;
        v_hosted_limit := COALESCE(v_hosted_limit, 5);
        SELECT count(*) INTO v_hosted
          FROM public.group_members
         WHERE user_id = v_uid AND role = 'host' AND status = 'active';
        IF v_hosted >= v_hosted_limit THEN
            RAISE EXCEPTION 'group_hosted_limit' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    PERFORM public.consume_action_limit(
        v_uid, 'group_join', '', 50, interval '1 day');

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_group_member_limits() FROM PUBLIC;
DROP TRIGGER IF EXISTS group_member_limits ON public.group_members;
CREATE TRIGGER group_member_limits
    BEFORE INSERT OR UPDATE ON public.group_members
    FOR EACH ROW EXECUTE FUNCTION public.enforce_group_member_limits();

-- One transactional group creation; direct `groups` inserts are denied below.
CREATE OR REPLACE FUNCTION public.create_group(
    p_name text,
    p_description text DEFAULT NULL,
    p_cover_url text DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid := auth.uid();
    v_name text;
    v_group_id uuid := gen_random_uuid();
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'not_authenticated' USING ERRCODE = 'P0001';
    END IF;

    v_name := btrim(COALESCE(p_name, ''));
    IF char_length(v_name) < 1 OR char_length(v_name) > 80 THEN
        RAISE EXCEPTION 'invalid_group_name' USING ERRCODE = 'P0001';
    END IF;
    IF p_description IS NOT NULL AND char_length(p_description) > 500 THEN
        RAISE EXCEPTION 'invalid_group_description' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO public.groups (id, name, description, cover_url, created_by_user_id)
    VALUES (
        v_group_id, v_name,
        NULLIF(btrim(COALESCE(p_description, '')), ''),
        NULLIF(btrim(COALESCE(p_cover_url, '')), ''),
        v_uid);

    INSERT INTO public.group_members (group_id, user_id, role, status)
    VALUES (v_group_id, v_uid, 'host', 'active');

    INSERT INTO public.chats (type, reference_id)
    VALUES ('group'::public.chat_type, v_group_id);

    RETURN jsonb_build_object('status', 'ok', 'id', v_group_id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_group(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_group(text, text, text) TO authenticated, service_role;

REVOKE INSERT, UPDATE, DELETE ON TABLE public.groups FROM anon, authenticated;
GRANT SELECT ON TABLE public.groups TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Event invites.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_event_invite_limits()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid := auth.uid();
    v_pending integer;
BEGIN
    IF v_uid IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT count(*) INTO v_pending
      FROM public.event_invites
     WHERE user_id = NEW.user_id AND status = 'pending';
    IF v_pending >= 50 THEN
        RAISE EXCEPTION 'event_invite_pending_limit' USING ERRCODE = 'P0001';
    END IF;

    PERFORM public.consume_action_limit(
        v_uid, 'event_invite', '', 1000, interval '1 day');
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_event_invite_limits() FROM PUBLIC;
DROP TRIGGER IF EXISTS event_invite_limits ON public.event_invites;
CREATE TRIGGER event_invite_limits
    BEFORE INSERT ON public.event_invites
    FOR EACH ROW EXECUTE FUNCTION public.enforce_event_invite_limits();

-- ---------------------------------------------------------------------------
-- 5. Reports, photos, messages, device tokens, push.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_report_limits()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid := COALESCE(NEW.reporter_id, auth.uid());
BEGIN
    IF v_uid IS NULL THEN
        RETURN NEW;
    END IF;

    PERFORM public.consume_action_limit(v_uid, 'report_hour', '', 5, interval '1 hour');
    PERFORM public.consume_action_limit(v_uid, 'report_day', '', 20, interval '1 day');

    IF EXISTS (
        SELECT 1 FROM public.reports r
         WHERE r.reporter_id = v_uid
           AND r.target_type = NEW.target_type
           AND r.target_id = NEW.target_id
           AND r.created_at > now() - interval '24 hours'
    ) THEN
        RAISE EXCEPTION 'report_duplicate' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_report_limits() FROM PUBLIC;
DROP TRIGGER IF EXISTS reports_limits ON public.reports;
CREATE TRIGGER reports_limits
    BEFORE INSERT ON public.reports
    FOR EACH ROW EXECUTE FUNCTION public.enforce_report_limits();

CREATE OR REPLACE FUNCTION public.enforce_photo_limits()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid := auth.uid();
BEGIN
    IF v_uid IS NULL THEN
        RETURN NEW;
    END IF;
    PERFORM public.consume_action_limit(v_uid, 'photo_user', '', 100, interval '1 day');
    PERFORM public.consume_action_limit(
        v_uid, 'photo_event', NEW.event_id::text, 50, interval '1 day');
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_photo_limits() FROM PUBLIC;
DROP TRIGGER IF EXISTS event_photo_limits ON public.event_photos;
CREATE TRIGGER event_photo_limits
    BEFORE INSERT ON public.event_photos
    FOR EACH ROW EXECUTE FUNCTION public.enforce_photo_limits();

CREATE OR REPLACE FUNCTION public.enforce_message_limits()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    IF NEW.sender_id IS NULL THEN
        RETURN NEW;
    END IF;
    PERFORM public.consume_action_limit(
        NEW.sender_id, 'message_chat', NEW.chat_id::text, 60, interval '1 minute');
    PERFORM public.consume_action_limit(
        NEW.sender_id, 'message_user', '', 300, interval '1 hour');
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_message_limits() FROM PUBLIC;
DROP TRIGGER IF EXISTS messages_limits ON public.messages;
CREATE TRIGGER messages_limits
    BEFORE INSERT ON public.messages
    FOR EACH ROW EXECUTE FUNCTION public.enforce_message_limits();

CREATE OR REPLACE FUNCTION public.enforce_device_token_limit()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NEW;
    END IF;
    IF (SELECT count(*) FROM public.device_tokens WHERE user_id = NEW.user_id) >= 5 THEN
        RAISE EXCEPTION 'device_token_limit' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_device_token_limit() FROM PUBLIC;
DROP TRIGGER IF EXISTS device_token_limit ON public.device_tokens;
CREATE TRIGGER device_token_limit
    BEFORE INSERT ON public.device_tokens
    FOR EACH ROW EXECUTE FUNCTION public.enforce_device_token_limit();

CREATE OR REPLACE FUNCTION public.enforce_push_hourly_limit()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    IF NEW.push_allowed IS DISTINCT FROM true THEN
        RETURN NEW;
    END IF;
    IF (SELECT count(*) FROM public.notifications n
         WHERE n.user_id = NEW.user_id
           AND n.push_allowed = true
           AND n.created_at > now() - interval '1 hour') >= 100 THEN
        NEW.push_allowed := false;
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_push_hourly_limit() FROM PUBLIC;
DROP TRIGGER IF EXISTS notifications_push_hourly_limit ON public.notifications;
CREATE TRIGGER notifications_push_hourly_limit
    BEFORE INSERT ON public.notifications
    FOR EACH ROW EXECUTE FUNCTION public.enforce_push_hourly_limit();

-- ---------------------------------------------------------------------------
-- 6. Group rank tier gating (read path).
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS grs_read_all ON public.group_rank_snapshots;
DROP POLICY IF EXISTS grs_read_tier_gated ON public.group_rank_snapshots;
CREATE POLICY grs_read_tier_gated ON public.group_rank_snapshots
    FOR SELECT USING (
        auth.uid() IS NOT NULL
        AND (
            (
                SELECT CASE
                    WHEN u.subscription_tier <> 'free'
                         AND u.subscription_expires_at IS NOT NULL
                         AND (u.subscription_expires_at + interval '24 hours' > now()
                              OR u.subscription_grace_until > now())
                    THEN u.subscription_tier
                    ELSE 'free'::public.subscription_tier
                END
                  FROM public.users u
                 WHERE u.id = auth.uid()
            ) = 'vip'::public.subscription_tier
            OR (
                (
                    SELECT CASE
                        WHEN u.subscription_tier <> 'free'
                             AND u.subscription_expires_at IS NOT NULL
                             AND (u.subscription_expires_at + interval '24 hours' > now()
                                  OR u.subscription_grace_until > now())
                        THEN u.subscription_tier
                        ELSE 'free'::public.subscription_tier
                    END
                      FROM public.users u
                     WHERE u.id = auth.uid()
                ) = 'pro'::public.subscription_tier
                AND size_tier IN ('micro'::public.size_tier,
                                  'small'::public.size_tier,
                                  'medium'::public.size_tier)
            )
            OR (
                NOT EXISTS (
                    SELECT 1 FROM public.users u
                     WHERE u.id = auth.uid()
                       AND u.subscription_tier <> 'free'
                       AND u.subscription_expires_at IS NOT NULL
                       AND (u.subscription_expires_at + interval '24 hours' > now()
                            OR u.subscription_grace_until > now())
                )
                AND size_tier = 'micro'::public.size_tier
            )
        )
    );

-- ---------------------------------------------------------------------------
-- 7. Shadow-block profile projection (Q4/E3 §8).
--   * blocker -> blocked: full (privacy-projected) profile + blocked_by_me
--   * blocked -> blocker: minimal (username + avatar only) + blocked_me
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_profile_for_viewer(p_id uuid)
RETURNS TABLE(
    id uuid,
    username text,
    avatar_url text,
    bio text,
    profile_public boolean,
    blocked_by_me boolean,
    blocked_me boolean
)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    WITH me AS (
        SELECT auth.uid() AS uid
    ),
    rel AS (
        SELECT
            EXISTS (
                SELECT 1 FROM public.friendships f
                 WHERE f.status = 'blocked'
                   AND f.requester_id = m.uid AND f.addressee_id = p_id
            ) AS blocked_by_me,
            EXISTS (
                SELECT 1 FROM public.friendships f
                 WHERE f.status = 'blocked'
                   AND f.requester_id = p_id AND f.addressee_id = m.uid
            ) AS blocked_me
          FROM me m
    )
    SELECT u.id,
           u.username,
           CASE
               WHEN r.blocked_me
                    OR u.profile_public
                    OR u.id = m.uid
                    OR public.is_accepted_friend(m.uid, u.id)
               THEN u.avatar_url
               ELSE NULL
           END,
           CASE
               WHEN NOT r.blocked_me
                    AND (u.profile_public
                         OR u.id = m.uid
                         OR public.is_accepted_friend(m.uid, u.id))
               THEN u.bio
               ELSE NULL
           END,
           u.profile_public,
           r.blocked_by_me,
           r.blocked_me
      FROM public.users u
      CROSS JOIN me m
      CROSS JOIN rel r
     WHERE u.id = p_id
       AND u.deleted_at IS NULL;
$$;

REVOKE ALL ON FUNCTION public.get_profile_for_viewer(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_profile_for_viewer(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. Counter retention.
-- ---------------------------------------------------------------------------
DO $job$ BEGIN
    PERFORM cron.schedule('action-rate-limits-prune', '35 3 * * *',
        $cmd$DELETE FROM public.action_rate_limits WHERE window_start < now() - interval '30 days';$cmd$);
END $job$;

COMMIT;
