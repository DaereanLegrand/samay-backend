-- Samay — 206_minigame_key_request/key_request.sql
-- Minigame round-key REQUEST ring (2026-09-03) — server-blind re-key heal.
--
-- Problem: a participant whose device-local E2EE state was WIPED (app
-- reinstall / data clear / account switch) regenerates a fresh identity and
-- republishes it. The host's per-round key bundles (`minigame_e2ee_bundles`)
-- are pairwise-wrapped to the OLD identity, so `ensureRoundKey` self-heal can
-- never decrypt them — the `recipient identity does not match` DROP in the
-- logs. Because the device is ALREADY a participant, the accept-time /
-- roster-change distribution never re-fires, so the current round's answer
-- silently fails to decrypt on that device (the "waiting X/Y reactions…" only
-- bug) while every intact participant reads it fine.
--
-- Design (Signal-faithful + any-participant serve, server COMPLETELY blind):
--   * The server NEVER sees a round key. It only brokers a REQUEST MARKER.
--   * A participant who lost a round key appends itself to
--     `state.key_requests` (jsonb uuid[] INSIDE the game-state payload — rides
--     the existing `minigame_game_state` realtime channel, no new column).
--   * ANY other participant who holds the key history (not just the host)
--     observes the marker, re-wraps `K_0..K_<latest>` to the requester's
--     CURRENT identity via the existing pairwise `minigame_e2ee_bundles`
--     delivery seam (fresh X3DH init), then removes the requester from the
--     marker. The requester's `ensureRoundKey` / poll picks the new bundle up.
--   * The marker PERSISTS until a holder actually serves it (never cleared on
--     advance) — a requester who stayed unserved through round 0 still needs
--     `K_0` in round 1, and additive history delivery covers it.
--
-- This closes the deferred limitation in
-- `2026-09-01_round-key-mint-race.md` ("a member offline at Empezar who
-- returns while STILL in round 0 has no re-delivery trigger") for the
-- reinstall case, WITHOUT relaxing server blindness, WITHOUT a KDF dependency,
-- and WITHOUT the host as a single point of failure.
--
-- Posture mirrors 202/203/204/205: FORCE RLS, mutations through SECURITY
-- DEFINER RPCs only, PUBLIC EXECUTE revoked, authenticated + service_role.

-- ======================================================================
-- request_minigame_round_keys(uuid) — the requester self-flags.
-- A CURRENT participant who cannot decrypt the current round appends itself
-- to `state.key_requests` (dedup). No key material crosses this RPC.
-- ======================================================================
CREATE FUNCTION public.request_minigame_round_keys(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_status public.mini_game_status;
    v_participants uuid[];
    v_state jsonb;
    v_requests jsonb;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (serialize against advance/serve).
    SELECT status, participants INTO v_status, v_participants
    FROM public.minigame_sessions
    WHERE id = p_session_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Participant-only on the WRITE path (security hardening 2026-08-31:
    --    invitees / group members render the lobby but never request keys).
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle gate — key requests are for a live, playing game.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. The game-state row must exist (the play engine is running).
    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_state IS NULL THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    -- 6. Append the caller to the request marker (dedup). uuid[] rides the
    --    payload as jsonb strings; containment keeps it idempotent.
    v_requests := COALESCE(v_state -> 'key_requests', '[]'::jsonb);
    IF NOT v_requests @> jsonb_build_array(auth.uid()) THEN
        v_requests := v_requests || jsonb_build_array(auth.uid());
    END IF;

    UPDATE public.minigame_game_state
    SET state = jsonb_set(state, '{key_requests}', v_requests, true)
    WHERE session_id = p_session_id;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'requested', 'state', v_row);
END;
$$;

-- ======================================================================
-- resolve_minigame_key_request(uuid, uuid) — a HOLDER clears a served peer.
-- After a holder successfully re-wraps its key history to [p_requester]
-- (via the bundle seam), it removes [p_requester] from the marker so the
-- ring stops re-serving. Gates: the caller is a participant, the requester
-- is a DIFFERENT participant, and the caller never self-clears (a requester
-- cannot erase its own flag, which would defeat the heal).
-- ======================================================================
CREATE FUNCTION public.resolve_minigame_key_request(p_session_id uuid, p_requester uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_status public.mini_game_status;
    v_participants uuid[];
    v_state jsonb;
    v_requests jsonb;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock.
    SELECT status, participants INTO v_status, v_participants
    FROM public.minigame_sessions
    WHERE id = p_session_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Participant-only + never self-clear + requester is a participant.
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;
    IF auth.uid() = p_requester THEN
        RETURN jsonb_build_object('status', 'self_resolve');
    END IF;
    IF NOT (p_requester = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle gate.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. Drop the requester from the marker (idempotent — an absent requester
    --    still resolves).
    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    v_requests := COALESCE(v_state -> 'key_requests', '[]'::jsonb);
    v_requests := (
        SELECT COALESCE(jsonb_agg(elem) FILTER (WHERE elem <> to_jsonb(p_requester)), '[]'::jsonb)
        FROM jsonb_array_elements(v_requests) AS t(elem)
    );

    UPDATE public.minigame_game_state
    SET state = jsonb_set(state, '{key_requests}', v_requests, true)
    WHERE session_id = p_session_id;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'resolved', 'state', v_row);
END;
$$;

-- ======================================================================
-- ACLs — hardened posture (no PUBLIC; authenticated + service_role only).
-- ======================================================================
REVOKE ALL ON FUNCTION public.request_minigame_round_keys(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.request_minigame_round_keys(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.request_minigame_round_keys(p_session_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.resolve_minigame_key_request(p_session_id uuid, p_requester uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resolve_minigame_key_request(p_session_id uuid, p_requester uuid) TO authenticated;
GRANT ALL ON FUNCTION public.resolve_minigame_key_request(p_session_id uuid, p_requester uuid) TO service_role;
