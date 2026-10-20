-- ============================================================================
-- 229_wave0_trust_boundary — Wave 0 database trust-boundary fixes.
--
-- Scope (local/testing only; staging is frozen):
--   SEC-001  writeable views
--   SEC-002  negative shard minting
--   SEC-003  cosmetic purchase authority
--   SEC-004  early minigame settlement / abandonment refunds
--   SEC-005  event reads, exact location, discovery projection
--   SEC-006  friendship transitions and block ownership
--   SEC-007  event creation membership + preshard escrow
--   SEC-010  event photo upload gate
--
-- Security-first: direct client write paths are revoked where a validated RPC
-- is the intended write path. Old local clients are allowed to break.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- SEC-001 — views over users must never be client-writable.
-- The views intentionally expose a safe column projection while running with
-- owner rights; security_invoker would collapse them to the caller's own row
-- because public.users RLS is own-row-only. Revoke DML and anon reads instead.
-- ----------------------------------------------------------------------------
REVOKE ALL ON TABLE public.discovery_view FROM anon;
REVOKE ALL ON TABLE public.discovery_view FROM authenticated;
GRANT SELECT ON TABLE public.discovery_view TO authenticated;

REVOKE ALL ON TABLE public.user_search_view FROM anon;
REVOKE ALL ON TABLE public.user_search_view FROM authenticated;
GRANT SELECT ON TABLE public.user_search_view TO authenticated;

-- ----------------------------------------------------------------------------
-- SEC-002 — no negative/zero donations and no client ledger minting.
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'users_personal_shards_nonnegative'
    ) THEN
        ALTER TABLE public.users
            ADD CONSTRAINT users_personal_shards_nonnegative
            CHECK (personal_shards >= 0) NOT VALID;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'users_preshards_nonnegative'
    ) THEN
        ALTER TABLE public.users
            ADD CONSTRAINT users_preshards_nonnegative
            CHECK (preshards >= 0) NOT VALID;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'group_shard_contributions_positive'
    ) THEN
        ALTER TABLE public.group_shard_contributions
            ADD CONSTRAINT group_shard_contributions_positive
            CHECK (shards_contributed > 0) NOT VALID;
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.donate_shards_to_group(
    p_group_id uuid,
    p_user_id uuid,
    p_amount integer,
    p_expires_at timestamp with time zone
) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_expires timestamp with time zone;
BEGIN
    IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
        RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'invalid_amount' USING ERRCODE = 'P0001';
    END IF;
    IF p_expires_at IS NOT NULL AND p_expires_at <= now() THEN
        RAISE EXCEPTION 'invalid_expiry' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.group_members
        WHERE group_id = p_group_id
          AND user_id = p_user_id
          AND status = 'active'
    ) THEN
        RAISE EXCEPTION 'not_a_member' USING ERRCODE = 'P0001';
    END IF;

    v_expires := least(
        coalesce(p_expires_at, now() + interval '14 days'),
        now() + interval '30 days'
    );

    UPDATE public.users
       SET personal_shards = personal_shards - p_amount
     WHERE id = p_user_id
       AND personal_shards >= p_amount;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'insufficient_shards' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
    VALUES (p_user_id, -p_amount, 'group_donation', p_group_id);

    INSERT INTO public.group_shard_contributions
        (group_id, user_id, shards_contributed, expires_at)
    VALUES (p_group_id, p_user_id, p_amount, v_expires);
END;
$$;

REVOKE ALL ON FUNCTION public.donate_shards_to_group(uuid, uuid, integer, timestamp with time zone) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.donate_shards_to_group(uuid, uuid, integer, timestamp with time zone) TO authenticated;

REVOKE INSERT, UPDATE, DELETE ON TABLE public.shard_ledger FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.shard_ledger FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.preshard_ledger FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.preshard_ledger FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.group_shard_contributions FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.group_shard_contributions FROM authenticated;
DROP POLICY IF EXISTS sl_insert_own ON public.shard_ledger;

-- ----------------------------------------------------------------------------
-- SEC-003 — server-authoritative cosmetic purchase.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.subscription_tier_rank(p_tier public.subscription_tier)
RETURNS integer
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
    SELECT CASE p_tier
        WHEN 'free'::public.subscription_tier THEN 0
        WHEN 'pro'::public.subscription_tier THEN 1
        WHEN 'vip'::public.subscription_tier THEN 2
        ELSE -1
    END;
$$;

