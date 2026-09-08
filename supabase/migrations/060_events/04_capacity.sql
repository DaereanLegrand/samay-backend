-- Samay — 060_events/04_capacity.sql
--
-- Attendee capacity (Stage 1, 2026-09-08):
--   * events.capacity is the total headcount (host + staff + guests),
--     frozen at creation and capped by the creator's `entitlement_tier`
--     via app_config (`events.{free,t2,t1,t0}_max_attendees`).
--   * Seat accounting is centralized in `event_seats_used`.
--   * `create_event` is the SECURITY DEFINER creation path (atomic
--     events + event_hosts + chats inserts); clients no longer perform
--     the three-table insert themselves.

--
-- Name: event_seats_used(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_seats_used(p_event_id uuid) RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT
        (SELECT count(*)::integer FROM public.event_hosts WHERE event_id = p_event_id)
        + (SELECT count(*)::integer FROM public.event_invites
           WHERE event_id = p_event_id
             AND status IN ('accepted'::public.invite_status, 'attended'::public.invite_status))
$$;


--
-- Name: assert_event_capacity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assert_event_capacity() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_allowed integer;
    v_used integer;
BEGIN
    -- The tier cap comes from app_config, keyed on the CREATOR's current
    -- entitlement_tier (defaults: free=7). Runs for every insert path
    -- (RPC, service_role seeds, admin), so capacity can never exceed tier.
    SELECT COALESCE(value::integer, 7) INTO v_allowed
    FROM public.app_config
    WHERE key = (
        SELECT CASE (
            SELECT entitlement_tier FROM public.users WHERE id = NEW.created_by_user_id
        )
            WHEN 't2'::public.entitlement_tier THEN 'events.t2_max_attendees'
            WHEN 't1'::public.entitlement_tier THEN 'events.t1_max_attendees'
            WHEN 't0'::public.entitlement_tier THEN 'events.t0_max_attendees'
            ELSE 'events.free_max_attendees'
        END
    );

    -- No matching row (unknown creator or unseeded key) — fall back to 7.
    IF v_allowed IS NULL THEN
        v_allowed := 7;
    END IF;

    IF NEW.capacity IS NULL THEN
        NEW.capacity := v_allowed;
    ELSIF NEW.capacity < 1 OR NEW.capacity > v_allowed THEN
        RAISE EXCEPTION 'capacity_exceeds_tier'
            USING ERRCODE = 'P0001';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        v_used := public.event_seats_used(NEW.id);
        IF NEW.capacity < v_used THEN
            RAISE EXCEPTION 'capacity_below_used'
                USING ERRCODE = 'P0001';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: events assert_event_capacity_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER assert_event_capacity_trigger BEFORE INSERT OR UPDATE OF capacity ON public.events FOR EACH ROW EXECUTE FUNCTION public.assert_event_capacity();


--
-- Name: create_event(text, text, event_type, text, uuid, text, numeric, numeric, timestamp with time zone, timestamp with time zone, join_mode, integer, integer, preshard_remainder_action, integer); Type: FUNCTION; Schema: public; Owner: -
--

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
    p_capacity integer
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
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

    INSERT INTO public.events (
        id, name, description, cover_url, type, created_by_user_id, group_id,
        location_name, location_lat, location_lng, starts_at, ends_at,
        join_mode, preshards_pool, preshards_cap_per_user,
        preshards_remainder_action, dynamic_qr_enabled, capacity, invite_token,
        status, created_at, updated_at
    ) VALUES (
        v_event_id, btrim(p_name), NULLIF(btrim(p_description), ''), p_cover_url,
        p_type, v_me, p_group_id, NULLIF(btrim(p_location_name), ''),
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


--
-- Name: FUNCTION create_event(...); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_event(
    text, text, public.event_type, text, uuid, text, numeric, numeric,
    timestamp with time zone, timestamp with time zone, public.join_mode,
    integer, integer, public.preshard_remainder_action, integer
) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_event(
    text, text, public.event_type, text, uuid, text, numeric, numeric,
    timestamp with time zone, timestamp with time zone, public.join_mode,
    integer, integer, public.preshard_remainder_action, integer
) TO authenticated;
GRANT ALL ON FUNCTION public.create_event(
    text, text, public.event_type, text, uuid, text, numeric, numeric,
    timestamp with time zone, timestamp with time zone, public.join_mode,
    integer, integer, public.preshard_remainder_action, integer
) TO service_role;
