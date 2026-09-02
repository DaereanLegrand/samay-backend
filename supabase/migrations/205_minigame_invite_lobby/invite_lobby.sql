-- Samay — 205_minigame_invite_lobby/invite_lobby.sql
-- Invite players into an ALREADY-CREATED minigame session (2026-09-01).
--
-- The 2026-09-01 product flow moves invites OUT of match creation: the host
-- creates the partida with ZERO invitees, lands in the lobby (the session
-- detail / 180_minigame_lobby), and invites players while waiting. That needs
-- a post-create invite seam — previously invites could only be attached at
-- create_minigame_session time.
--
-- invite_minigame_players(p_session_id uuid, p_invitees uuid[]) is the lobby
-- counterpart of create_minigame_session's p_invitees handling:
--
--   * CREATOR-ONLY (backend-enforced via participants[1], exactly like
--     start_minigame_match / remove_minigame_participant — the host invites,
--     participants wait).
--   * Mirrors the create-time per-invitee gates: live user (deleted_at IS
--     NULL), NOT blocked in either direction, friends-only privacy
--     (users.minigame_invite_friends_only requires an accepted friendship).
--   * IDEMPOTENT: self / already-participant / already-pending invitees are
--     skipped (the (session_id, invitee_id) UNIQUE in 140 keeps the table
--     clean); only genuinely NEW pending rows are inserted, so a repeated
--     tap from the lobby never creates duplicates.
--   * Re-checks the session's FROZEN player_limit (current participants +
--     already-pending invitees + new invitees <= the cap frozen at creation,
--     subscription-scaled in 140) — a late invite when the lobby is full is
--     rejected atomically, never trusted client-side.
--   * The existing notify_minigame_invite AFTER-INSERT trigger fires for each
--     new row, so the invitee's notification (direct + group payload with
--     wager/inviter, 200_minigame_invite_notice) works unchanged.
--
-- Posture mirrors the invite RPC family (140/201/202): SECURITY DEFINER,
-- SET search_path = '', typed jsonb statuses (I-57), PUBLIC EXECUTE revoked,
-- authenticated + service_role only. create_minigame_session keeps its
-- p_invitees parameter (backward compatible; premium-gated later).

-- ======================================================================
-- invite_minigame_players(uuid, uuid[])
-- ----------------------------------------------------------------------
-- Invites [p_invitees] into [p_session_id]. Returns jsonb:
--   ok / not_authenticated / session_not_found / session_not_active /
--   not_creator / invitee_not_allowed / invitee_friends_only /
--   too_many_invitees / player_limit_reached
-- `ok` carries "invited": the count of NEW pending invite rows inserted
-- (idempotent re-invites report 0).
-- ======================================================================
CREATE FUNCTION public.invite_minigame_players(p_session_id uuid, p_invitees uuid[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_current_user uuid;
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_player_limit integer;
    v_invitee uuid;
    v_invited integer := 0;
    v_clean_invitees uuid[] := '{}'::uuid[];
    v_pending uuid[];
BEGIN
    -- 1. Authentication gate.
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (serialize against finish / accept /
    --    concurrent lobby invites).
    SELECT group_id, status, participants, player_limit
        INTO v_group_id, v_status, v_participants, v_player_limit
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Lifecycle gate: invites only on ACTIVE sessions (a finished game
    --    can no longer be joined).
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 4. Creator-only gate (backend-enforced via participants[1] — the host
    --    invites, participants wait; mirror of start_minigame_match).
    IF array_length(v_participants, 1) IS NULL
       OR v_participants[1] <> v_current_user THEN
        RETURN jsonb_build_object('status', 'not_creator');
    END IF;

    -- 5. Invitee cleaning + per-invitee gates (mirror of the create-time
    --    block in 140/201/202): self skip, dedup, live user, blocked-either-
    --    direction, friends-only privacy. A violation rejects atomically.
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

    -- 5b. Idempotency: drop invitees who are already participants or already
    --     hold a pending invite (the UNIQUE (session_id, invitee_id) would
    --     also reject them — skipping is the friendly idempotent contract).
    v_pending := ARRAY(
        SELECT mi.invitee_id FROM public.minigame_invites mi
        WHERE mi.session_id = p_session_id AND mi.status = 'pending'::public.mini_game_invite_status
    );
    v_clean_invitees := ARRAY(
        SELECT t.v FROM unnest(v_clean_invitees) AS t(v)
        WHERE t.v <> ALL (v_participants)
          AND t.v <> ALL (v_pending)
    );

    -- 6. Player-cap gate: the frozen player_limit bounds the total roster
    --    (current participants + already-pending + the new invitees).
    IF (COALESCE(array_length(v_participants, 1), 0)
        + COALESCE(array_length(v_pending, 1), 0)
        + COALESCE(array_length(v_clean_invitees, 1), 0)) > v_player_limit THEN
        RETURN jsonb_build_object('status', 'player_limit_reached');
    END IF;

    -- 7. Invite rows (one pending row per NEW invitee; the notify trigger on
    --    minigame_invites dispatches the realtime notification unchanged).
    IF array_length(v_clean_invitees, 1) > 0 THEN
        FOREACH v_invitee IN ARRAY v_clean_invitees
        LOOP
            INSERT INTO public.minigame_invites (session_id, invitee_id, created_by)
            VALUES (p_session_id, v_invitee, v_current_user);
            v_invited := v_invited + 1;
        END LOOP;
    END IF;

    RETURN jsonb_build_object('status', 'ok', 'invited', v_invited);
END;
$$;

-- ======================================================================
-- ACLs — hardened posture (no PUBLIC; authenticated + service_role only).
-- ======================================================================
REVOKE ALL ON FUNCTION public.invite_minigame_players(p_session_id uuid, p_invitees uuid[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.invite_minigame_players(p_session_id uuid, p_invitees uuid[]) TO authenticated;
GRANT ALL ON FUNCTION public.invite_minigame_players(p_session_id uuid, p_invitees uuid[]) TO service_role;
