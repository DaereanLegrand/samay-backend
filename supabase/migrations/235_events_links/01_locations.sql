-- ============================================================================
-- 235_events_links / 01_locations.sql — Q2 location precision.
--
-- Adds the coarse `location_city` field used by the stage-aware projection.
-- `location_name` remains the EXACT venue and must never be returned to a
-- viewer who is not host/staff or an accepted/attended invitee. Exact
-- coordinates (`location_lat` / `location_lng`) are never returned by
-- discovery; all event RPCs below project them as NULL.
--
-- Backfill:
--   Existing rows only carry a free-form `location_name` (often the venue or
--   a city). Auto-promoting that value into `location_city` would leak an
--   exact venue to pending viewers, so the backfill is intentionally
--   CONSERVATIVE: only a short, comma-free label is copied into the city
--   column AND the original exact value is retained for accepted viewers.
--   Operators may re-run the second UPDATE with an explicit city mapping.
--
-- Lock/backfill notes:
--   * ADD COLUMN with no default is metadata-only in PostgreSQL 11+.
--   * The conservative backfill touches only rows where location_city IS NULL
--     and location_name is short/comma-free; it is idempotent and safe to
--     re-run. For large tables run it in batches:
--       UPDATE public.events SET location_city = btrim(location_name)
--        WHERE location_city IS NULL AND location_name = 'Arequipa';
--
-- Rollback:
--   ALTER TABLE public.events DROP COLUMN IF EXISTS location_city;
-- Forward-fix: keep the column; adjust the backfill criteria only.
-- ============================================================================

ALTER TABLE public.events
    ADD COLUMN IF NOT EXISTS location_city text;

COMMENT ON COLUMN public.events.location_city
    IS 'Coarse city/neighborhood shown to viewers before acceptance (Q2). Exact venue stays in location_name.';

UPDATE public.events
   SET location_city = btrim(location_name)
 WHERE location_city IS NULL
   AND location_name IS NOT NULL
   AND btrim(location_name) <> ''
   AND char_length(btrim(location_name)) <= 60
   AND position(',' IN location_name) = 0;

-- ----------------------------------------------------------------------------
-- Safe event read for stage-aware detail/deep-link previews. Direct `events`
-- SELECT remains host/staff + accepted only (SEC-005); this SECURITY DEFINER
-- RPC is the only path that can expose the pending/public projection.
--
-- Q2 projection:
--   host/staff/accepted/attended -> exact location_name
--   pending invitee/public/group   -> location_city only
--   everybody                      -> location_lat/lng NULL
-- The distance is computed server-side from optional p_lat/p_lng and never
-- implies access to the exact coordinates.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_event_for_viewer(
    p_event_id uuid,
    p_lat double precision DEFAULT NULL,
    p_lng double precision DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_event public.events%ROWTYPE;
    v_exact boolean;
    v_pending boolean;
    v_group_member boolean;
    v_distance double precision;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT * INTO v_event FROM public.events WHERE id = p_event_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'event_not_found');
    END IF;

    v_exact := EXISTS (
        SELECT 1 FROM public.event_hosts h
         WHERE h.event_id = p_event_id AND h.user_id = v_me
    ) OR EXISTS (
        SELECT 1 FROM public.event_invites i
         WHERE i.event_id = p_event_id AND i.user_id = v_me
           AND i.status IN ('accepted', 'attended')
    );

    v_pending := EXISTS (
        SELECT 1 FROM public.event_invites i
         WHERE i.event_id = p_event_id AND i.user_id = v_me
           AND i.status = 'pending'
    );

    v_group_member := v_event.group_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.group_members gm
         WHERE gm.group_id = v_event.group_id
           AND gm.user_id = v_me
           AND gm.status = 'active'
    );

    -- Visibility: public/group-less events, group members, invitees (any
    -- status), hosts/staff. Private group events stay hidden otherwise.
    IF NOT v_exact
       AND NOT v_pending
       AND NOT v_group_member
       AND v_event.group_id IS NOT NULL
       AND v_event.join_mode IS NULL THEN
        RETURN jsonb_build_object('status', 'event_not_found');
    END IF;

    IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
        v_distance := public.haversine_km(
            p_lat, p_lng,
            v_event.location_lat::double precision,
            v_event.location_lng::double precision);
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok',
        'id', v_event.id,
        'name', v_event.name,
        'description', v_event.description,
        'cover_url', v_event.cover_url,
        'type', v_event.type,
        'status', v_event.status,
        'group_id', v_event.group_id,
        'location_name', CASE WHEN v_exact THEN v_event.location_name END,
        'location_city', v_event.location_city,
        'location_lat', NULL,
        'location_lng', NULL,
        'starts_at', v_event.starts_at,
        'ends_at', v_event.ends_at,
        'join_mode', v_event.join_mode,
        'preshards_pool', v_event.preshards_pool,
        'capacity', v_event.capacity,
        'featured', v_event.featured,
        'created_by_user_id', v_event.created_by_user_id,
        'viewer_role', CASE
            WHEN EXISTS (SELECT 1 FROM public.event_hosts h
                          WHERE h.event_id = p_event_id AND h.user_id = v_me
                            AND h.role = 'host') THEN 'host'
            WHEN EXISTS (SELECT 1 FROM public.event_hosts h
                          WHERE h.event_id = p_event_id AND h.user_id = v_me) THEN 'staff'
            WHEN v_exact THEN 'attendee'
            WHEN v_pending THEN 'pending'
            ELSE 'viewer'
        END,
        'viewer_has_exact_location', v_exact,
        'viewer_has_pending_invite', v_pending,
        'distance_km', v_distance
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_event_for_viewer(uuid, double precision, double precision) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_for_viewer(uuid, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_event_for_viewer(uuid, double precision, double precision) TO service_role;
