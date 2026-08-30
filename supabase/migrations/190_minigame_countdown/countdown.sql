-- Samay — 190_minigame_countdown/countdown.sql
-- Pre-play countdown + server-authoritative "next turn" (2026-08-30).
--
-- The partida lobby now waits a fixed 5s countdown after the host taps Start
-- before the play screen opens for EVERY participant. The DB row is the
-- single source of truth — there is no wall-clock agreement to coordinate:
--
--   * init_minigame_game_state (CREATE OR REPLACE) seeds phase='countdown'
--     with countdown_ends_at = now() + 5s. That IS the server's
--     "start countdown" signal — every lobby sees it stream in on the
--     existing minigame_game_state realtime channel and renders the overlay.
--   * get_minigame_game_state (CREATE OR REPLACE) performs a LAZY flip: on
--     read, if phase='countdown' and countdown_ends_at <= now(), it UPDATEs
--     phase='playing' and returns the advanced row. The UPDATE streams back
--     over the same channel = the server's "countdown ended" signal, so every
--     client navigates to the play screen together. Crash-safe and fully
--     synchronous — no cron, no background workers; a crashed mid-countdown
--     state self-heals on the next read.
--   * cancel_minigame_start(uuid) — NEW SECURITY DEFINER RPC, CREATOR-ONLY
--     (participants[0], backend-enforced): resets the game-state row back to a
--     setup skeleton so every participant stays on the match (lobby) screen.
--     The ready map is preserved (host cancels, everyone keeps their ready).
--   * advance_minigame_turn (CREATE OR REPLACE) now rejects a mid-countdown
--     turn with the typed 'countdown_pending' status and re-draws a fresh
--     server-random next_subject_id on every advance (the "who's next"
--     indicator, authoritative like the current subject).
--
-- Posture mirrors 100/140/150/180: FORCE RLS, mutations through SECURITY
-- DEFINER RPCs only, PUBLIC EXECUTE revoked, authenticated + service_role.

-- ======================================================================
-- init_minigame_game_state(uuid) — CREATE OR REPLACE (same signature).
-- The lobby -> countdown -> playing transition. Seeds the random first
-- subject AND the server-authoritative next_subject_id, plus the countdown
-- deadline. Creator-only (participants[0]) enforced server-side; idempotent
-- for an already-in-progress row (countdown OR playing). Ready map clears.
-- ======================================================================
CREATE OR REPLACE FUNCTION public.init_minigame_game_state(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_count integer;
    v_game_type public.mini_game_type;
    v_random_index integer;
    v_next_index integer;
    v_state jsonb;
    v_row jsonb;
    v_existing jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (serialize init vs finish/join).
    SELECT group_id, status, participants, game_type
        INTO v_group_id, v_status, v_participants, v_game_type
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate (participant / invitee / group member) FIRST — a
    --    bystander gets not_allowed (unchanged 150 contract).
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

    -- 3b. Creator-only Start gate (backend-enforced, never a UI rule).
    IF array_length(v_participants, 1) IS NULL
       OR v_participants[1] <> auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_creator');
    END IF;

    -- 4. Lifecycle gate: only active sessions start a play engine.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. Idempotency: an existing row in countdown OR playing is a no-op
    --    (countdown is as started as playing — re-tapping Start must not
    --    restart the timer).
    SELECT to_jsonb(m) INTO v_existing
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_existing IS NOT NULL
       AND v_existing -> 'state' ->> 'phase' IN ('countdown', 'playing') THEN
        RETURN jsonb_build_object('status', 'already_started', 'state', v_existing);
    END IF;

    -- 6. Random first subject + random NEXT subject (server-random — players
    --    never self-select; the next index is distinct from the first when
    --    there is more than one participant, so the "who's next" indicator
    --    never names the current player).
    v_count := COALESCE(array_length(v_participants, 1), 0);
    IF v_count = 0 THEN
        RETURN jsonb_build_object('status', 'no_participants');
    END IF;
    v_random_index := 1 + floor(random() * v_count)::integer;
    IF v_count = 1 THEN
        v_next_index := v_random_index;
    ELSE
        v_next_index := 1 + floor(random() * (v_count - 1))::integer;
        IF v_next_index >= v_random_index THEN
            v_next_index := v_next_index + 1;
        END IF;
    END IF;

    v_state := jsonb_build_object(
        'judge_index', 0,
        'round', 0,
        'phase', 'countdown',
        -- The deadline as a native timestamptz: jsonb serializes it as ISO
        -- 8601 with the session timezone offset, which both Postgres
        -- (::timestamptz) and Dart (DateTime.tryParse) round-trip exactly.
        'countdown_ends_at', now() + interval '5 seconds',
        'subject_id', v_participants[v_random_index],
        'next_subject_id', v_participants[v_next_index],
        'prompt_type', NULL,
        'prompt', NULL
    );

    -- 7. Upsert the row: a fresh session INSERTs; a lobby-seeded row (from
    --    set_minigame_ready) UPDATEs with the seeded skeleton + cleared ready
    --    map. game_type denormalized from the session.
    INSERT INTO public.minigame_game_state (session_id, game_type, state, ready)
    VALUES (p_session_id, v_game_type, v_state, '{}'::jsonb)
    ON CONFLICT (session_id) DO UPDATE
        SET state = v_state,
            game_type = v_game_type,
            ready = '{}'::jsonb;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'started', 'state', v_row);
