-- Samay — 180_minigame_lobby/lobby.sql
-- Minigame partida lobby (2026-08-30): realtime participant list, per-player
-- Ready, creator-only Start, and creator removal.
--
-- Model (industry-standard lobby pattern mapped onto the DB-as-authoritative
-- state architecture — Colyseus/Nakama-style room state):
--
--   * The `minigame_game_state` row IS the room state; a NEW `ready` jsonb
--     map (`{participant_id: bool}`) is the authoritative "who is ready"
--     roster (the Colyseus MapSchema<Player> analog). `ready` lives on the
--     GAME-STATE row, NOT the session row, so the existing
--     `minigame_game_state` realtime subscription streams every toggle live
--     to the whole lobby.
--   * set_minigame_ready(uuid, boolean) — a SECURITY DEFINER RPC (server-side
--     intent handler): validates the caller is participant / invitee / group
--     member and the session is active, then upserts the caller's ready flag
--     into the `ready` map. Clients never write the row directly (FORCE RLS).
--   * get_minigame_participants(uuid) — SECURITY DEFINER RPC returning
--     [{id, username, avatar_url}] for the session's participants, read via
--     the security-barrier `user_search_view` (deleted + blocked excluded).
--     One batched call — no N+1, and it works for NON-friends (the
--     get_friend_profiles RPC is friends-only and would drop strangers).
--   * remove_minigame_participant(uuid, uuid) — SECURITY DEFINER RPC, gated
--     to the CREATOR (participants[0], the session's host — host authority
--     per the lobby pattern). Refunds the removed player's wager escrow
--     (GWAG mirror of finish/complete draw settlement), removes them from
--     `participants`, deletes their invite row, and drops their ready flag —
--     one transaction. The creator can never remove themself.
--   * init_minigame_game_state (CREATE OR REPLACE, unchanged signature):
--     the `lobby -> playing` transition is now CREATOR-ONLY, enforced
--     SERVER-SIDE (participants[0] gate → `not_creator`). Anyone else gets
--     `not_creator` even if they call the RPC directly (backend-enforced,
--     never just a UI rule). The ready map is cleared on init.
--   * minigame_sessions JOINS supabase_realtime (guarded) so participant
--     join/remove UPDATEs stream live to the lobby — the session row was
--     missing from the publication, so a realtime participants list could
--     not see a peer join or be removed.
--
-- Posture mirrors 100/140/150: FORCE RLS, every mutation through SECURITY
-- DEFINER RPCs, PUBLIC EXECUTE revoked, authenticated + service_role only.

-- ======================================================================
-- minigame_game_state.ready — the authoritative per-participant ready map
-- ======================================================================
ALTER TABLE public.minigame_game_state
    ADD COLUMN ready jsonb;

COMMENT ON COLUMN public.minigame_game_state.ready IS
    'Authoritative per-participant ready map {participant_id: bool} for the partida lobby (180_minigame_lobby). Written ONLY through set_minigame_ready; streamed live via the minigame_game_state realtime subscription. Cleared on init_minigame_game_state.';

-- ======================================================================
-- Realtime: minigame_sessions joins supabase_realtime so participant
-- join/remove UPDATEs (and the status flip) stream LIVE to the lobby.
-- Guarded — never fights make supabase-init (mirror of 150/960 guards).
-- ======================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_sessions') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.minigame_sessions;
  END IF;
END
$$;

