-- Samay — 191_minigame_game_state_at_creation/game_state_at_creation.sql
-- The minigame_game_state row exists FROM SESSION CREATION (2026-08-30).
--
-- Rationale: set_minigame_ready was INSERT ... ON CONFLICT — the FIRST ready
-- toggle on a fresh session had no game-state row yet, so it INSERTed one,
-- and the realtime subscription is `PostgresChangeEvent.update`-only: an
-- INSERT is never delivered, so the first ready toggle was invisible to the
-- rest of the lobby until a second toggle (an UPDATE) arrived.
--
-- Fix (KISS, matches the existing realtime convention): create the row
-- atomically in create_minigame_session so every ready toggle is an UPDATE
-- from the very first one — the update-only subscription streams them all.
-- set_minigame_ready becomes a plain UPDATE (no ON CONFLICT). init keeps its
-- ON CONFLICT (the row now pre-exists → UPDATE path, clearing ready + seeding
-- the countdown skeleton), still correct for pre-191 rows.

-- ======================================================================
-- create_minigame_session(uuid, text, integer, uuid[], text) — CREATE
-- OR REPLACE (same 5-arg signature). Adds step 9b: after the session insert,
-- seed the game-state row ({state:{}, ready:{}}) in the SAME transaction, so
-- the lobby's realtime ready stream works from the first toggle.
-- ======================================================================
CREATE OR REPLACE FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[] DEFAULT '{}'::uuid[], p_name text DEFAULT NULL) RETURNS jsonb
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
    v_auto_name text;
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
    --     the auto "partida-XX" display.
    v_name := NULLIF(btrim(p_name), '');

    -- 6c. Auto partida name (170_minigame_invite_badges): the server-computed
    --     running number per game_type among ACTIVE sessions. Canonical for
    --     creator AND invitee (resolvable from the row in isolation), so the
    --     invitee sees "partida-1" matching what the creator's list shows.
    v_auto_name := 'partida-' || (
        SELECT count(*) + 1
        FROM public.minigame_sessions
        WHERE game_type = v_game_type AND status = 'active'
    );

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
    --    frozen player_limit, the optional partida name and the canonical
    --    auto_name ride the row).
    INSERT INTO public.minigame_sessions
        (group_id, game_type, status, shard_wager, player_limit, participants, name, auto_name)
    VALUES
        (p_group_id, v_game_type, 'active', p_wager, v_player_limit,
         ARRAY[v_current_user], v_name, v_auto_name)
    RETURNING id INTO v_session_id;

    -- 9. Ledger entry with the session reference (escrow verifiability).
    IF p_wager > 0 THEN
        INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
        VALUES (v_current_user, -p_wager, 'minigame_wager', v_session_id);
    END IF;

    -- 9b. Seed the game-state row in the same transaction (191): an empty
    --     lobby skeleton ({state:{}, ready:{}}). The row existing from
    --     creation makes every set_minigame_ready an UPDATE, so the first
    --     ready toggle streams through the update-only realtime subscription.
    INSERT INTO public.minigame_game_state (session_id, game_type, state, ready)
    VALUES (v_session_id, v_game_type, '{}'::jsonb, '{}'::jsonb);

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
-- set_minigame_ready(uuid, boolean) — CREATE OR REPLACE (same signature).
-- The row now always exists (seeded at creation, 191): a plain UPDATE
-- writes the caller's ready flag. Every ready toggle is an UPDATE → streamed
-- live by the update-only minigame_game_state realtime subscription. The
-- COALESCE keeps pre-191 rows (NULL ready map) working.
-- ======================================================================
CREATE OR REPLACE FUNCTION public.set_minigame_ready(p_session_id uuid, p_ready boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (serialize against finish/remove/init).
    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate (participant / invitee / group member — mirrors the
    --    play-engine RPCs).
    IF NOT (
            (v_group_id IS NULL AND auth.uid() = ANY (v_participants))
         OR EXISTS (
                SELECT 1 FROM public.minigame_invites mi
                WHERE mi.session_id = p_session_id AND mi.invitee_id = auth.uid()
            )
         OR EXISTS (
                SELECT 1 FROM public.group_members gm
                WHERE gm.group_id = v_group_id AND gm.user_id = auth.uid()
            )
        ) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle gate: ready toggles only while the session is active.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. Plain UPDATE (the row is seeded at creation, 191): upsert the
    --    caller's ready flag into the ready map. The whole lobby sees the
    --    toggle through the game-state realtime subscription.
    UPDATE public.minigame_game_state
    SET ready = COALESCE(ready, '{}'::jsonb) || jsonb_build_object(auth.uid()::text, p_ready)
    WHERE session_id = p_session_id;

    RETURN jsonb_build_object('status', 'ready');
END;
$$;
