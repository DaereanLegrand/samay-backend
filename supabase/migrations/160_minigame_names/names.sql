-- Samay — 160_minigame_names/names.sql
-- Minigame partida names (2026-08-28 per-game page flow).
--
-- The per-game landing page lets a player NAME their partida when they hit
-- "Nueva partida" (or leave it blank and fall back to the auto "partida-XX"
-- display). Model:
--
--   * minigame_sessions.name — the optional user-supplied title (text,
--     NULLABLE). NULL or empty string = the client displays the computed
--     "partida-XX" (XX = the session's running number in its list), so the
--     auto-name stays computed client-side and never pollutes the DB.
--   * create_minigame_session gains p_name text (the previous 4-arg
--     overload is dropped; CREATE OR REPLACE cannot change the argument
--     list). p_name is optional and never validated server-side beyond
--     trimming — the client owns the copy; the server just stores it.

-- Name: minigame_sessions.name; Type: COLUMN; Schema: public
ALTER TABLE public.minigame_sessions
    ADD COLUMN name text;

-- ======================================================================
-- create_minigame_session(uuid, text, integer, uuid[], text)
-- The 4-arg overload (uuid, text, integer, uuid[]) is dropped so the
-- argument list can gain p_name. Behavior is byte-identical to 140's 4-arg
-- version plus the optional partida name stored on the session row.
-- ======================================================================
DROP FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[]);

CREATE FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[] DEFAULT '{}'::uuid[], p_name text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_session_id uuid;
    v_game_type public.mini_game_type;
    v_current_user uuid;
    v_invitee uuid;
    v_clean_invitees uuid[] := '{}'::uuid[];
    v_tier public.subscription_tier;
    v_player_limit integer;
    v_name text;