-- ======================================================================
-- set_minigame_ready(uuid, boolean)
-- Server-side intent handler for the Ready toggle: validates standing
-- (auth + participant/invitee/group-member + active session), then upserts
-- the caller's flag into the `ready` jsonb map. The whole lobby sees the
-- change instantly through the minigame_game_state realtime stream.
-- ======================================================================
CREATE FUNCTION public.set_minigame_ready(p_session_id uuid, p_ready boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (serialize against finish/remove/init).
    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate (participant / invitee / group member — mirrors the
    --    play-engine RPCs).
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

    -- 4. Lifecycle gate: ready toggles only while the session is active.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. Upsert the caller's ready flag into the ready map. The game-state
    --    row may not exist yet (the lobby precedes Start — `init` runs
    --    later), so INSERT ... ON CONFLICT seeds a skeleton with the ready
    --    flag when the row is absent. The whole lobby sees the toggle
    --    through the game-state realtime subscription.
    INSERT INTO public.minigame_game_state (session_id, game_type, state, ready)
    SELECT p_session_id,
           s.game_type,
           '{}'::jsonb,
           jsonb_build_object(auth.uid()::text, p_ready)
      FROM public.minigame_sessions AS s
     WHERE s.id = p_session_id
    ON CONFLICT (session_id) DO UPDATE
        SET ready = COALESCE(minigame_game_state.ready, '{}'::jsonb)
                    || jsonb_build_object(auth.uid()::text, p_ready);

    RETURN jsonb_build_object('status', 'ready');
END;
$$;

-- ======================================================================
-- get_minigame_participants(uuid)
-- The lobby's presence roster: username + avatar for the session's
-- participants, in ONE round trip (I-57 typed-jsonb-status contract, mirror
-- of the other play-engine RPCs). Reads `user_search_view` (security barrier
-- — deleted + blocked excluded) and works for NON-friends, unlike
-- get_friend_profiles. Gates: auth + participant/invitee/group-member.
-- ======================================================================
CREATE FUNCTION public.get_minigame_participants(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_participants uuid[];
    v_roster jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + access gate (participant / invitee / group member).
    SELECT group_id, participants
        INTO v_group_id, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;
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

    -- 3. Resolve the roster through the security-barrier view.
    SELECT COALESCE(jsonb_agg(
               jsonb_build_object(
                   'id', usv.id,
                   'username', usv.username,
                   'avatar_url', usv.avatar_url
               )
           ), '[]'::jsonb)
        INTO v_roster
      FROM public.user_search_view AS usv
     WHERE usv.id = ANY(v_participants);

    RETURN jsonb_build_object('status', 'ok', 'participants', v_roster);
END;
$$;

-- ======================================================================
-- remove_minigame_participant(uuid, uuid)
-- Creator-only removal (host authority): the caller must be the session
-- creator (participants[0]). In ONE transaction it refunds the removed
-- player's wager escrow (GWAG: minigame_refund ledger row + personal_shards
-- credit, mirror of the draw settlement), removes them from `participants`,
-- deletes their invite row, and drops their ready flag. The creator is
-- never removable; a finished session cannot be modified.
-- ======================================================================
CREATE FUNCTION public.remove_minigame_participant(p_session_id uuid, p_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_wager integer;
    v_participants uuid[];
    v_new_participants uuid[];
    v_participant uuid;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (serialize concurrent removes/joins).
    SELECT group_id, status, shard_wager, participants
        INTO v_group_id, v_status, v_wager, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Creator gate — backend-enforced, not a UI rule: the caller MUST be
    --    participants[0] (the session host).
    IF array_length(v_participants, 1) IS NULL
       OR v_participants[1] <> auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_creator');
    END IF;

    -- 4. Lifecycle gate: only active sessions can lose a player.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. Target gate: must be an actual participant, and never the creator.
    IF p_user_id = auth.uid() OR NOT (p_user_id = ANY(v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_participant');
    END IF;

    -- 6. Refund the removed player's wager escrow (GWAG mirror of the draw
    --    settlement in finish/complete — the minigame_refund reversal).
    IF v_wager > 0 THEN
        UPDATE public.users
        SET personal_shards = personal_shards + v_wager
        WHERE id = p_user_id;

        INSERT INTO public.shard_ledger
            (user_id, delta, reason, reference_id)
        VALUES (p_user_id, v_wager, 'minigame_refund', p_session_id);
    END IF;

    -- 7. Drop the player from participants (creator stays index 0).
    SELECT array_agg(p) INTO v_new_participants
      FROM unnest(v_participants) AS p
     WHERE p <> p_user_id;
    IF v_new_participants IS NULL THEN
        v_new_participants := ARRAY[]::uuid[];
    END IF;
    UPDATE public.minigame_sessions
    SET participants = v_new_participants
    WHERE id = p_session_id;

    -- 8. Close their invite row (pending OR accepted — the invite is no
    --    longer meaningful once the player is out).
    DELETE FROM public.minigame_invites
    WHERE session_id = p_session_id AND invitee_id = p_user_id;

    -- 9. Drop their ready flag.
    UPDATE public.minigame_game_state
    SET ready = ready - p_user_id::text
    WHERE session_id = p_session_id;

    RETURN jsonb_build_object('status', 'removed');
END;
$$;

-- ======================================================================
-- init_minigame_game_state(uuid) — CREATE OR REPLACE (same signature as
-- 150). The `lobby -> playing` transition is now CREATOR-ONLY and enforced
-- SERVER-SIDE: a non-creator participant (or invitee / group member) gets
-- `not_creator` even when calling the RPC directly. Every other behavior is
-- byte-identical to 150: session lock, idempotent already_started, random
-- first subject, game-agnostic skeleton. The ready map clears on init.
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
    --    bystander gets `not_allowed` (unchanged 150 contract, pinned by
    --    opt-018). Only after standing is confirmed does the creator gate run.
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

    -- 3b. Creator-only Start gate (180_minigame_lobby, backend-enforced):
    --     participants[0] is the session host; ONLY they may transition the
    --     lobby to playing. A non-creator participant / invitee / group member
    --     gets `not_creator` (never a UI rule).
    IF array_length(v_participants, 1) IS NULL
       OR v_participants[1] <> auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_creator');
    END IF;

    -- 4. Lifecycle gate: only active sessions start a play engine.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. Idempotency: an existing PLAYING row is a no-op. But a row seeded
    --    by set_minigame_ready (lobby skeleton, `state = {}`, no random
    --    subject yet) must still be STARTED — seed the skeleton, pick the
    --    random first subject and clear the ready map (the lobby roster
    --    resets once the game begins).
    SELECT to_jsonb(m) INTO v_existing
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_existing IS NOT NULL
       AND v_existing -> 'state' ->> 'phase' = 'playing' THEN
        RETURN jsonb_build_object('status', 'already_started', 'state', v_existing);
    END IF;

    -- 6. Random first subject (server-random — players never self-select).
    v_count := COALESCE(array_length(v_participants, 1), 0);
    IF v_count = 0 THEN
        RETURN jsonb_build_object('status', 'no_participants');
    END IF;
    v_random_index := 1 + floor(random() * v_count)::integer;

    v_state := jsonb_build_object(
        'judge_index', 0,
        'round', 0,
        'phase', 'playing',
        'subject_id', v_participants[v_random_index],
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
-- ACLs — hardened posture (no PUBLIC; authenticated + service_role only,
-- mirror of 140/150/160/170).
-- ======================================================================
REVOKE ALL ON FUNCTION public.set_minigame_ready(p_session_id uuid, p_ready boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_minigame_ready(p_session_id uuid, p_ready boolean) TO authenticated;
GRANT ALL ON FUNCTION public.set_minigame_ready(p_session_id uuid, p_ready boolean) TO service_role;

REVOKE ALL ON FUNCTION public.get_minigame_participants(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_minigame_participants(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_minigame_participants(p_session_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.remove_minigame_participant(p_session_id uuid, p_user_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.remove_minigame_participant(p_session_id uuid, p_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.remove_minigame_participant(p_session_id uuid, p_user_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.init_minigame_game_state(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.init_minigame_game_state(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.init_minigame_game_state(p_session_id uuid) TO service_role;
