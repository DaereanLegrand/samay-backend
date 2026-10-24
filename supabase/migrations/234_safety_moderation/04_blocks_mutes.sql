-- ============================================================================
-- 234_safety_moderation / 04_blocks_mutes.sql
--
-- Q4b (2026-10-23):
--   * Block hides the user from feed, discovery, rankings and notifications,
--     prevents new DMs/invites, and hides their shared group/event activity
--     where feasible WITHOUT removing membership.
--   * Mute is one-way and weaker: feed/rankings/notifications are filtered,
--     but DMs and invites remain allowed.
--   * A blocked user can never alter the block (only the blocker can update or
--     lift it); the existing RLS is re-asserted and backed by triggers.
--
-- Rollback: restore the 120_views_ranking views/functions and the 110/060
-- trigger set. Drop block_user/unblock_user/mute_user/unmute_user and the
-- additive triggers. Forward-fix: keep the filters; never restore a surface
-- that shows a blocked user.
--
-- Backfill: none (no historical rows to rewrite). Indexes are additive.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Predicates.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_muted_between(p_viewer uuid, p_actor uuid)
RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT p_viewer IS NOT NULL
       AND p_actor IS NOT NULL
       AND p_viewer <> p_actor
       AND EXISTS (
            SELECT 1 FROM public.user_mutes m
             WHERE m.muter_id = p_viewer AND m.muted_id = p_actor
       );
$$;

CREATE OR REPLACE FUNCTION public.is_hidden_between(p_viewer uuid, p_actor uuid)
RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT public.is_blocked_between(p_viewer, p_actor)
        OR public.is_muted_between(p_viewer, p_actor);
$$;

