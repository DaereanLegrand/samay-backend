-- ============================================================================
-- 239_minigame_join_codes/01_join_codes.sql — E4 code-only public matches
--
-- Removes the public lobby and the publish toggle. A direct partida becomes
-- discoverable ONLY through a 6-character code:
--   * A-Z0-9 minus O/0/I/1/L, case-insensitive;
--   * stored as a SHA-256 hash, never listed or logged;
--   * valid while the session is active; the host can rotate or revoke;
--   * joins enforce status/player limit/wager and 10 attempts/min/account.
-- Existing `is_public` sessions get a code (the host can rotate to see one)
-- and stay joinable; participants/wagers are not touched.
--
-- Rollback: forward-fix only. Restoring the open lobby would require an owner
-- decision (it is removed by Q13/E4).
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Code storage.
-- ---------------------------------------------------------------------------
ALTER TABLE public.minigame_sessions
    ADD COLUMN IF NOT EXISTS join_code_hash text;
ALTER TABLE public.minigame_sessions
    ADD COLUMN IF NOT EXISTS join_code_rotated_at timestamp with time zone;

COMMENT ON COLUMN public.minigame_sessions.join_code_hash IS
    'E4: SHA-256 hex of the 6-character join code. Never store or log the plaintext; the host receives it once from set/rotate.';

CREATE OR REPLACE FUNCTION public.new_minigame_join_code()
RETURNS text
    LANGUAGE sql VOLATILE
    SET search_path TO ''
    AS $$
    SELECT string_agg(
               substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789',
                      1 + floor(random() * 31)::integer, 1),
               '')
      FROM generate_series(1, 6);
$$;

REVOKE ALL ON FUNCTION public.new_minigame_join_code() FROM PUBLIC, anon, authenticated;

-- Backfill every existing public session with an unknown code; the host can
-- rotate to obtain a fresh one.
UPDATE public.minigame_sessions
   SET join_code_hash = encode(
           extensions.digest(public.new_minigame_join_code(), 'sha256'),
           'hex'),
       join_code_rotated_at = now()
 WHERE is_public
   AND group_id IS NULL
   AND join_code_hash IS NULL;

-- ---------------------------------------------------------------------------
-- 2. Remove the open lobby.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS ms_read_public ON public.minigame_sessions;
DROP INDEX IF EXISTS public.idx_minigame_sessions_public;
DROP FUNCTION IF EXISTS public.list_public_minigames(text);
DROP FUNCTION IF EXISTS public.set_minigame_public(uuid, boolean);

-- join_minigame_session is invite/participant-only again (no is_public).
CREATE OR REPLACE FUNCTION public.join_minigame_session(p_session_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_current_user uuid;
    v_group_id uuid;
    v_wager integer;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_player_limit integer;
BEGIN
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT group_id, shard_wager, status, participants, player_limit
        INTO v_group_id, v_wager, v_status, v_participants, v_player_limit
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    IF v_group_id IS NOT NULL THEN
        IF NOT public.is_group_member(v_group_id) THEN
            RETURN jsonb_build_object('status', 'not_member');
        END IF;
    ELSE
        IF v_current_user <> ALL(v_participants)
           AND NOT EXISTS (
               SELECT 1 FROM public.minigame_invites
               WHERE session_id = p_session_id
                 AND invitee_id = v_current_user
                 AND status = 'pending'
           )
        THEN
            RETURN jsonb_build_object('status', 'not_allowed');
        END IF;
    END IF;

    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    IF v_current_user = ANY(v_participants) THEN
        RETURN jsonb_build_object('status', 'joined');
    END IF;

    IF array_length(v_participants, 1) >= v_player_limit THEN
        RETURN jsonb_build_object('status', 'player_limit_reached');
    END IF;

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

    UPDATE public.minigame_sessions
    SET participants = participants || ARRAY[v_current_user]
    WHERE id = p_session_id;

    RETURN jsonb_build_object('status', 'joined');
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Host: set/rotate/revoke the code.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_minigame_join_code(p_session_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_participants uuid[];
    v_group_id uuid;
    v_status public.mini_game_status;
    v_code text;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT participants, group_id, status
        INTO v_participants, v_group_id, v_status
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;
    IF v_participants[1] IS DISTINCT FROM auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_creator');
    END IF;
    IF v_group_id IS NOT NULL THEN
        RETURN jsonb_build_object('status', 'group_session');
    END IF;
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    v_code := public.new_minigame_join_code();
    UPDATE public.minigame_sessions
       SET join_code_hash = encode(extensions.digest(v_code, 'sha256'), 'hex'),
           join_code_rotated_at = now()
     WHERE id = p_session_id;

    -- The ONLY response that carries the plaintext code.
    RETURN jsonb_build_object('status', 'ok', 'code', v_code);
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_minigame_join_code(p_session_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_participants uuid[];
    v_group_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT participants, group_id
        INTO v_participants, v_group_id
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;
    IF v_participants[1] IS DISTINCT FROM auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_creator');
    END IF;

    UPDATE public.minigame_sessions
       SET join_code_hash = NULL,
           join_code_rotated_at = now()
     WHERE id = p_session_id;

    RETURN jsonb_build_object('status', 'ok');
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Join by code (case-insensitive, rate-limited, no lobby).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.join_minigame_by_code(p_code text)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid := auth.uid();
    v_code text;
    v_session public.minigame_sessions;
    v_hash text;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    v_code := upper(btrim(COALESCE(p_code, '')));
    IF char_length(v_code) <> 6
       OR v_code !~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$' THEN
        RETURN jsonb_build_object('status', 'invalid_code');
    END IF;

    -- 10 attempts/min/account (per-IP flood guard is handled at the gateway).
    PERFORM public.consume_action_limit(
        v_uid, 'minigame_code_join', '', 10, interval '1 minute');

    v_hash := encode(extensions.digest(v_code, 'sha256'), 'hex');

    SELECT * INTO v_session
      FROM public.minigame_sessions
     WHERE join_code_hash = v_hash
       AND group_id IS NULL
       AND status = 'active'
     FOR UPDATE
     LIMIT 1;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'invalid_code');
    END IF;

    IF v_uid = ANY (v_session.participants) THEN
        RETURN jsonb_build_object('status', 'joined', 'session_id', v_session.id);
    END IF;

    IF array_length(v_session.participants, 1) >= v_session.player_limit THEN
        RETURN jsonb_build_object('status', 'player_limit_reached',
                                  'session_id', v_session.id);
    END IF;

    IF v_session.shard_wager > 0 THEN
        UPDATE public.users
           SET personal_shards = personal_shards - v_session.shard_wager
         WHERE id = v_uid AND personal_shards >= v_session.shard_wager;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'insufficient_shards',
                                      'session_id', v_session.id);
        END IF;
        INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
        VALUES (v_uid, -v_session.shard_wager, 'minigame_wager', v_session.id);
    END IF;

    UPDATE public.minigame_sessions
       SET participants = participants || ARRAY[v_uid]
     WHERE id = v_session.id;

    RETURN jsonb_build_object('status', 'joined', 'session_id', v_session.id);
END;
$$;

REVOKE ALL ON FUNCTION public.set_minigame_join_code(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revoke_minigame_join_code(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.join_minigame_by_code(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_minigame_join_code(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.revoke_minigame_join_code(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.join_minigame_by_code(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Drop the publish toggle column after the code backfill.
-- ---------------------------------------------------------------------------
ALTER TABLE public.minigame_sessions DROP COLUMN IF EXISTS is_public;

COMMIT;
