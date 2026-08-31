-- Samay — 203_minigame_host_start/start.sql
-- Host-device-confirmed match start (2026-08-31).
--
-- The countdown is HOST-DEVICE based (see 190 header). The host's device
-- runs its own 5s countdown from its internal clock after tapping Start
-- (the server's init_minigame_game_state seeded phase='countdown' — the
-- "start countdown" signal). When the host's countdown reaches 0 WITHOUT a
-- cancel, the host's app calls this RPC:
--
--   * start_minigame_match(p_session_id) — SECURITY DEFINER, CREATOR-ONLY
--     (participants[0], backend-enforced). Flips state.phase 'countdown' →
--     'playing'. The minigame_game_state_touch trigger bumps updated_at, so
--     the UPDATE streams over the existing minigame_game_state realtime
--     channel = the authoritative "match is starting" broadcast. Every
--     participant's client navigates to the play screen together.
--
-- There is NO server timer, NO cron, NO countdown_ends_at deadline — the
-- server never counts down. The only server-side transitions out of
-- 'countdown' are this RPC (host confirm → playing) and
-- cancel_minigame_start (host cancel → setup skeleton).
--
-- Posture mirrors 190/140/150/180: FORCE RLS, mutations through SECURITY
-- DEFINER RPCs only, PUBLIC EXECUTE revoked, authenticated + service_role.

-- ======================================================================
-- start_minigame_match(uuid)
-- The host's device confirms the countdown finished without a cancel: flips
-- the game-state phase countdown → playing. Creator-only, backend-enforced
-- (participants[0]). Typed statuses mirror the play-engine RPC family.
-- ======================================================================
CREATE FUNCTION public.start_minigame_match(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (serialize start vs cancel/finish).
    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate (participant / invitee / group member).
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

    -- 3b. Creator-only Start gate (backend-enforced).
    IF array_length(v_participants, 1) IS NULL
       OR v_participants[1] <> auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_creator');
    END IF;

    -- 4. Lifecycle gate: only active sessions start.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. Only a countdown can be confirmed — an already-playing or absent
    --    state is a typed rejection (idempotent for an already-playing row).
    IF NOT EXISTS (
        SELECT 1 FROM public.minigame_game_state m
        WHERE m.session_id = p_session_id
          AND m.state ->> 'phase' = 'countdown'
    ) THEN
        -- Already playing is fine (re-tap / re-entrant host confirm).
        SELECT to_jsonb(m) INTO v_row
        FROM public.minigame_game_state m
        WHERE m.session_id = p_session_id
          AND m.state ->> 'phase' = 'playing';
        IF v_row IS NOT NULL THEN
            RETURN jsonb_build_object('status', 'started', 'state', v_row);
        END IF;
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    -- 6. Flip countdown → playing. The touch trigger streams it via realtime.
    UPDATE public.minigame_game_state
    SET state = state || jsonb_build_object('phase', 'playing')
    WHERE session_id = p_session_id;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'started', 'state', v_row);
END;
$$;

-- ======================================================================
-- ACLs — hardened posture (no PUBLIC; authenticated + service_role only).
-- ======================================================================
REVOKE ALL ON FUNCTION public.start_minigame_match(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.start_minigame_match(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.start_minigame_match(p_session_id uuid) TO service_role;