REVOKE ALL ON FUNCTION public.is_muted_between(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.is_hidden_between(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_muted_between(uuid, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_hidden_between(uuid, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Block RPCs. The user-facing client no longer writes `friendships` directly
-- (the old path was RLS-guarded but race-prone); these are the single write
-- path.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.block_user(p_user_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_existing public.friendships%ROWTYPE;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;
    IF p_user_id IS NULL OR p_user_id = v_me THEN
        RETURN jsonb_build_object('status', 'invalid_target');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_user_id AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('status', 'target_not_found');
    END IF;

    SELECT * INTO v_existing
      FROM public.friendships
     WHERE (requester_id = v_me AND addressee_id = p_user_id)
        OR (requester_id = p_user_id AND addressee_id = v_me)
     ORDER BY created_at DESC
     LIMIT 1;

    IF FOUND THEN
        IF v_existing.status = 'blocked' THEN
            IF v_existing.requester_id = v_me THEN
                RETURN jsonb_build_object('status', 'ok', 'already_blocked', true);
            END IF;
            -- The peer owns the block; the blocked party cannot alter it.
            RETURN jsonb_build_object('status', 'blocked_by_peer');
        END IF;
        DELETE FROM public.friendships WHERE id = v_existing.id;
    END IF;

    INSERT INTO public.friendships (requester_id, addressee_id, status)
    VALUES (v_me, p_user_id, 'blocked');

    RETURN jsonb_build_object('status', 'ok', 'blocked', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.unblock_user(p_user_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_deleted integer;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    DELETE FROM public.friendships
     WHERE requester_id = v_me
       AND addressee_id = p_user_id
       AND status = 'blocked';
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    IF v_deleted > 0 THEN
        RETURN jsonb_build_object('status', 'ok', 'unblocked', true);
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.friendships
         WHERE requester_id = p_user_id AND addressee_id = v_me AND status = 'blocked'
    ) THEN
        RETURN jsonb_build_object('status', 'blocked_by_peer');
    END IF;

    RETURN jsonb_build_object('status', 'ok', 'unblocked', false);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_blocked_users()
RETURNS TABLE(id uuid, username text, avatar_url text, blocked_at timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT u.id, u.username, u.avatar_url, f.created_at
      FROM public.friendships f
      JOIN public.users u ON u.id = f.addressee_id
     WHERE f.requester_id = auth.uid()
       AND f.status = 'blocked'
     ORDER BY f.created_at DESC;
$$;

REVOKE ALL ON FUNCTION public.block_user(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.unblock_user(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_blocked_users() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.block_user(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.unblock_user(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_blocked_users() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Mute RPCs.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mute_user(p_user_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;
    IF p_user_id IS NULL OR p_user_id = v_me THEN
        RETURN jsonb_build_object('status', 'invalid_target');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_user_id AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('status', 'target_not_found');
    END IF;

    INSERT INTO public.user_mutes (muter_id, muted_id)
    VALUES (v_me, p_user_id)
    ON CONFLICT (muter_id, muted_id) DO NOTHING;

    RETURN jsonb_build_object('status', 'ok', 'muted', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.unmute_user(p_user_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;
    DELETE FROM public.user_mutes
     WHERE muter_id = auth.uid() AND muted_id = p_user_id;
    RETURN jsonb_build_object('status', 'ok', 'unmuted', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_muted_users()
RETURNS TABLE(id uuid, username text, avatar_url text, muted_at timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT u.id, u.username, u.avatar_url, m.created_at
      FROM public.user_mutes m
      JOIN public.users u ON u.id = m.muted_id
     WHERE m.muter_id = auth.uid()
     ORDER BY m.created_at DESC;
$$;

REVOKE ALL ON FUNCTION public.mute_user(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.unmute_user(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_muted_users() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mute_user(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.unmute_user(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_muted_users() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Block ownership: the existing policies stay, plus triggers that reject any
-- mutation of a block by the blocked party (defence in depth for definer paths).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_block_row_owner()
RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    IF OLD.status <> 'blocked' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    IF auth.uid() IS NULL THEN
        RETURN COALESCE(NEW, OLD); -- service-role maintenance
    END IF;
    IF auth.uid() <> OLD.requester_id THEN
        RAISE EXCEPTION 'not_blocker' USING ERRCODE = 'P0001';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF NEW.status <> 'blocked'
           OR NEW.requester_id <> OLD.requester_id
           OR NEW.addressee_id <> OLD.addressee_id THEN
            RAISE EXCEPTION 'block_immutable' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS friendships_block_owner_update ON public.friendships;
CREATE TRIGGER friendships_block_owner_update
    BEFORE UPDATE ON public.friendships
    FOR EACH ROW
    EXECUTE FUNCTION public.assert_block_row_owner();

DROP TRIGGER IF EXISTS friendships_block_owner_delete ON public.friendships;
CREATE TRIGGER friendships_block_owner_delete
    BEFORE DELETE ON public.friendships
    FOR EACH ROW
    EXECUTE FUNCTION public.assert_block_row_owner();

REVOKE ALL ON FUNCTION public.assert_block_row_owner() FROM PUBLIC, anon, authenticated;

-- A blocked pair cannot create a NEW pending request. (Blocking itself is a
-- 'blocked' insert, handled by block_user().)
CREATE OR REPLACE FUNCTION public.assert_friendship_not_blocked()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    IF NEW.status IN ('pending', 'accepted')
       AND public.is_blocked_between(NEW.requester_id, NEW.addressee_id) THEN
        RAISE EXCEPTION 'BLOCKED' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS friendships_no_blocked_requests ON public.friendships;
CREATE TRIGGER friendships_no_blocked_requests
    BEFORE INSERT ON public.friendships
    FOR EACH ROW
    EXECUTE FUNCTION public.assert_friendship_not_blocked();

REVOKE ALL ON FUNCTION public.assert_friendship_not_blocked() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Invites: blocked pairs cannot invite each other (new rows only; existing
-- membership is untouched).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_event_invite_not_blocked()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    IF public.is_blocked_between(NEW.user_id, NEW.invited_by_user_id) THEN
        RAISE EXCEPTION 'BLOCKED' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS event_invites_no_blocked_trigger ON public.event_invites;
CREATE TRIGGER event_invites_no_blocked_trigger
    BEFORE INSERT ON public.event_invites
    FOR EACH ROW
    EXECUTE FUNCTION public.assert_event_invite_not_blocked();

REVOKE ALL ON FUNCTION public.assert_event_invite_not_blocked() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.assert_group_invite_not_blocked()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_actor uuid := auth.uid();
BEGIN
    IF NEW.status = 'invited'
       AND v_actor IS NOT NULL
       AND v_actor <> NEW.user_id
       AND public.is_blocked_between(v_actor, NEW.user_id) THEN
        RAISE EXCEPTION 'BLOCKED' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS group_members_no_blocked_trigger ON public.group_members;
CREATE TRIGGER group_members_no_blocked_trigger
    BEFORE INSERT OR UPDATE OF status ON public.group_members
    FOR EACH ROW
    EXECUTE FUNCTION public.assert_group_invite_not_blocked();

REVOKE ALL ON FUNCTION public.assert_group_invite_not_blocked() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.assert_minigame_invite_not_blocked()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    IF public.is_blocked_between(NEW.created_by, NEW.invitee_id) THEN
        RAISE EXCEPTION 'BLOCKED' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS minigame_invites_no_blocked_trigger ON public.minigame_invites;
CREATE TRIGGER minigame_invites_no_blocked_trigger
    BEFORE INSERT ON public.minigame_invites
    FOR EACH ROW
    EXECUTE FUNCTION public.assert_minigame_invite_not_blocked();

REVOKE ALL ON FUNCTION public.assert_minigame_invite_not_blocked() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Discovery/search/ranking filters. Block is symmetric; mute is the viewer's
-- one-way choice (the muted user is not told and does not see a different view).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.discovery_view WITH (security_barrier='true') AS
 SELECT id,
    username,
    avatar_url,
    interest_tags
   FROM public.users
  WHERE ((deleted_at IS NULL) AND (discovery_opt_in = true) AND (interest_tags <> '{}'::text[]) AND (NOT (EXISTS ( SELECT 1
           FROM public.friendships
          WHERE ((friendships.status = 'blocked'::public.friendship_status) AND (((friendships.requester_id = users.id) AND (friendships.addressee_id = auth.uid())) OR ((friendships.requester_id = auth.uid()) AND (friendships.addressee_id = users.id)))))))
    AND NOT EXISTS (
        SELECT 1 FROM public.user_mutes m
         WHERE m.muter_id = auth.uid() AND m.muted_id = users.id
    ));

CREATE OR REPLACE VIEW public.user_search_view WITH (security_barrier='true') AS
 SELECT u.id,
    u.username,
    CASE
        WHEN u.profile_public
          OR u.id = auth.uid()
          OR public.is_accepted_friend(auth.uid(), u.id)
        THEN u.avatar_url
        ELSE NULL
    END AS avatar_url,
    CASE
        WHEN u.profile_public
          OR u.id = auth.uid()
          OR public.is_accepted_friend(auth.uid(), u.id)
        THEN u.bio
        ELSE NULL
    END AS bio,
    u.profile_public
   FROM public.users u
  WHERE u.deleted_at IS NULL
    AND NOT EXISTS (
        SELECT 1
          FROM public.friendships f
         WHERE f.status = 'blocked'
           AND (
                (f.requester_id = u.id AND f.addressee_id = auth.uid())
                OR
                (f.requester_id = auth.uid() AND f.addressee_id = u.id)
           )
    )
    AND NOT EXISTS (
        SELECT 1 FROM public.user_mutes m
         WHERE m.muter_id = auth.uid() AND m.muted_id = u.id
    );

CREATE OR REPLACE FUNCTION public.get_user_ranking(p_limit integer DEFAULT 100)
RETURNS TABLE(user_id uuid, username text, avatar_url text, personal_shards bigint, profile_public boolean)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT
        u.id,
        u.username,
        u.avatar_url,
        u.personal_shards::bigint,
        u.profile_public
    FROM public.users u
    WHERE u.deleted_at IS NULL
      AND u.profile_public = true
      AND NOT public.is_hidden_between(auth.uid(), u.id)
    ORDER BY u.personal_shards DESC, u.username ASC
    LIMIT p_limit;
$$;

REVOKE ALL ON FUNCTION public.get_user_ranking(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_user_ranking(integer) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- search_events — 220/229 body plus the actor filter. Events created by a
-- blocked/muted user disappear from the viewer's feed; membership is untouched,
-- so the event still opens from a direct link for actual members.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.search_events(
    p_query text DEFAULT NULL,
    p_lat double precision DEFAULT NULL,
    p_lng double precision DEFAULT NULL,
    p_radius_km double precision DEFAULT NULL,
    p_limit integer DEFAULT 50
) RETURNS TABLE(
    id uuid,
    name text,
    description text,
    cover_url text,
    type public.event_type,
    status public.event_status,
    group_id uuid,
    location_name text,
    location_lat numeric,
    location_lng numeric,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    join_mode public.join_mode,
    preshards_pool integer,
    capacity integer,
    featured boolean,
    created_by_user_id uuid,
    distance_km double precision,
    friends_going integer,
    friends_pending integer,
    score double precision
)
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_current_user uuid;
    v_trimmed text;
    v_pattern text;
    v_has_query boolean;
    v_has_location boolean;
    v_radius double precision;
    v_count integer;
BEGIN
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = 'SR003',
            MESSAGE = 'not_authenticated';
    END IF;

    v_trimmed := btrim(coalesce(p_query, ''));
    v_has_query := char_length(v_trimmed) > 0;
    IF v_has_query
       AND (char_length(v_trimmed) < 2 OR char_length(v_trimmed) > 50) THEN
        RAISE EXCEPTION USING
            ERRCODE = 'SR002',
            MESSAGE = 'invalid_query_length';
    END IF;

    INSERT INTO public.search_rate_limits AS srl
        (user_id, window_start, search_count)
    VALUES (v_current_user, now(), 1)
    ON CONFLICT (user_id) DO UPDATE
        SET window_start = CASE
                WHEN srl.window_start < now() - interval '1 minute'
                    THEN EXCLUDED.window_start
                ELSE srl.window_start
            END,
            search_count = CASE
                WHEN srl.window_start < now() - interval '1 minute'
                    THEN 1
                ELSE srl.search_count + 1
            END
    RETURNING srl.search_count INTO v_count;

    IF v_count > 60 THEN
        RAISE EXCEPTION USING
            ERRCODE = 'SR001',
            MESSAGE = 'search_rate_limit_exceeded';
    END IF;

    v_has_location := p_lat IS NOT NULL AND p_lng IS NOT NULL;
    v_radius := least(greatest(coalesce(p_radius_km, 50), 1), 100);

    v_pattern := '%'
        || replace(replace(replace(v_trimmed, '\', '\\'), '%', '\%'), '_', '\_')
        || '%';

    RETURN QUERY
    WITH friend_ids AS (
        SELECT CASE
                   WHEN f.requester_id = v_current_user THEN f.addressee_id
                   ELSE f.requester_id
               END AS friend_id
          FROM public.friendships f
         WHERE f.status = 'accepted'
           AND (f.requester_id = v_current_user
                OR f.addressee_id = v_current_user)
    ),
    friend_counts AS (
        SELECT i.event_id,
               count(*) FILTER (
                   WHERE i.status IN ('accepted', 'attended')
               )::integer AS going,
               count(*) FILTER (
                   WHERE i.status = 'pending'
               )::integer AS pending
          FROM public.event_invites i
          JOIN friend_ids fi ON fi.friend_id = i.user_id
         GROUP BY i.event_id
    )
    SELECT e.id,
           e.name,
           e.description,
           e.cover_url,
           e.type,
           e.status,
           e.group_id,
           CASE
               WHEN EXISTS (
                        SELECT 1 FROM public.event_hosts h
                        WHERE h.event_id = e.id AND h.user_id = v_current_user
                    )
                 OR EXISTS (
                        SELECT 1 FROM public.event_invites i
                        WHERE i.event_id = e.id
                          AND i.user_id = v_current_user
                          AND i.status IN ('accepted', 'attended')
                    )
               THEN e.location_name
               ELSE NULL
           END AS location_name,
           NULL::numeric AS location_lat,
           NULL::numeric AS location_lng,
           e.starts_at,
           e.ends_at,
           e.join_mode,
           e.preshards_pool,
           e.capacity,
           e.featured,
           e.created_by_user_id,
           CASE
               WHEN v_has_location
                 AND (
                        EXISTS (
                            SELECT 1 FROM public.event_hosts h
                            WHERE h.event_id = e.id AND h.user_id = v_current_user
                        )
                     OR EXISTS (
                            SELECT 1 FROM public.event_invites i
                            WHERE i.event_id = e.id
                              AND i.user_id = v_current_user
                              AND i.status IN ('accepted', 'attended')
                        )
                 )
               THEN public.haversine_km(
                        p_lat, p_lng,
                        e.location_lat::double precision,
                        e.location_lng::double precision)
           END AS distance_km,
           coalesce(fc.going, 0) AS friends_going,
           coalesce(fc.pending, 0) AS friends_pending,
           (coalesce(fc.going, 0) + 0.5 * coalesce(fc.pending, 0))
               ::double precision AS score
      FROM public.events e
      LEFT JOIN friend_counts fc ON fc.event_id = e.id
     WHERE e.status IN ('upcoming', 'live')
       AND NOT public.is_hidden_between(v_current_user, e.created_by_user_id)
       AND (
               e.group_id IS NULL
               OR EXISTS (
                   SELECT 1 FROM public.group_members gm
                    WHERE gm.group_id = e.group_id
                      AND gm.user_id = v_current_user
                      AND gm.status = 'active'
               )
               OR EXISTS (
                   SELECT 1 FROM public.event_invites ei
                    WHERE ei.event_id = e.id
                      AND ei.user_id = v_current_user
                      AND ei.status IN ('accepted', 'attended')
               )
               OR EXISTS (
                   SELECT 1 FROM public.event_hosts eh
                    WHERE eh.event_id = e.id
                      AND eh.user_id = v_current_user
               )
           )
       AND (
               NOT v_has_query
               OR e.name ILIKE v_pattern
               OR e.location_name ILIKE v_pattern
               OR e.description ILIKE v_pattern
           )
       AND (
               NOT v_has_location
               OR (e.location_lat IS NOT NULL
                   AND e.location_lng IS NOT NULL
                   AND public.haversine_km(
                           p_lat, p_lng,
                           e.location_lat::double precision,
                           e.location_lng::double precision) <= v_radius)
           )
     ORDER BY score DESC,
              distance_km ASC NULLS LAST,
              e.starts_at ASC
     LIMIT least(greatest(coalesce(p_limit, 50), 1), 50);
END;
$$;

REVOKE ALL ON FUNCTION public.search_events(text, double precision, double precision, double precision, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.search_events(text, double precision, double precision, double precision, integer) TO authenticated, service_role;