CREATE OR REPLACE FUNCTION public.purchase_cosmetic(p_cosmetic_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_cost integer;
    v_required public.subscription_tier;
    v_tier public.subscription_tier;
    v_balance integer;
BEGIN
    IF v_me IS NULL THEN
        RAISE EXCEPTION 'not_authenticated' USING ERRCODE = 'P0001';
    END IF;

    SELECT shard_cost, tier_requirement
      INTO v_cost, v_required
      FROM public.cosmetics
     WHERE id = p_cosmetic_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'cosmetic_not_found' USING ERRCODE = 'P0001';
    END IF;

    SELECT subscription_tier, personal_shards
      INTO v_tier, v_balance
      FROM public.users
     WHERE id = v_me
       FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'user_not_found' USING ERRCODE = 'P0001';
    END IF;

    IF public.subscription_tier_rank(v_tier) < public.subscription_tier_rank(v_required) THEN
        RAISE EXCEPTION 'tier_required' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.user_cosmetics
        WHERE user_id = v_me AND cosmetic_id = p_cosmetic_id
    ) THEN
        RAISE EXCEPTION 'already_owned' USING ERRCODE = 'P0001';
    END IF;
    IF v_balance < v_cost THEN
        RAISE EXCEPTION 'insufficient_shards' USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.users
       SET personal_shards = personal_shards - v_cost
     WHERE id = v_me;

    INSERT INTO public.user_cosmetics (user_id, cosmetic_id, equipped, purchased_at)
    VALUES (v_me, p_cosmetic_id, false, now());

    INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
    VALUES (v_me, -v_cost, 'cosmetic_purchase', p_cosmetic_id);

    RETURN jsonb_build_object('status', 'ok', 'balance', v_balance - v_cost);
END;
$$;