END;
$$;

-- ======================================================================
-- get_minigame_game_state(uuid) — CREATE OR REPLACE (same signature).
-- The lazy countdown flip: when the caller reads a row whose countdown
-- deadline has passed, the server advances it to playing BEFORE returning.
-- The UPDATE streams through the minigame_game_state realtime publication,
-- so the flip is the authoritative "go to the play screen" broadcast.
-- ======================================================================
CREATE OR REPLACE FUNCTION public.get_minigame_game_state(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_participants uuid[];
    v_row jsonb;
    v_phase text;
    v_deadline text;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup (no lock — read-only).
    SELECT group_id, participants
        INTO v_group_id, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id;
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

    -- 4. Lazy countdown flip (synchronous, no background worker): if the row
    --    is still in countdown and the deadline has passed, advance it. The
    --    UPDATE touches updated_at via the touch trigger, so the realtime
    --    channel streams the playing state to every participant.
    SELECT m.state ->> 'phase', m.state ->> 'countdown_ends_at'
        INTO v_phase, v_deadline
        FROM public.minigame_game_state m
        WHERE m.session_id = p_session_id;

    IF v_phase = 'countdown' AND v_deadline IS NOT NULL
       AND (v_deadline)::timestamptz <= now() THEN
        UPDATE public.minigame_game_state
        SET state = state
                    - 'countdown_ends_at'
                    || jsonb_build_object('phase', 'playing')
        WHERE session_id = p_session_id;
    END IF;

    -- 5. Read the (possibly advanced) state row.
    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_row IS NULL THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    RETURN jsonb_build_object('status', 'ok', 'state', v_row);
END;
$$;

-- ======================================================================
-- cancel_minigame_start(uuid)
-- The host's Cancel button (190 countdown). Creator-only, backend-enforced
-- (participants[0]). Resets the row back to a setup skeleton so EVERY
-- participant stays on the match screen; the ready map is preserved. Typed
-- statuses mirror the play-engine RPC family.
-- ======================================================================
CREATE FUNCTION public.cancel_minigame_start(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_game_type public.mini_game_type;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (serialize cancel vs init/finish).
    SELECT group_id, status, participants, game_type
        INTO v_group_id, v_status, v_participants, v_game_type
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

    -- 3b. Creator-only Cancel gate (backend-enforced).
    IF array_length(v_participants, 1) IS NULL
       OR v_participants[1] <> auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_creator');
    END IF;

    -- 4. Lifecycle gate: only active sessions can be cancelled.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. Only a countdown can be cancelled — an already-playing or absent
    --    state is a typed rejection (the play screen is not a cancel target).
    IF NOT EXISTS (
        SELECT 1 FROM public.minigame_game_state m
        WHERE m.session_id = p_session_id
          AND m.state ->> 'phase' = 'countdown'
    ) THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    -- 6. Reset to a setup skeleton (empty state — the lobby treats it as
    --    not-started). The ready map is preserved; game_type stays.
    UPDATE public.minigame_game_state
    SET state = '{}'::jsonb
    WHERE session_id = p_session_id;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'cancelled', 'state', v_row);
END;
$$;

-- ======================================================================
-- advance_minigame_turn(uuid, jsonb) — CREATE OR REPLACE (same signature).
-- Two 190 additions: a mid-countdown advance is rejected with
-- 'countdown_pending' (the turn cannot close before the game truly starts),
-- and every advance re-draws a fresh server-random next_subject_id so the
-- "who's next" indicator is authoritative on every client.
-- ======================================================================
CREATE OR REPLACE FUNCTION public.advance_minigame_turn(p_session_id uuid, p_round jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_state jsonb;
    v_phase text;
    v_judge_index integer;
    v_round integer;
    v_player_count integer;
    v_next_judge integer;
    v_random_index integer;
    v_next_index integer;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (serialize concurrent turn advances).
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

    -- 4. Lifecycle gate.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. Load the game-state row (must be initialized).
    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_state IS NULL THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    -- 5b. 190: the turn cannot advance while the start countdown is pending.
    v_phase := v_state ->> 'phase';
    IF v_phase = 'countdown' THEN
        RETURN jsonb_build_object('status', 'countdown_pending');
    END IF;

    -- 6. Round-robin judge rotation (generic across all 5 games).
    v_player_count := COALESCE(array_length(v_participants, 1), 0);
    IF v_player_count = 0 THEN
        RETURN jsonb_build_object('status', 'no_participants');
    END IF;
    v_judge_index := COALESCE((v_state ->> 'judge_index')::integer, 0);
    v_next_judge := (v_judge_index + 1) % v_player_count;
    v_round := COALESCE((v_state ->> 'round')::integer, 0);

    -- 7. Random next subject + random FOLLOWING subject (server-random —
    --    players never self-select; distinct from the next when possible).
    v_random_index := 1 + floor(random() * v_player_count)::integer;
    IF v_player_count = 1 THEN
        v_next_index := v_random_index;
    ELSE
        v_next_index := 1 + floor(random() * (v_player_count - 1))::integer;
        IF v_next_index >= v_random_index THEN
            v_next_index := v_next_index + 1;
        END IF;
    END IF;

    -- 8. Append the completed round + rotate the skeleton; clear the prompt
    --    fields and persist the fresh next_subject_id for the following turn.
    UPDATE public.minigame_game_state
    SET rounds = rounds || ARRAY[p_round],
        state = v_state
                - 'subject_id' - 'next_subject_id' - 'prompt_type' - 'prompt'
                || jsonb_build_object(
                       'judge_index', v_next_judge,
                       'round', v_round + 1,
                       'phase', 'playing',
                       'subject_id', v_participants[v_random_index],
                       'next_subject_id', v_participants[v_next_index]
                   )
    WHERE session_id = p_session_id;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'advanced', 'state', v_row);
END;
$$;

-- ======================================================================
-- ACLs — hardened posture (no PUBLIC; authenticated + service_role only,
-- mirror of 140/150/180).
-- ======================================================================
REVOKE ALL ON FUNCTION public.cancel_minigame_start(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cancel_minigame_start(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.cancel_minigame_start(p_session_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.init_minigame_game_state(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.init_minigame_game_state(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.init_minigame_game_state(p_session_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.get_minigame_game_state(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_minigame_game_state(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_minigame_game_state(p_session_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.advance_minigame_turn(p_session_id uuid, p_round jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.advance_minigame_turn(p_session_id uuid, p_round jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.advance_minigame_turn(p_session_id uuid, p_round jsonb) TO service_role;