BEGIN
    -- 1. Authentication gate.
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 1b. Player cap frozen at creation (direct-minigames 2026-08-27):
    --     the CREATOR's subscription tier selects the app_config cap
    --     (minigame.{free,pro,vip}_max_players, defaults 8/32/100). Stored
    --     on the session so joins/accepts never re-read a downgraded tier.
    SELECT subscription_tier INTO v_tier
    FROM public.users WHERE id = v_current_user;
    v_player_limit := COALESCE((
        SELECT value::integer FROM public.app_config
        WHERE key = CASE v_tier
            WHEN 'vip'::public.subscription_tier THEN 'minigame.vip_max_players'
            WHEN 'pro'::public.subscription_tier THEN 'minigame.pro_max_players'
            ELSE 'minigame.free_max_players'
        END
    ), 8);

    -- 2. Group-membership gate (direct-minigames 2026-08-27): a NULL
    --    p_group_id = DIRECT session and needs no group; a non-null group
    --    still requires active membership (is_group_member helper).
    IF p_group_id IS NOT NULL AND NOT public.is_group_member(p_group_id) THEN
        RETURN jsonb_build_object('status', 'not_member');
    END IF;

    -- 3. Wager validation (GWAG: integer shards >= 0; 0 = no wager).
    IF p_wager < 0 THEN
        RETURN jsonb_build_object('status', 'invalid_wager');
    END IF;

    -- 4. Game-type validation against the mini_game_type enum.
    BEGIN
        v_game_type := p_game_type::public.mini_game_type;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('status', 'invalid_game_type');
    END;

    -- 5. Invitee cleaning + per-invitee gates (blocked / deleted /
    --    friends-only privacy) — a single violation rejects atomically.
    IF p_invitees IS NOT NULL AND array_length(p_invitees, 1) > 0 THEN
        FOR v_invitee IN
            SELECT DISTINCT unnest(p_invitees)
        LOOP
            IF v_invitee = v_current_user THEN
                CONTINUE; -- never invite yourself
            END IF;
            IF array_length(v_clean_invitees, 1) >= 20 THEN
                RETURN jsonb_build_object('status', 'too_many_invitees');
            END IF;

            -- Blocked (either direction) or deleted invitees are rejected.
            IF NOT EXISTS (
                SELECT 1 FROM public.users
                WHERE id = v_invitee AND deleted_at IS NULL
            ) THEN
                RETURN jsonb_build_object('status', 'invitee_not_allowed');
            END IF;
            IF EXISTS (
                SELECT 1 FROM public.friendships
                WHERE status = 'blocked'::public.friendship_status
                  AND ((requester_id = v_current_user AND addressee_id = v_invitee)
                    OR (requester_id = v_invitee AND addressee_id = v_current_user))
            ) THEN
                RETURN jsonb_build_object('status', 'invitee_not_allowed');
            END IF;

            -- Friends-only privacy: the invitee opted to be invitable only
            -- by accepted friends.
            IF EXISTS (
                SELECT 1 FROM public.users
                WHERE id = v_invitee AND minigame_invite_friends_only = true
            ) AND NOT EXISTS (
                SELECT 1 FROM public.friendships
                WHERE status = 'accepted'::public.friendship_status
                  AND ((requester_id = v_current_user AND addressee_id = v_invitee)
                    OR (requester_id = v_invitee AND addressee_id = v_current_user))
            ) THEN
                RETURN jsonb_build_object('status', 'invitee_friends_only');
            END IF;

            v_clean_invitees := v_clean_invitees || v_invitee;
        END LOOP;
    END IF;

    -- 6. Player-cap gate (direct-minigames 2026-08-27): the creator counts
    --    as one participant (they are always participant[0]); the frozen
    --    player_limit bounds the total roster (free 8, scaled by the
    --    creator's tier). Typed rejection — the whole create stays atomic.
    IF (1 + COALESCE(array_length(v_clean_invitees, 1), 0)) > v_player_limit THEN
        RETURN jsonb_build_object('status', 'player_limit_reached');
    END IF;

    -- 6b. Partida name (160_minigame_names): trimmed copy; NULL/blank =
    --     client-side auto "partida-XX" display.
    v_name := NULLIF(btrim(p_name), '');

    -- 7. Wager escrow (unchanged from the baseline 3-arg contract).
    IF p_wager > 0 THEN
        UPDATE public.users
        SET personal_shards = personal_shards - p_wager
        WHERE id = v_current_user AND personal_shards >= p_wager;

        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'insufficient_shards');
        END IF;
    END IF;

    -- 8. Session insert (the initiator is the first participant; the
    --    frozen player_limit and the optional partida name ride the row).
    INSERT INTO public.minigame_sessions
        (group_id, game_type, status, shard_wager, player_limit, participants, name)
    VALUES
        (p_group_id, v_game_type, 'active', p_wager, v_player_limit,
         ARRAY[v_current_user], v_name)
    RETURNING id INTO v_session_id;

    -- 9. Ledger entry with the session reference (escrow verifiability).
    IF p_wager > 0 THEN
        INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
        VALUES (v_current_user, -p_wager, 'minigame_wager', v_session_id);
    END IF;

    -- 10. Invite rows (one pending row per invitee; the notify trigger on
    --    minigame_invites dispatches the realtime notification).
    IF array_length(v_clean_invitees, 1) > 0 THEN
        FOREACH v_invitee IN ARRAY v_clean_invitees
        LOOP
            INSERT INTO public.minigame_invites (session_id, invitee_id, created_by)
            VALUES (v_session_id, v_invitee, v_current_user);
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'status', 'created',
        'sessionId', v_session_id,
        'invited', COALESCE(array_length(v_clean_invitees, 1), 0)
    );
END;
$$;

-- ======================================================================
-- ACL — mirror 140_minigame_invites (PUBLIC revoked, authenticated +
-- service_role EXECUTE).
-- ======================================================================
REVOKE ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text) TO authenticated;
GRANT ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text) TO service_role;
