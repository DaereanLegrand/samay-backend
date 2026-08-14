-- Samay — create_minigame_session RPC (agent I-63, GMCR/GWAG foundation)
-- Migration 23 of 23.
--
-- Server-side contract for minigame session creation
-- (docs/specs/steps/phase-11-gamification-minigames/GMCR-minigames-core.md
-- + GWAG-wager-system.md): the client calls this SECURITY DEFINER RPC instead
-- of inserting into minigame_sessions directly, because under FORCE RLS the
-- table has no INSERT/UPDATE policy (only ms_read_group_member SELECT) and
-- users.personal_shards is column-level REVOKEd from authenticated (G-03).
--
-- Contract (client side: lib/core/services/minigame_service.dart):
--   * Business outcomes are RETURNED as jsonb (never RAISE'd) so the client
--     maps them to typed errors without parsing exception messages (I-57
--     pattern):
--       {status:'not_authenticated'}  auth.uid() is NULL
--       {status:'not_member'}         caller not an active member of the group
--       {status:'invalid_wager'}      p_wager < 0 (GWAG: integer shards >= 0)
--       {status:'invalid_game_type'}  p_game_type not in mini_game_type enum
--       {status:'insufficient_shards'} balance below the wager
--       {status:'created', sessionId} session inserted, escrow started
--   * The membership gate delegates to the I-32 SECURITY DEFINER helper
--     public.is_group_member() (recursion-safe; active members only).
--   * Wager escrow (GWAG §Wager Acceptance): when p_wager > 0 the caller's
--     personal_shards are deducted immediately (guarded UPDATE — never
--     overdrawn) and a shard_ledger row with reason=minigame_wager and
--     reference_id = session id is written. All writes happen in ONE
--     transaction (plpgsql function body), so a failed insert rolls back the
--     deduction and vice-versa. Escrow = shard_wager x participants,
--     verifiable by summing the minigame_wager ledger rows for the session.
--
-- OUT OF SCOPE (documented server RPC gap — handoff I-77/S-03):
--   * join_minigame_session (participants append) — the client contract
--     (MinigameService.joinSession) sends a client-side UPDATE that FORCE RLS
--     currently blocks.
--   * Winner settlement: minigame_win ledger + escrow credit to the winner,
--     and minigame_refund on draw — the GWAG §Wager Resolution writes. A
--     SECURITY DEFINER finish_minigame_session RPC (session id + winner id)
--     must add them server-side before wagers can be resolved.
--
-- Hardening (I-31 pattern): SECURITY DEFINER + SET search_path = '' +
-- fully-qualified object references; EXECUTE revoked from PUBLIC and
-- granted to authenticated only.

CREATE OR REPLACE FUNCTION public.create_minigame_session(
    p_group_id uuid,
    p_game_type text,
    p_wager integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_session_id uuid;
    v_game_type public.mini_game_type;
    v_current_user uuid;
BEGIN
    -- 1. Authentication gate. auth.uid() resolves in the auth schema by
    --    explicit qualification; anon callers (auth.uid() = NULL) fail here.
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Group-membership gate (GMCR: all games are group-scoped; only
    --    active members may create sessions).
    IF NOT public.is_group_member(p_group_id) THEN
        RETURN jsonb_build_object('status', 'not_member');
    END IF;

    -- 3. Wager validation (GWAG: integer shards >= 0; 0 = no wager).
    IF p_wager < 0 THEN
        RETURN jsonb_build_object('status', 'invalid_wager');
    END IF;

    -- 4. Game-type validation against the mini_game_type enum (the cast
    --    raises invalid_text_representation for unknown values).
    BEGIN
        v_game_type := p_game_type::public.mini_game_type;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('status', 'invalid_game_type');
    END;

    -- 5. Wager escrow — deduct immediately (GWAG: "deducted immediately on
    --    acceptance and held in escrow"; the deduction IS the loss record).
    --    The guarded UPDATE never overdraws; SECURITY DEFINER bypasses the
    --    G-03 column REVOKE + assert_safe_user_update privileged gate.
    IF p_wager > 0 THEN
        UPDATE public.users
        SET personal_shards = personal_shards - p_wager
        WHERE id = v_current_user AND personal_shards >= p_wager;

        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'insufficient_shards');
        END IF;
    END IF;

    -- 6. Session insert (GMCR step 4: status=active; the initiator is the
    --    first participant — the participant-select UI is future work).
    INSERT INTO public.minigame_sessions
        (group_id, game_type, status, shard_wager, participants)
    VALUES
        (p_group_id, v_game_type, 'active', p_wager, ARRAY[v_current_user])
    RETURNING id INTO v_session_id;

    -- 7. Ledger entry with the session reference (escrow verifiability:
    --    sum of minigame_wager rows for this session = pot).
    IF p_wager > 0 THEN
        INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
        VALUES (v_current_user, -p_wager, 'minigame_wager', v_session_id);
    END IF;

    RETURN jsonb_build_object('status', 'created', 'sessionId', v_session_id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_minigame_session(uuid, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_minigame_session(uuid, text, integer) TO authenticated;
