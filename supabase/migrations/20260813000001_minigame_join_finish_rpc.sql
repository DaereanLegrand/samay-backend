-- Samay — join_minigame_session + finish_minigame_session RPCs (agent R4)
-- Migration 25 of 25.
--
-- Closes the documented server RPC gap (handoff I-77/S-03; TODO.md:2906-2911):
-- MinigameService.joinSession/updateStatus were client-side UPDATEs on
-- minigame_sessions, which has NO UPDATE policy under FORCE RLS
-- (20260809000001) — every join/finish failed with 42501, and a wagered
-- session's escrow (shard_ledger minigame_wager entries) could never be
-- resolved. These two SECURITY DEFINER RPCs move both contracts server-side,
-- mirroring the exact hardening + escrow patterns of
-- create_minigame_session (migration 20260809000006, agent I-63):
-- SECURITY DEFINER + SET search_path = '' + fully-qualified references,
-- business outcomes RETURNED as jsonb (never RAISE'd — I-57 contract),
-- membership gated through the I-32 is_group_member helper, EXECUTE revoked
-- from PUBLIC and granted to authenticated only.
--
-- Contract (client side: lib/core/services/minigame_service.dart):
--
--   join_minigame_session(p_session_id uuid) → jsonb:
--     {status:'not_authenticated'}  auth.uid() is NULL
--     {status:'session_not_found'}  no session row for p_session_id
--     {status:'not_member'}         caller not an active member of the
--                                   session's group (is_group_member)
--     {status:'session_not_active'} session already finished (GMCR: joins
--                                   only on active sessions)
--     {status:'joined'}             caller appended to participants
--                                   (idempotent — repeat joins are a no-op)
--     {status:'insufficient_shards'} balance below the session's shard_wager
--
--   Escrow on join (GWAG §Wager Acceptance: "wagers deducted ... immediately
--   for each participant"): when shard_wager > 0 the JOINING user's
--   personal_shards are deducted (guarded UPDATE — never overdrawn) and a
--   shard_ledger row with reason=minigame_wager and reference_id = session id
--   is written — the exact mirror of create_minigame_session's steps 5+7.
--   All writes happen in ONE transaction; a failure rolls everything back.
--
--   finish_minigame_session(p_session_id uuid, p_winner_id uuid,
--                           p_place integer) → jsonb:
--     {status:'not_authenticated'}
--     {status:'session_not_found'}
--     {status:'not_member'}
--     {status:'already_finished'}   idempotent — settlement already ran
--     {status:'invalid_winner'}     p_winner_id not NULL and not a participant
--     {status:'finished'}           escrow settled, status='finished',
--                                   winner_id set
--
--   Settlement (GWAG §Wager Resolution, mirrored exactly):
--     * Winner path (p_winner_id NOT NULL): the winner receives the full
--       escrow pot (shard_wager x len(participants)) — UPDATE
--       users.personal_shards + shard_ledger minigame_win entry. Losers get
--       NO refund — their minigame_wager deduction IS the loss record.
--     * Draw path (p_winner_id NULL, the client contract for
--       MinigameService.updateStatus which carries no winner): every
--       participant is refunded shard_wager — UPDATE users.personal_shards +
--       shard_ledger minigame_refund entry (reversing the deduction).
--     * shard_wager = 0: nothing to settle; the status flip is the whole
--       write.
--
--   p_place is accepted for the future result-row contract (rank within the
--   session) but is currently unused: the schema has no minigame_results
--   table (full_schema §3.22 defines only minigame_sessions), so there is no
--   result row to record yet. It is validated to be non-negative when
--   provided (negative places are never legitimate) and otherwise ignored —
--   adding it now keeps the RPC signature stable for the client.
--
--   Both RPCs SELECT the session row FOR UPDATE, serializing concurrent
--   joins/finishes so the participants array never suffers a lost update
--   (create_minigame_session inserts its own row, so it needs no lock).

CREATE OR REPLACE FUNCTION public.join_minigame_session(
    p_session_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_current_user uuid;
    v_group_id uuid;
    v_wager integer;
    v_status public.mini_game_status;
    v_participants uuid[];
BEGIN
    -- 1. Authentication gate (same as create_minigame_session step 1).
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock: serializes concurrent joins so the
    --    participants append can never lose an update.
    SELECT group_id, shard_wager, status, participants
        INTO v_group_id, v_wager, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Group-membership gate (GMCR: all games are group-scoped; only
    --    active members may join) — is_group_member is recursion-safe.
    IF NOT public.is_group_member(v_group_id) THEN
        RETURN jsonb_build_object('status', 'not_member');
    END IF;

    -- 4. Lifecycle gate: joins only on active sessions.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. Idempotency: an existing participant re-joining is a no-op
    --    (the client contract never removes participants).
    IF v_current_user = ANY(v_participants) THEN
        RETURN jsonb_build_object('status', 'joined');
    END IF;

    -- 6. Escrow on join (GWAG: wagers deducted immediately for EACH
    --    participant; mirror of create_minigame_session steps 5 + 7).
    IF v_wager > 0 THEN
        UPDATE public.users
        SET personal_shards = personal_shards - v_wager
        WHERE id = v_current_user AND personal_shards >= v_wager;

        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'insufficient_shards');
        END IF;

        INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
        VALUES (v_current_user, -v_wager, 'minigame_wager', p_session_id);
    END IF;

    -- 7. Append the caller to the participants array (self only).
    UPDATE public.minigame_sessions
    SET participants = participants || ARRAY[v_current_user]
    WHERE id = p_session_id;

    RETURN jsonb_build_object('status', 'joined');
END;
$$;

CREATE OR REPLACE FUNCTION public.finish_minigame_session(
    p_session_id uuid,
    p_winner_id uuid,
    p_place integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_current_user uuid;
    v_group_id uuid;
    v_wager integer;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_participant uuid;
    v_escrow integer;
BEGIN
    -- 1. Authentication gate.
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock: settlement and the status flip must be
    --    serialized against concurrent finishes/joins.
    SELECT group_id, shard_wager, status, participants
        INTO v_group_id, v_wager, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Group-membership gate (only group members may settle a session).
    IF NOT public.is_group_member(v_group_id) THEN
        RETURN jsonb_build_object('status', 'not_member');
    END IF;

    -- 4. Lifecycle gate: only active sessions settle (repeat finishes are
    --    idempotent no-ops — the escrow must never be paid twice).
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'already_finished');
    END IF;

    -- 5. Winner gate: a declared winner must be one of the participants
    --    (GWAG: the winner is a player; NULL winner = draw).
    IF p_winner_id IS NOT NULL AND NOT (p_winner_id = ANY(v_participants)) THEN
        RETURN jsonb_build_object('status', 'invalid_winner');
    END IF;

    -- 6. Escrow settlement (GWAG §Wager Resolution).
    IF v_wager > 0 THEN
        IF p_winner_id IS NULL THEN
            -- Draw: refund every participant (minigame_refund reverses the
            -- minigame_wager deduction).
            FOREACH v_participant IN ARRAY v_participants
            LOOP
                UPDATE public.users
                SET personal_shards = personal_shards + v_wager
                WHERE id = v_participant;

                INSERT INTO public.shard_ledger
                    (user_id, delta, reason, reference_id)
                VALUES (v_participant, v_wager, 'minigame_refund',
                        p_session_id);
            END LOOP;
        ELSE
            -- Winner takes the whole pot; losers' deductions stand (their
            -- minigame_wager entry IS the loss record).
            v_escrow := v_wager * COALESCE(array_length(v_participants, 1), 0);

            UPDATE public.users
            SET personal_shards = personal_shards + v_escrow
            WHERE id = p_winner_id;

            INSERT INTO public.shard_ledger
                (user_id, delta, reason, reference_id)
            VALUES (p_winner_id, v_escrow, 'minigame_win', p_session_id);
        END IF;
    END IF;

    -- 7. Status flip + winner record (p_place is reserved for the future
    --    result-row contract; no minigame_results table exists yet).
    UPDATE public.minigame_sessions
    SET status = 'finished',
        winner_id = p_winner_id
    WHERE id = p_session_id;

    RETURN jsonb_build_object('status', 'finished');
END;
$$;

REVOKE ALL ON FUNCTION public.join_minigame_session(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.join_minigame_session(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.finish_minigame_session(uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.finish_minigame_session(uuid, uuid, integer) TO authenticated;
