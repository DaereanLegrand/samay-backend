-- ======================================================================
-- Drunk bottle minigame (209_minigame_drunk_bottle).
--
-- Minimal spin/stop sync for `drunk_bottle` sessions: any participant may
-- spin or stop the bottle (host-only gating is a follow-up), the result
-- (spinning flag + selected participant) rides the existing
-- `minigame_game_state.state` jsonb and streams to the whole lobby over the
-- already-wired realtime channel (same transport `set_minigame_ready` uses)
-- — no new table, no new subscription.
-- ======================================================================

CREATE FUNCTION public.set_drunk_bottle_spin(
    p_session_id uuid,
    p_spinning boolean,
    p_selected_id uuid DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_game_type public.mini_game_type;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (mirrors set_minigame_ready).
    SELECT group_id, status, participants, game_type
        INTO v_group_id, v_status, v_participants, v_game_type
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    IF v_game_type <> 'drunk_bottle' THEN
        RETURN jsonb_build_object('status', 'wrong_game_type');
    END IF;

    -- 3. Access gate: any current participant (no group-play path yet for
    --    this game — direct partidas only).
    IF NOT (v_group_id IS NULL AND auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    IF p_selected_id IS NOT NULL AND NOT (p_selected_id = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'invalid_selection');
    END IF;

    -- 4. Upsert the spin state. bottle_seq is a monotonic per-write counter
    --    (mirrors reactions_seq) so a client can tell "new spin" from a
    --    same-value re-delivery.
    INSERT INTO public.minigame_game_state (session_id, game_type, state, ready)
    SELECT p_session_id,
           s.game_type,
           jsonb_build_object(
               'phase', 'playing',
               'bottle_spinning', p_spinning,
               'bottle_selected_id', to_jsonb(p_selected_id),
               'bottle_seq', 1
           ),
           '{}'::jsonb
      FROM public.minigame_sessions AS s
     WHERE s.id = p_session_id
    ON CONFLICT (session_id) DO UPDATE
        SET state = minigame_game_state.state
                     || jsonb_build_object(
                         'phase', 'playing',
                         'bottle_spinning', p_spinning,
                         'bottle_selected_id', to_jsonb(p_selected_id),
                         'bottle_seq',
                         COALESCE((minigame_game_state.state->>'bottle_seq')::int, 0) + 1
                     ),
            updated_at = now();

    RETURN jsonb_build_object('status', 'ok');
END;
$$;

REVOKE ALL ON FUNCTION public.set_drunk_bottle_spin(uuid, boolean, uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_drunk_bottle_spin(uuid, boolean, uuid) TO authenticated;
GRANT ALL ON FUNCTION public.set_drunk_bottle_spin(uuid, boolean, uuid) TO service_role;
