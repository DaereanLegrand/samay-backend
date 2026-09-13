-- ======================================================================
-- Public partidas (210_minigame_public).
--
-- Until now a direct partida was visible ONLY to its participants and its
-- pending invitees (ms_read_direct_participant / ms_read_invitee), so the
-- only way in was a personal invite. A host can now PUBLISH a partida: it
-- shows up in an open lobby list that ANY signed-in user can browse and
-- join, without an invite.
--
-- Published partidas stay bounded by everything that already guards a
-- session: the frozen player_limit, the active-status gate and the wager
-- escrow on join.
-- ======================================================================

ALTER TABLE public.minigame_sessions
    ADD COLUMN IF NOT EXISTS is_public boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.minigame_sessions.is_public IS
    'The host published this partida to the open lobby (210_minigame_public): any signed-in user can read the row (ms_read_public) and join it (join_minigame_session). Direct sessions only.';

CREATE INDEX IF NOT EXISTS idx_minigame_sessions_public
    ON public.minigame_sessions (game_type, created_at DESC)
    WHERE is_public AND group_id IS NULL;

-- Any signed-in user reads a PUBLISHED, still-open direct partida. The
-- policy is additive: private partidas keep the participant/invitee-only
-- posture they had.
DROP POLICY IF EXISTS ms_read_public ON public.minigame_sessions;
CREATE POLICY ms_read_public ON public.minigame_sessions FOR SELECT USING (
    is_public
    AND group_id IS NULL
    AND status = 'active'
    AND auth.uid() IS NOT NULL
);

-- ----------------------------------------------------------------------
-- set_minigame_public(uuid, boolean) — the HOST publishes / unpublishes.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_minigame_public(
    p_session_id uuid,
    p_is_public boolean
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_participants uuid[];
    v_group_id uuid;
    v_status public.mini_game_status;
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
    -- The host is participants[1] (the creator, 1-based SQL array).
    IF v_participants[1] IS DISTINCT FROM auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_creator');
    END IF;
    IF v_group_id IS NOT NULL THEN
        RETURN jsonb_build_object('status', 'group_session');
    END IF;
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    UPDATE public.minigame_sessions
       SET is_public = p_is_public
     WHERE id = p_session_id;

    RETURN jsonb_build_object('status', 'ok', 'is_public', p_is_public);
END;
$$;

-- ----------------------------------------------------------------------
-- list_public_minigames(text) — the open lobby feed.
-- Returns published, still-open direct partidas with room left, newest
-- first, resolved with the host's username in ONE round trip (mirrors
-- get_minigame_participants' user_search_view read).
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_public_minigames(
    p_game_type text DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_rows jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT COALESCE(jsonb_agg(row_to_json(t)::jsonb ORDER BY t.created_at DESC), '[]'::jsonb)
      INTO v_rows
      FROM (
        SELECT s.id,
               s.game_type::text          AS game_type,
               s.name,
               s.auto_name,
               s.shard_wager,
               s.player_limit,
               COALESCE(array_length(s.participants, 1), 0) AS player_count,
               s.created_at,
               (auth.uid() = ANY (s.participants))          AS is_member,
               u.username                                   AS host_username,
               u.avatar_url                                 AS host_avatar_url
          FROM public.minigame_sessions s
          LEFT JOIN public.user_search_view u ON u.id = s.participants[1]
         WHERE s.is_public
           AND s.group_id IS NULL
           AND s.status = 'active'
           AND (p_game_type IS NULL OR s.game_type::text = p_game_type)
         ORDER BY s.created_at DESC
         LIMIT 50
      ) t;

    RETURN jsonb_build_object('status', 'ok', 'sessions', v_rows);
END;
$$;

-- ----------------------------------------------------------------------
-- join_minigame_session(uuid) — REPLACED to admit public joins.
--
-- Identical to 100_minigames/sessions.sql except step 3, which now also
-- lets a caller in when the partida was PUBLISHED (is_public). Everything
-- else (active gate, idempotent re-join, player cap, wager escrow) is
-- unchanged and still applies to public joiners.
-- ----------------------------------------------------------------------
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
    v_is_public boolean;
BEGIN
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT group_id, shard_wager, status, participants, player_limit, is_public
        INTO v_group_id, v_wager, v_status, v_participants, v_player_limit, v_is_public
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
           AND NOT COALESCE(v_is_public, false)
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

REVOKE ALL ON FUNCTION public.set_minigame_public(uuid, boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_minigame_public(uuid, boolean) TO authenticated;
GRANT ALL ON FUNCTION public.set_minigame_public(uuid, boolean) TO service_role;

REVOKE ALL ON FUNCTION public.list_public_minigames(text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_public_minigames(text) TO authenticated;
GRANT ALL ON FUNCTION public.list_public_minigames(text) TO service_role;