REVOKE ALL ON FUNCTION public.subscription_tier_rank(public.subscription_tier) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.subscription_tier_rank(public.subscription_tier) TO authenticated;
REVOKE ALL ON FUNCTION public.purchase_cosmetic(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purchase_cosmetic(uuid) TO authenticated;

REVOKE INSERT, UPDATE, DELETE ON TABLE public.user_cosmetics FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.user_cosmetics FROM authenticated;
REVOKE ALL ON TABLE public.user_cosmetics FROM anon;
GRANT SELECT ON TABLE public.user_cosmetics TO authenticated;
GRANT UPDATE (equipped) ON TABLE public.user_cosmetics TO authenticated;
DROP POLICY IF EXISTS user_cosmetics_insert_own ON public.user_cosmetics;

-- ----------------------------------------------------------------------------
-- SEC-004 — settlement is server-only; abandonment refunds follow owner rules.
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.finish_minigame_game(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.finish_minigame_game(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.abandon_minigame_game(p_session_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_status public.mini_game_status;
    v_participants uuid[];
    v_wager integer;
    v_state jsonb;
    v_abandoned jsonb;
    v_host uuid;
    v_non_host uuid[];
    v_all_abandoned boolean;
    v_p uuid;
    v_count integer;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT status, participants, shard_wager
      INTO v_status, v_participants, v_wager
      FROM public.minigame_sessions
     WHERE id = p_session_id
       FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'already_finished');
    END IF;
    IF NOT (v_me = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    SELECT state INTO v_state
      FROM public.minigame_game_state
     WHERE session_id = p_session_id
       FOR UPDATE;
    v_abandoned := COALESCE(v_state -> 'abandoned', '[]'::jsonb);
    IF NOT (v_abandoned ? v_me::text) THEN
        v_abandoned := v_abandoned || to_jsonb(v_me);
    END IF;

    v_host := v_participants[1];
    SELECT COALESCE(array_agg(u), '{}'::uuid[])
      INTO v_non_host
      FROM unnest(v_participants) AS u
     WHERE u <> v_host;

    v_all_abandoned := (v_me = v_host) OR NOT EXISTS (
        SELECT 1 FROM unnest(v_non_host) AS u
        WHERE NOT (v_abandoned ? u::text)
    );

    IF v_all_abandoned THEN
        v_count := COALESCE(array_length(v_participants, 1), 0);
        IF v_wager > 0 THEN
            FOREACH v_p IN ARRAY v_participants LOOP
                UPDATE public.users
                   SET personal_shards = personal_shards + v_wager
                 WHERE id = v_p;
                INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
                VALUES (v_p, v_wager, 'minigame_refund', p_session_id);
            END LOOP;
        END IF;

        UPDATE public.minigame_sessions
           SET status = 'finished'
         WHERE id = p_session_id;

        UPDATE public.minigame_game_state
           SET state = COALESCE(state, '{}'::jsonb) || jsonb_build_object(
                   'phase', 'finished',
                   'abandoned', true,
                   'result', 'abandoned',
                   'abandoned_by', v_abandoned
               )
         WHERE session_id = p_session_id;

        RETURN jsonb_build_object(
            'status', 'abandoned',
            'refunded', v_wager * v_count
        );
    END IF;

    UPDATE public.minigame_game_state
       SET state = COALESCE(state, '{}'::jsonb) || jsonb_build_object(
               'abandoned', v_abandoned
           )
     WHERE session_id = p_session_id;

    RETURN jsonb_build_object('status', 'recorded', 'abandoned', v_abandoned);
END;
$$;

REVOKE ALL ON FUNCTION public.abandon_minigame_game(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.abandon_minigame_game(uuid) TO authenticated;

-- ----------------------------------------------------------------------------
-- SEC-005 — event reads: only hosts/staff and accepted attendees see the row.
-- Group members use search_events' safe discovery projection instead.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS events_read_access ON public.events;
CREATE POLICY events_read_access ON public.events
    FOR SELECT USING (
        auth.uid() IS NOT NULL
        AND (
            EXISTS (
                SELECT 1 FROM public.event_hosts h
                WHERE h.event_id = events.id
                  AND h.user_id = auth.uid()
            )
            OR EXISTS (
                SELECT 1 FROM public.event_invites i
                WHERE i.event_id = events.id
                  AND i.user_id = auth.uid()
                  AND i.status IN ('accepted', 'attended')
            )
        )
    );

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

REVOKE ALL ON FUNCTION public.search_events(text, double precision, double precision, double precision, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_events(text, double precision, double precision, double precision, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_events(text, double precision, double precision, double precision, integer) TO service_role;

-- ----------------------------------------------------------------------------
-- SEC-006 — friendship state transitions and block ownership.
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'friendships_distinct_parties'
    ) THEN
        ALTER TABLE public.friendships
            ADD CONSTRAINT friendships_distinct_parties
            CHECK (requester_id <> addressee_id) NOT VALID;
    END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS friendships_unique_pair
    ON public.friendships (
        least(requester_id, addressee_id),
        greatest(requester_id, addressee_id)
    );

CREATE OR REPLACE FUNCTION public.assert_safe_friendship_update()
RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    IF NEW.requester_id <> OLD.requester_id
       OR NEW.addressee_id <> OLD.addressee_id THEN
        RAISE EXCEPTION 'friendship_parties_immutable' USING ERRCODE = 'P0001';
    END IF;

    IF OLD.status = 'blocked' THEN
        IF auth.uid() <> OLD.requester_id THEN
            RAISE EXCEPTION 'not_blocker' USING ERRCODE = 'P0001';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF OLD.status = 'pending'
           AND NEW.status = 'accepted'
           AND auth.uid() = OLD.addressee_id THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'invalid_friendship_transition' USING ERRCODE = 'P0001';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS friendships_safe_update_trigger ON public.friendships;
CREATE TRIGGER friendships_safe_update_trigger
    BEFORE UPDATE ON public.friendships
    FOR EACH ROW
    EXECUTE FUNCTION public.assert_safe_friendship_update();

DROP POLICY IF EXISTS friendships_insert_own ON public.friendships;
CREATE POLICY friendships_insert_own ON public.friendships
    FOR INSERT WITH CHECK (
        requester_id = auth.uid()
        AND addressee_id <> auth.uid()
        AND status IN ('pending', 'blocked')
    );

DROP POLICY IF EXISTS friendships_update_own ON public.friendships;
CREATE POLICY friendships_update_own ON public.friendships
    FOR UPDATE USING (
        addressee_id = auth.uid()
        AND status = 'pending'
    ) WITH CHECK (
        addressee_id = auth.uid()
        AND status = 'accepted'
    );

DROP POLICY IF EXISTS friendships_delete_own ON public.friendships;
CREATE POLICY friendships_delete_own ON public.friendships
    FOR DELETE USING (
        (status = 'blocked' AND requester_id = auth.uid())
        OR (status <> 'blocked' AND (requester_id = auth.uid() OR addressee_id = auth.uid()))
    );

-- ----------------------------------------------------------------------------
-- SEC-007 — event creation must be a member and must escrow the pool.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_event(
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
    IF v_pool < 0 THEN
        RAISE EXCEPTION 'invalid_pool' USING ERRCODE = 'P0001';
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

REVOKE ALL ON FUNCTION public.create_event(
    text, text, public.event_type, text, uuid, text, numeric, numeric,
    timestamp with time zone, timestamp with time zone, public.join_mode,
    integer, integer, public.preshard_remainder_action, integer
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_event(
    text, text, public.event_type, text, uuid, text, numeric, numeric,
    timestamp with time zone, timestamp with time zone, public.join_mode,
    integer, integer, public.preshard_remainder_action, integer
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_event(
    text, text, public.event_type, text, uuid, text, numeric, numeric,
    timestamp with time zone, timestamp with time zone, public.join_mode,
    integer, integer, public.preshard_remainder_action, integer
) TO service_role;

REVOKE INSERT ON TABLE public.events FROM anon;
REVOKE INSERT ON TABLE public.events FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.event_hosts FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.event_hosts FROM authenticated;

CREATE OR REPLACE FUNCTION public.assert_safe_event_update()
RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    v_privileged boolean;
BEGIN
    SELECT rolbypassrls OR rolsuper INTO v_privileged
    FROM pg_catalog.pg_roles
    WHERE rolname = current_user;

    IF COALESCE(v_privileged, false) THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        NEW.created_by_user_id := auth.uid();
        NEW.preshards_pool := 0;
        NEW.preshards_cap_per_user := NULL;
        NEW.preshards_remainder_action := NULL;
        NEW.preshards_distributed := false;
        NEW.featured := false;
        NEW.featured_until := NULL;
        NEW.status := 'upcoming';
        RETURN NEW;
    END IF;

    IF NEW.preshards_pool <> OLD.preshards_pool
       OR NEW.preshards_cap_per_user IS DISTINCT FROM OLD.preshards_cap_per_user
       OR NEW.preshards_remainder_action IS DISTINCT FROM OLD.preshards_remainder_action
       OR NEW.preshards_distributed <> OLD.preshards_distributed
       OR NEW.featured <> OLD.featured
       OR NEW.featured_until IS DISTINCT FROM OLD.featured_until
       OR NEW.invite_token <> OLD.invite_token
       OR NEW.created_by_user_id <> OLD.created_by_user_id
       OR NEW.group_id IS DISTINCT FROM OLD.group_id THEN
        RAISE EXCEPTION 'events server-managed columns may only be changed by a privileged role'
            USING ERRCODE = 'P0001';
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NEW.status = 'cancelled'
           AND EXISTS (
                SELECT 1 FROM public.event_hosts
                WHERE event_id = OLD.id
                  AND user_id = auth.uid()
                  AND role = 'host'
           ) THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'events status may only be changed by a host cancel'
            USING ERRCODE = 'P0001';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.refund_event_pool_on_cancel()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_host RECORD;
BEGIN
    IF NEW.status = 'cancelled'
       AND OLD.status <> 'cancelled'
       AND NOT NEW.preshards_distributed THEN
        FOR v_host IN
            SELECT user_id, preshards_contributed
              FROM public.event_hosts
             WHERE event_id = NEW.id
               AND preshards_contributed > 0
        LOOP
            UPDATE public.users
               SET preshards = preshards + v_host.preshards_contributed
             WHERE id = v_host.user_id;
            INSERT INTO public.preshard_ledger (user_id, delta, reason, reference_id)
            VALUES (v_host.user_id, v_host.preshards_contributed, 'event_pool_returned', NEW.id);
        END LOOP;

        UPDATE public.events
           SET preshards_pool = 0,
               preshards_distributed = true
         WHERE id = NEW.id;
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.refund_event_pool_on_cancel() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refund_event_pool_on_cancel() TO service_role;

DROP TRIGGER IF EXISTS refund_event_pool_on_cancel_trigger ON public.events;
CREATE TRIGGER refund_event_pool_on_cancel_trigger
    AFTER UPDATE OF status ON public.events
    FOR EACH ROW
    WHEN (NEW.status = 'cancelled' AND OLD.status <> 'cancelled')
    EXECUTE FUNCTION public.refund_event_pool_on_cancel();

-- ----------------------------------------------------------------------------
-- SEC-010 — photo upload is for confirmed attendees/hosts on a live window.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS eph_insert_own ON public.event_photos;
CREATE POLICY eph_insert_own ON public.event_photos
    FOR INSERT WITH CHECK (
        uploaded_by_user_id = auth.uid()
        AND storage_path LIKE event_id::text || '/photos/%'
        AND EXISTS (
            SELECT 1 FROM public.events e
            WHERE e.id = event_photos.event_id
              AND e.status IN ('upcoming', 'live')
              AND (
                  EXISTS (
                      SELECT 1 FROM public.event_attendances a
                      WHERE a.event_id = e.id
                        AND a.user_id = auth.uid()
                  )
                  OR EXISTS (
                      SELECT 1 FROM public.event_hosts h
                      WHERE h.event_id = e.id
                        AND h.user_id = auth.uid()
                  )
              )
        )
    );

DROP POLICY IF EXISTS eph_delete_own_or_host ON public.event_photos;
CREATE POLICY eph_delete_own_or_host ON public.event_photos
    FOR DELETE USING (
        uploaded_by_user_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.event_hosts h
            WHERE h.event_id = event_photos.event_id
              AND h.user_id = auth.uid()
        )
    );
