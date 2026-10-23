-- ============================================================================
-- 235_events_links / 04_projection.sql — Q2 in discovery + creation.
--
-- search_events (replaces 229/220):
--   * NEVER returns location_lat/location_lng (always NULL)
--   * returns location_city to every eligible viewer
--   * returns the exact location_name only to host/staff or an accepted/
--     attended invitee
--   * returns distance_km to every viewer (city + distance before acceptance)
--   * keeps the past-last ordering introduced by 220
--
-- create_event gains p_location_city (default NULL) as the coarse field.
-- The old 15-argument overload is dropped so PostgREST resolves to exactly
-- one function; existing callers that pass 15 named arguments keep working
-- through the new default.
--
-- Rollback:
--   DROP FUNCTION create_event(..., text); then recreate the 15-argument
--   definition from 229_wave0_trust_boundary/01_trust_boundary.sql.
--   DROP FUNCTION search_events(...); then recreate from 220.
-- Forward-fix: never restore coordinates to the discovery projection.
-- ============================================================================

DROP FUNCTION IF EXISTS public.search_events(
    text, double precision, double precision, double precision, integer
);

CREATE FUNCTION public.search_events(
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
    location_city text,
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
               WHEN EXISTS (SELECT 1 FROM public.event_hosts h
                             WHERE h.event_id = e.id AND h.user_id = v_current_user)
                 OR EXISTS (SELECT 1 FROM public.event_invites i
                             WHERE i.event_id = e.id AND i.user_id = v_current_user
                               AND i.status IN ('accepted', 'attended'))
               THEN e.location_name
           END AS location_name,
           e.location_city,
           NULL::numeric AS location_lat,
           NULL::numeric AS location_lng,
           e.starts_at,
           e.ends_at,
           e.join_mode,
           e.preshards_pool,
           e.capacity,
           e.featured,
           e.created_by_user_id,
           CASE WHEN v_has_location
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
       AND (
               e.group_id IS NULL
               OR EXISTS (SELECT 1 FROM public.group_members gm
                           WHERE gm.group_id = e.group_id
                             AND gm.user_id = v_current_user
                             AND gm.status = 'active')
               OR EXISTS (SELECT 1 FROM public.event_invites ei
                           WHERE ei.event_id = e.id
                             AND ei.user_id = v_current_user)
               OR EXISTS (SELECT 1 FROM public.event_hosts eh
                           WHERE eh.event_id = e.id
                             AND eh.user_id = v_current_user)
           )
       AND (
               NOT v_has_query
               OR e.name ILIKE v_pattern
               OR e.location_name ILIKE v_pattern
               OR e.location_city ILIKE v_pattern
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
     ORDER BY (e.status IN ('ended', 'cancelled')
               OR e.ends_at < now()) ASC,
              score DESC,
              distance_km ASC NULLS LAST,
              e.starts_at ASC
     LIMIT least(greatest(coalesce(p_limit, 50), 1), 50);
END;
$$;

REVOKE ALL ON FUNCTION public.search_events(text, double precision, double precision, double precision, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_events(text, double precision, double precision, double precision, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_events(text, double precision, double precision, double precision, integer) TO service_role;

-- ----------------------------------------------------------------------------
-- create_event + location_city
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_event(
    text, text, public.event_type, text, uuid, text, numeric, numeric,
    timestamp with time zone, timestamp with time zone, public.join_mode,
    integer, integer, public.preshard_remainder_action, integer
);

CREATE FUNCTION public.create_event(
    p_name text,
    p_description text,
    p_type public.event_type,
    p_cover_url text,
    p_group_id uuid,
    p_location_name text,
    p_location_lat numeric,
    p_location_lng numeric,
    p_starts_at timestamp with time zone,
    p_ends_at timestamp with time zone,
    p_join_mode public.join_mode,
    p_preshards_pool integer,
    p_preshards_cap_per_user integer,
    p_preshards_remainder_action public.preshard_remainder_action,
    p_capacity integer,
    p_location_city text DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_event_id uuid := gen_random_uuid();
    v_pool integer := COALESCE(p_preshards_pool, 0);
    v_now timestamp with time zone := now();
    v_invite_token text := (gen_random_uuid())::text;
BEGIN
    IF v_me IS NULL THEN
        RAISE EXCEPTION 'not_authenticated' USING ERRCODE = 'P0001';
    END IF;
    IF p_name IS NULL OR btrim(p_name) = '' THEN
        RAISE EXCEPTION 'name_required' USING ERRCODE = 'P0001';
    END IF;
    IF p_ends_at <= p_starts_at THEN
        RAISE EXCEPTION 'invalid_time_range' USING ERRCODE = 'P0001';
    END IF;
    IF p_type = 'casual'::public.event_type AND v_pool <> 0 THEN
        RAISE EXCEPTION 'casual_pool_forbidden' USING ERRCODE = 'P0001';
    END IF;
    IF v_pool < 0 THEN
        RAISE EXCEPTION 'invalid_pool' USING ERRCODE = 'P0001';
    END IF;
    IF p_location_city IS NOT NULL AND char_length(btrim(p_location_city)) > 120 THEN
        RAISE EXCEPTION 'city_too_long' USING ERRCODE = 'P0001';
    END IF;

    IF p_group_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.group_members
        WHERE group_id = p_group_id
          AND user_id = v_me
          AND status = 'active'
    ) THEN
        RAISE EXCEPTION 'not_a_group_member' USING ERRCODE = 'P0001';
    END IF;

    IF v_pool > 0 THEN
        UPDATE public.users
           SET preshards = preshards - v_pool
         WHERE id = v_me
           AND preshards >= v_pool;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'insufficient_preshards' USING ERRCODE = 'P0001';
        END IF;
        INSERT INTO public.preshard_ledger (user_id, delta, reason, reference_id)
        VALUES (v_me, -v_pool, 'event_pool_set', v_event_id);
    END IF;

    INSERT INTO public.events (
        id, name, description, cover_url, type, created_by_user_id, group_id,
        location_name, location_city, location_lat, location_lng,
        starts_at, ends_at,
        join_mode, preshards_pool, preshards_cap_per_user,
        preshards_remainder_action, dynamic_qr_enabled, capacity, invite_token,
        status, created_at, updated_at
    ) VALUES (
        v_event_id, btrim(p_name), NULLIF(btrim(p_description), ''), p_cover_url,
        p_type, v_me, p_group_id, NULLIF(btrim(p_location_name), ''),
        NULLIF(btrim(p_location_city), ''),
        p_location_lat, p_location_lng, p_starts_at, p_ends_at, p_join_mode,
        v_pool, p_preshards_cap_per_user, p_preshards_remainder_action,
        v_pool > 0, p_capacity, v_invite_token,
        'upcoming', v_now, v_now
    );

    INSERT INTO public.event_hosts (
        event_id, user_id, role, preshards_contributed, added_at
    ) VALUES (
        v_event_id, v_me, 'host'::public.event_role, v_pool, v_now
    );

    INSERT INTO public.chats (type, reference_id, created_at)
    VALUES ('event'::public.chat_type, v_event_id, v_now);

    RETURN jsonb_build_object(
        'status', 'ok',
        'id', v_event_id,
        'inviteToken', v_invite_token
    );
END;
$$;

REVOKE ALL ON FUNCTION public.create_event(
    text, text, public.event_type, text, uuid, text, numeric, numeric,
    timestamp with time zone, timestamp with time zone, public.join_mode,
    integer, integer, public.preshard_remainder_action, integer, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_event(
    text, text, public.event_type, text, uuid, text, numeric, numeric,
    timestamp with time zone, timestamp with time zone, public.join_mode,
    integer, integer, public.preshard_remainder_action, integer, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_event(
    text, text, public.event_type, text, uuid, text, numeric, numeric,
    timestamp with time zone, timestamp with time zone, public.join_mode,
    integer, integer, public.preshard_remainder_action, integer, text
) TO service_role;
