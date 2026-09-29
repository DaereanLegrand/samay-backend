-- ============================================================================
-- 220_events_search_past_last — los eventos que ya pasaron van al final.
--
-- `search_events` (131) ordenaba por actividad de amigos, distancia y fecha,
-- sin mirar si el evento ya habia terminado. Como un evento pasado suele
-- acumular mas asistencias que uno por venir, la pestana Eventos abria
-- mostrando FINALIZADO en las tres primeras tarjetas: lo primero que ve el
-- usuario es lo unico a lo que ya no puede ir.
--
-- No se filtran (siguen siendo alcanzables: llevan fotos y recuerdos), solo
-- se hunden por debajo de los vigentes. El resto del orden no cambia.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.search_events(p_query text DEFAULT NULL::text, p_lat double precision DEFAULT NULL::double precision, p_lng double precision DEFAULT NULL::double precision, p_radius_km double precision DEFAULT NULL::double precision, p_limit integer DEFAULT 50)
 RETURNS TABLE(id uuid, name text, description text, cover_url text, type event_type, status event_status, group_id uuid, location_name text, location_lat numeric, location_lng numeric, starts_at timestamp with time zone, ends_at timestamp with time zone, join_mode join_mode, preshards_pool integer, capacity integer, featured boolean, created_by_user_id uuid, distance_km double precision, friends_going integer, friends_pending integer, score double precision)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_current_user uuid;
    v_trimmed text;
    v_pattern text;
    v_has_query boolean;
    v_has_location boolean;
    v_radius double precision;
    v_count integer;
BEGIN
    -- 1. Authentication gate (auth.uid() = NULL for anon / expired session).
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = 'SR003',
            MESSAGE = 'not_authenticated';
    END IF;

    -- 2. Input validation (client sanitization is bypassable — enforce caps
    --    server-side). Event names can be short, so the minimum is 2.
    v_trimmed := btrim(coalesce(p_query, ''));
    v_has_query := char_length(v_trimmed) > 0;
    IF v_has_query
       AND (char_length(v_trimmed) < 2 OR char_length(v_trimmed) > 50) THEN
        RAISE EXCEPTION USING
            ERRCODE = 'SR002',
            MESSAGE = 'invalid_query_length';
    END IF;

    -- 3. Shared per-user quota: 60 searches per rolling minute (the same
    --    budget as search_users; atomic upsert resets an expired window).
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

    -- 4. Distance filter inputs. The radius is HARD-CAPPED at 100 km — even a
    --    user-supplied reference location (e.g. NYC) is only searched within
    --    100 km of that point. Missing radius defaults to 50 km.
    v_has_location := p_lat IS NOT NULL AND p_lng IS NOT NULL;
    v_radius := least(greatest(coalesce(p_radius_km, 50), 1), 100);

    -- 5. Escaped substring pattern for the text search.
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
           e.location_name,
           e.location_lat,
           e.location_lng,
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
     WHERE (
               e.group_id IS NULL
               OR EXISTS (
                   SELECT 1 FROM public.group_members gm
                    WHERE gm.group_id = e.group_id
                      AND gm.user_id = v_current_user)
               OR EXISTS (
                   SELECT 1 FROM public.event_invites ei
                    WHERE ei.event_id = e.id
                      AND ei.user_id = v_current_user)
               OR EXISTS (
                   SELECT 1 FROM public.event_hosts eh
                    WHERE eh.event_id = e.id
                      AND eh.user_id = v_current_user)
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
     ORDER BY (e.status IN ('ended', 'cancelled')
               OR e.ends_at < now()) ASC,
              score DESC,
              distance_km ASC NULLS LAST,
              e.starts_at ASC
     LIMIT least(greatest(coalesce(p_limit, 50), 1), 50);
END;
$function$

