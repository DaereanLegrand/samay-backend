-- ============================================================================
-- 300_slim/04_leave_session.sql — a player leaves the lobby
--
-- Slim-prod has no wager to refund when a player walks away, so leaving is a
-- pure roster operation:
--   * auth gate, row lock (FOR UPDATE) so a concurrent join/remove cannot
--     lose an update;
--   * not a participant  -> 'not_participant'
--   * not an active match -> 'session_not_active'
--   * creator AND the only participant -> 'last_participant' (a session must
--     always keep its host; the client finishes/abandons instead);
--   * otherwise drop the caller from participants[]. HOST AUTHORITY
--     TRANSFER: participants[1] is the host, so when the creator (index 1)
--     leaves, the next remaining participant naturally becomes participants[1]
--     and inherits creator-only actions (start / remove).
--   * the caller's minigame_invites row, minigame_aliases row and ready flag
--     are removed in the same transaction.
--
-- Rollback: forward-fix only.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.leave_minigame_session(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_new_participants uuid[];
    v_has_ready boolean;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 1. Session lookup + row lock.
    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 2. Standing: only a current participant may leave.
    IF NOT (v_uid = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_participant');
    END IF;

    -- 3. Lifecycle: roster edits only on an active match.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 4. The host can never leave an otherwise-empty session.
    IF v_participants[1] = v_uid
       AND COALESCE(array_length(v_participants, 1), 0) <= 1 THEN
        RETURN jsonb_build_object('status', 'last_participant');
    END IF;

    -- 5. Remove the caller. Host authority transfers implicitly: whatever
    --    remains keeps its relative order, so the next participant becomes
    --    participants[1].
    SELECT array_agg(p ORDER BY ord) INTO v_new_participants
      FROM unnest(v_participants) WITH ORDINALITY AS t(p, ord)
     WHERE p <> v_uid;
    IF v_new_participants IS NULL THEN
        v_new_participants := ARRAY[]::uuid[];
    END IF;

    UPDATE public.minigame_sessions
    SET participants = v_new_participants
    WHERE id = p_session_id;

    -- 6. Close the invite row (pending OR accepted).
    DELETE FROM public.minigame_invites
    WHERE session_id = p_session_id AND invitee_id = v_uid;

    -- 7. Drop the anonymous-mode alias.
    DELETE FROM public.minigame_aliases
    WHERE session_id = p_session_id AND participant_id = v_uid;

    -- 8. Clear the ready flag when the game-state row exists and carries one
    --    (minigame_game_state.ready is optional in older seeds).
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'minigame_game_state'
          AND column_name = 'ready'
    ) INTO v_has_ready;

    IF v_has_ready THEN
        UPDATE public.minigame_game_state
        SET ready = ready - v_uid::text
        WHERE session_id = p_session_id;
    END IF;

    RETURN jsonb_build_object('status', 'left');
END;
$$;

REVOKE ALL ON FUNCTION public.leave_minigame_session(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.leave_minigame_session(uuid) TO authenticated, service_role;

COMMIT;
