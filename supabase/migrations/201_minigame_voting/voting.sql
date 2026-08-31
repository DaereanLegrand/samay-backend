-- Samay — 201_minigame_voting/voting.sql
-- Rounds, reaction voting and the leaderboard prize payout (2026-08-30).
--
-- Product contract (user directives):
--   * The create wizard (all 5 games) gains a round count (default 5, total
--     turns).
--   * The BACKEND takes N = the number of paid prize positions
--     (`p_prize_positions`, stored on `minigame_sessions.prize_positions`).
--     Prizes split HARMONICALLY by rank: share_i = (1/i) / Σ_{k=1..N}(1/k).
--     The split is computed in INTEGER arithmetic (LCM-normalized weights +
--     largest-remainder distribution) so the paid sum is ALWAYS exactly the
--     pot — never more, never less (no floating-point drift). N is capped at
--     the participant count (you cannot pay more places than players).
--     The UI for the HOST to set N is deferred (TODO); the client sends a
--     default N = 3 for now.
--   * When the round target is reached the game ENDS AUTOMATICALLY (no host
--     tap) and the leaderboard is settled server-side.
--   * Verdad o Reto adds REACTION VOTING: after a prompt is revealed, every
--     participant votes one emoji (disgust/sad/surprised/excited/demon/heart)
--     on the round's subject. Each reaction = +1 point to the subject; a
--     subject with ZERO reactions gets -1 for that round. Voting is realtime
--     (the reactions payload streams on the existing minigame_game_state
--     realtime channel).
--   * Prize pool = total wager pot (wager x participants). Free games
--     (wager 0) show the leaderboard with no shards.
--
-- Model:
--   * minigame_sessions.round_target (int, NULLable = legacy open-ended) and
--     minigame_sessions.prize_positions (int, default 3), both frozen at
--     creation by the redefined create_minigame_session
--     (7-arg: + p_rounds, p_prize_positions).
--   * minigame_reactions — one row per (session, round, voter); FORCE RLS,
--     reads by participants, writes ONLY through submit_minigame_reaction.
--     The round's live vote state ALSO rides the game-state payload
--     (state.reactions: {subject_id: [emoji...]}) so every participant sees
--     votes stream in realtime without a second channel.
--   * minigame_results — the settle-once leaderboard row (rank, score, prize
--     per participant), written ONLY by finish_minigame_game. FORCE RLS,
--     readable by participants/invitees/group members (mirror of
--     mgs_read_participant semantics).
--   * submit_minigame_reaction(uuid, text) — SECURITY DEFINER upsert of the
--     caller's vote for the CURRENT round, mirrors the reaction into
--     state.reactions (realtime), idempotent per voter (one vote locks).
--   * advance_minigame_turn (CREATE OR REPLACE) — appends the completed round
--     WITH the server-computed score (reaction count, or -1 for zero votes)
--     into the round record, clears state.reactions, and AUTO-FINISHES via
--     finish_minigame_game when round+1 reaches round_target.
--   * finish_minigame_game(uuid) — the single settlement seam REPLACING both
--     finish_minigame_session (winner-takes-all) and complete_minigame_game
--     (draw-only): computes the scoreboard from rounds history, pays the
--     prize split into users.personal_shards with shard_ledger reason
--     minigame_win, writes minigame_results + flips phase + session status to
--     finished. Idempotent.
--
-- Posture mirrors 100/140/150/180/190/191: FORCE RLS, mutations through
-- SECURITY DEFINER RPCs only, PUBLIC EXECUTE revoked, authenticated +
-- service_role.

-- ======================================================================
-- 1. minigame_sessions: round target + prize distribution
-- ======================================================================
ALTER TABLE public.minigame_sessions
    ADD COLUMN round_target integer;

ALTER TABLE public.minigame_sessions
    ADD COLUMN prize_positions integer DEFAULT 3 NOT NULL;

COMMENT ON COLUMN public.minigame_sessions.round_target IS
    'Total-turn target (201_minigame_voting). NULL = legacy open-ended games; the play engine auto-finishes when the round counter reaches this.';
COMMENT ON COLUMN public.minigame_sessions.prize_positions IS
    'Number of paid prize positions N frozen at creation (201_minigame_voting). Prizes split harmonically by rank (1/i weights, integer-exact); the host-set N UI is deferred (TODO), the client sends a default.';

-- ======================================================================
-- 2. minigame_reactions — one vote per (session, round, voter)
-- ======================================================================
CREATE TABLE public.minigame_reactions (
    session_id uuid NOT NULL,
    round integer NOT NULL,
    voter_id uuid NOT NULL,
    reaction text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT minigame_reactions_pkey PRIMARY KEY (session_id, round, voter_id),
    CONSTRAINT minigame_reactions_session_id_fkey FOREIGN KEY (session_id)
        REFERENCES public.minigame_sessions(id) ON DELETE CASCADE
);

ALTER TABLE public.minigame_reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE ONLY public.minigame_reactions FORCE ROW LEVEL SECURITY;

CREATE INDEX minigame_reactions_session_round_idx
    ON public.minigame_reactions (session_id, round);

-- The vote is readable exactly when the session row is (participant /
-- invitee / group member) — semantic mirror of mgs_read_participant.
CREATE POLICY mgs_reactions_read ON public.minigame_reactions FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM public.minigame_sessions s
        WHERE s.id = session_id
          AND (
                (s.group_id IS NULL AND auth.uid() = ANY (s.participants))
             OR EXISTS (
                    SELECT 1 FROM public.minigame_invites mi
                    WHERE mi.session_id = s.id AND mi.invitee_id = auth.uid()
                )
             OR EXISTS (
                    SELECT 1 FROM public.group_members gm
                    WHERE gm.group_id = s.group_id AND gm.user_id = auth.uid()
                      AND gm.status = 'active'
                      AND NOT EXISTS (
                            SELECT 1 FROM public.users u
                            WHERE u.id = gm.user_id AND u.deleted_at IS NOT NULL
                        )
                )
          )
    )
);

-- ======================================================================
-- 3. minigame_results — the settle-once leaderboard
-- ======================================================================
CREATE TABLE public.minigame_results (
    session_id uuid NOT NULL,
    results jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT minigame_results_pkey PRIMARY KEY (session_id),
    CONSTRAINT minigame_results_session_id_fkey FOREIGN KEY (session_id)
        REFERENCES public.minigame_sessions(id) ON DELETE CASCADE
);

ALTER TABLE public.minigame_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE ONLY public.minigame_results FORCE ROW LEVEL SECURITY;

-- The leaderboard is readable exactly when the session row is.
CREATE POLICY mgs_results_read ON public.minigame_results FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM public.minigame_sessions s
        WHERE s.id = session_id
          AND (
                (s.group_id IS NULL AND auth.uid() = ANY (s.participants))
             OR EXISTS (
                    SELECT 1 FROM public.minigame_invites mi
                    WHERE mi.session_id = s.id AND mi.invitee_id = auth.uid()
                )
             OR EXISTS (
                    SELECT 1 FROM public.group_members gm
                    WHERE gm.group_id = s.group_id AND gm.user_id = auth.uid()
                      AND gm.status = 'active'
                      AND NOT EXISTS (
                            SELECT 1 FROM public.users u
                            WHERE u.id = gm.user_id AND u.deleted_at IS NOT NULL
                        )
                )
          )
    )
);

-- ======================================================================
-- 4. create_minigame_session — 7-arg (the 191 5-arg is DROP'd; CREATE OR
--    REPLACE cannot change the argument list). Validates the round target +
--    prize choice, freezes them on the session row, and seeds the game-state
--    row (191) with the payload pre-loaded so the round counter and prize
--    distribution are visible from the lobby.
-- ======================================================================
DROP FUNCTION IF EXISTS public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text);
DROP FUNCTION IF EXISTS public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text, p_rounds integer, p_prize_positions integer);

-- The leaderboard settlement REPLACES the legacy winner-takes-all and
-- draw-only seams (201 user directive): drop them so the new RPC is the one
-- and only settlement path.
DROP FUNCTION IF EXISTS public.finish_minigame_session(p_session_id uuid, p_winner_id uuid, p_place integer);
DROP FUNCTION IF EXISTS public.complete_minigame_game(p_session_id uuid);

CREATE FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[] DEFAULT '{}'::uuid[], p_name text DEFAULT NULL, p_rounds integer DEFAULT 5, p_prize_positions integer DEFAULT 3) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_session_id uuid;
    v_game_type public.mini_game_type;
    v_current_user uuid;
    v_invitee uuid;
    v_clean_invitees uuid[] := '{}'::uuid[];
    v_tier public.subscription_tier;
    v_player_limit integer;
    v_name text;
    v_auto_name text;
    v_rounds integer;
    v_prize_positions integer;
BEGIN
    -- 1. Authentication gate.
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 1b. Player cap frozen at creation (direct-minigames 2026-08-27).
    SELECT subscription_tier INTO v_tier
    FROM public.users WHERE id = v_current_user;
    v_player_limit := COALESCE((
        SELECT value::integer FROM public.app_config
        WHERE key = CASE v_tier
            WHEN 'vip'::public.subscription_tier THEN 'minigame.vip_max_players'
            WHEN 'pro'::public.subscription_tier THEN 'minigame.pro_max_players'
            ELSE 'minigame.free_max_players'
        END
    ), 8);

    -- 2. Group-membership gate (direct-minigames 2026-08-27).
    IF p_group_id IS NOT NULL AND NOT public.is_group_member(p_group_id) THEN
        RETURN jsonb_build_object('status', 'not_member');
    END IF;

    -- 3. Wager validation (GWAG: integer shards >= 0; 0 = no wager).
    IF p_wager < 0 THEN
        RETURN jsonb_build_object('status', 'invalid_wager');
    END IF;

    -- 4. Game-type validation against the mini_game_type enum.
    BEGIN
        v_game_type := p_game_type::public.mini_game_type;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('status', 'invalid_game_type');
    END;

    -- 4b. Round-target validation (201): a positive total-turn target.
    v_rounds := COALESCE(p_rounds, 5);
    IF v_rounds < 1 THEN
        RETURN jsonb_build_object('status', 'invalid_rounds');
    END IF;

    -- 4c. Prize-position validation (201): at least one paid position. The
    --     N places are capped at the settlement-time participant count (in
    --     finish_minigame_game) — you cannot pay more places than players.
    v_prize_positions := COALESCE(p_prize_positions, 3);
    IF v_prize_positions < 1 THEN
        RETURN jsonb_build_object('status', 'invalid_prize_positions');
    END IF;

    -- 5. Invitee cleaning + per-invitee gates (blocked / deleted /
    --    friends-only privacy) — a single violation rejects atomically.
    IF p_invitees IS NOT NULL AND array_length(p_invitees, 1) > 0 THEN
        FOR v_invitee IN
            SELECT DISTINCT unnest(p_invitees)
        LOOP
            IF v_invitee = v_current_user THEN
                CONTINUE; -- never invite yourself
            END IF;
            IF array_length(v_clean_invitees, 1) >= 20 THEN
                RETURN jsonb_build_object('status', 'too_many_invitees');
            END IF;

            IF NOT EXISTS (
                SELECT 1 FROM public.users
                WHERE id = v_invitee AND deleted_at IS NULL
            ) THEN
                RETURN jsonb_build_object('status', 'invitee_not_allowed');
            END IF;
            IF EXISTS (
                SELECT 1 FROM public.friendships
                WHERE status = 'blocked'::public.friendship_status
                  AND ((requester_id = v_current_user AND addressee_id = v_invitee)
                    OR (requester_id = v_invitee AND addressee_id = v_current_user))
            ) THEN
                RETURN jsonb_build_object('status', 'invitee_not_allowed');
            END IF;

            IF EXISTS (
                SELECT 1 FROM public.users
                WHERE id = v_invitee AND minigame_invite_friends_only = true
            ) AND NOT EXISTS (
                SELECT 1 FROM public.friendships
                WHERE status = 'accepted'::public.friendship_status
                  AND ((requester_id = v_current_user AND addressee_id = v_invitee)
                    OR (requester_id = v_invitee AND addressee_id = v_current_user))
            ) THEN
                RETURN jsonb_build_object('status', 'invitee_friends_only');
            END IF;

            v_clean_invitees := v_clean_invitees || v_invitee;
        END LOOP;
    END IF;

    -- 6. Player-cap gate (direct-minigames 2026-08-27).
    IF (1 + COALESCE(array_length(v_clean_invitees, 1), 0)) > v_player_limit THEN
        RETURN jsonb_build_object('status', 'player_limit_reached');
    END IF;

    -- 6b. Partida name (160_minigame_names): trimmed copy.
    v_name := NULLIF(btrim(p_name), '');

    -- 6c. Auto partida name (170_minigame_invite_badges).
    v_auto_name := 'partida-' || (
        SELECT count(*) + 1
        FROM public.minigame_sessions
        WHERE game_type = v_game_type AND status = 'active'
    );

    -- 7. Wager escrow (unchanged from the baseline 3-arg contract).
    IF p_wager > 0 THEN
        UPDATE public.users
        SET personal_shards = personal_shards - p_wager
        WHERE id = v_current_user AND personal_shards >= p_wager;

        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'insufficient_shards');
        END IF;
    END IF;

    -- 8. Session insert (initiator first participant; frozen player_limit,
    --    name, auto_name, round target + prize choice ride the row).
    INSERT INTO public.minigame_sessions
        (group_id, game_type, status, shard_wager, player_limit, participants, name, auto_name, round_target, prize_positions)
    VALUES
        (p_group_id, v_game_type, 'active', p_wager, v_player_limit,
         ARRAY[v_current_user], v_name, v_auto_name, v_rounds, v_prize_positions)
    RETURNING id INTO v_session_id;

    -- 9. Ledger entry with the session reference (escrow verifiability).
    IF p_wager > 0 THEN
        INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
        VALUES (v_current_user, -p_wager, 'minigame_wager', v_session_id);
    END IF;

    -- 9b. Seed the game-state row in the same transaction (191) with the
    --     round target + prize choice pre-loaded into the payload so the
    --     lobby and play screens read them from the row.
    INSERT INTO public.minigame_game_state (session_id, game_type, state, ready)
    VALUES (v_session_id, v_game_type,
            jsonb_build_object(
                'round', 0,
                'round_target', v_rounds,
                'prize_positions', v_prize_positions,
                'reactions', '{}'::jsonb
            ),
            '{}'::jsonb);

    -- 10. Invite rows (one pending row per invitee; the notify trigger on
    --    minigame_invites dispatches the realtime notification).
    IF array_length(v_clean_invitees, 1) > 0 THEN
        FOREACH v_invitee IN ARRAY v_clean_invitees
        LOOP
            INSERT INTO public.minigame_invites (session_id, invitee_id, created_by)
            VALUES (v_session_id, v_invitee, v_current_user);
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'status', 'created',
        'sessionId', v_session_id,
        'invited', COALESCE(array_length(v_clean_invitees, 1), 0)
    );
END;
$$;

-- ======================================================================
-- 5. submit_minigame_reaction(uuid, text)
-- The realtime voting write: the caller's ONE emoji vote for the CURRENT
-- round (one vote per voter per round — re-voting replaces, never appends).
-- The vote is persisted to minigame_reactions AND mirrored into
-- state.reactions ({subject_id: [emoji,...]}) so every participant sees the
-- live tally on the existing minigame_game_state realtime channel.
-- ======================================================================
CREATE FUNCTION public.submit_minigame_reaction(p_session_id uuid, p_reaction text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_round integer;
    v_subject_id uuid;
    v_phase text;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (serialize vote vs advance/finish).
    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate — participant-only on the WRITE path (security
    --    hardening 2026-08-31: invitees / inactive group members can render
    --    the lobby but never cast votes).
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle gate: votes only while the session is active.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. The game must be playing with a current subject to vote on.
    SELECT m.state ->> 'phase',
           COALESCE((m.state ->> 'round')::integer, 0),
           (m.state ->> 'subject_id')::uuid
        INTO v_phase, v_round, v_subject_id
        FROM public.minigame_game_state m
        WHERE m.session_id = p_session_id;
    IF v_phase IS NULL OR v_phase <> 'playing' OR v_subject_id IS NULL THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    -- 6. Reaction validation against the six emoji keys.
    IF p_reaction NOT IN ('disgust', 'sad', 'surprised', 'excited', 'demon', 'heart') THEN
        RETURN jsonb_build_object('status', 'invalid_reaction');
    END IF;

    -- 7. Persist the vote (idempotent upsert — re-voting replaces, one vote
    --    per voter per round).
    INSERT INTO public.minigame_reactions (session_id, round, voter_id, reaction)
    VALUES (p_session_id, v_round, auth.uid(), p_reaction)
    ON CONFLICT (session_id, round, voter_id) DO UPDATE
        SET reaction = EXCLUDED.reaction;

    -- 8. Mirror into the state payload (realtime): the round's single
    --    subject -> the ordered vote list, rebuilt from the table so a
    --    re-vote replaces cleanly. The UPDATE streams live.
    UPDATE public.minigame_game_state
    SET state = jsonb_set(
            state,
            '{reactions}',
            COALESCE((
                SELECT jsonb_build_object(
                    v_subject_id::text,
                    (SELECT jsonb_agg(r.reaction ORDER BY r.created_at)
                     FROM public.minigame_reactions r
                     WHERE r.session_id = p_session_id AND r.round = v_round)
                )
            ), '{}'::jsonb),
            true
        )
    WHERE session_id = p_session_id;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'submitted', 'state', v_row);
END;
$$;

-- ======================================================================
-- 6. advance_minigame_turn(uuid, jsonb) — CREATE OR REPLACE (190 signature
--    kept). 201 additions: the completed round record gains the server-side
--    SCORE (reaction count, or -1 for a zero-vote subject), the reaction
--    payload resets for the next turn, and when the new round reaches
--    round_target the game AUTO-FINISHES via finish_minigame_game (the
--    authoritative leaderboard settlement) instead of advancing.
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
    v_round_target integer;
    v_subject_id uuid;
    v_reaction_count integer;
    v_score integer;
    v_round_json jsonb;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (serialize concurrent turn advances).
    SELECT group_id, status, participants, round_target
        INTO v_group_id, v_status, v_participants, v_round_target
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
                  AND gm.status = 'active'
                  AND NOT EXISTS (
                        SELECT 1 FROM public.users u
                        WHERE u.id = gm.user_id AND u.deleted_at IS NOT NULL
                    )
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
    v_subject_id := (v_state ->> 'subject_id')::uuid;

    -- 6b. 201: score the completed round — the number of reactions the
    --     subject received this round, or -1 when they got ZERO (the no-
    --     reactions penalty). p_round (client-shaped) stays, but the
    --     authoritative score is computed server-side.
    SELECT count(*) INTO v_reaction_count
    FROM public.minigame_reactions
    WHERE session_id = p_session_id AND round = v_round;
    v_score := CASE WHEN v_reaction_count > 0 THEN v_reaction_count ELSE -1 END;
    v_round_json := COALESCE(p_round, '{}'::jsonb) || jsonb_build_object('score', v_score);

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

    -- 8. Append the scored round, reset the reactions payload and rotate the
    --    skeleton; clear the prompt fields and persist the fresh
    --    next_subject_id for the following turn.
    UPDATE public.minigame_game_state
    SET rounds = rounds || ARRAY[v_round_json],
        state = v_state
                - 'subject_id' - 'next_subject_id' - 'prompt_type' - 'prompt'
                - 'reactions'
                || jsonb_build_object(
                       'judge_index', v_next_judge,
                       'round', v_round + 1,
                       'phase', 'playing',
                       'subject_id', v_participants[v_random_index],
                       'next_subject_id', v_participants[v_next_index],
                       'reactions', '{}'::jsonb
                   )
    WHERE session_id = p_session_id;

    -- 9. 201 AUTO-FINISH: once the round counter reaches the frozen target
    --    the game ends and the leaderboard settles (finish_minigame_game),
    --    replacing the manual host X for target-bound sessions.
    IF v_round_target IS NOT NULL AND v_round + 1 >= v_round_target THEN
        RETURN public.finish_minigame_game(p_session_id);
    END IF;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'advanced', 'state', v_row);
END;
$$;

-- ======================================================================
-- 7. finish_minigame_game(uuid)
-- The single settlement seam REPLACING finish_minigame_session (winner-takes-
-- all) and complete_minigame_game (draw-only). Server-authoritative:
--   * Computes the scoreboard from the append-only rounds history (summed
--     per participant; a participant with no rounds scores 0).
--   * Ranks by score DESC (participant-array order tie-break for
--     determinism) and pays HARMONIC prizes: N = prize_positions (capped at
--     the participant count), share_rank = (1/rank) / Σ(1/i) — computed in
--     exact integer arithmetic (LCM weights + largest-remainder) so the paid
--     sum is ALWAYS exactly the pot.
--   * Pot = wager x participant count. Free games (wager 0) write results
--     with zero prizes.
--   * Pays every prize into users.personal_shards with a shard_ledger
--     minigame_win row, writes minigame_results (the leaderboard the client
--     renders) and flips state.phase + session status to finished.
--     Idempotent (already_finished).
-- ======================================================================
CREATE FUNCTION public.finish_minigame_game(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_wager integer;
    v_prize_positions integer;
    v_rounds jsonb[];
    v_pot integer;
    v_prize_rows jsonb;
    v_row jsonb;
    v_result jsonb;
    v_prize integer;
    v_other_prizes integer;
    v_player_count integer;
    v_lcm integer;
    v_denom integer;
    v_r integer;
    v_weights jsonb;
    v_base jsonb;
    v_remaining integer;
    v_rank integer;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (serialize against concurrent finishes).
    SELECT group_id, status, participants, shard_wager, prize_positions
        INTO v_group_id, v_status, v_participants, v_wager, v_prize_positions
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
                  AND gm.status = 'active'
                  AND NOT EXISTS (
                        SELECT 1 FROM public.users u
                        WHERE u.id = gm.user_id AND u.deleted_at IS NOT NULL
                    )
            )
        ) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle gate: only active sessions settle (idempotent no-op on
    --    repeat — the escrow must never be paid twice).
    IF v_status <> 'active' THEN
        SELECT to_jsonb(m) INTO v_row
        FROM public.minigame_game_state m
        WHERE m.session_id = p_session_id;
        IF v_row IS NULL THEN
            RETURN jsonb_build_object('status', 'already_finished');
        END IF;
        RETURN jsonb_build_object('status', 'finished', 'state', v_row);
    END IF;

    -- 5. Load the round history (the scoreboard source of truth).
    SELECT rounds INTO v_rounds
    FROM public.minigame_game_state
    WHERE session_id = p_session_id;
    IF v_rounds IS NULL THEN
        v_rounds := '{}'::jsonb[];
    END IF;

    v_player_count := COALESCE(array_length(v_participants, 1), 0);
    v_pot := v_wager * v_player_count;
    -- N paid places, never more than there are players.
    v_prize_positions := LEAST(COALESCE(v_prize_positions, 3), v_player_count);

    -- 6. HARMONIC prize weights (1/rank, N positions) in EXACT integer
    --    arithmetic: weight_rank = lcm/rank, lcm = lcm(1..N). The sum of the
    --    normalized weights is the denominator; each rank's base prize is
    --    floor(pot * weight_rank / denom), and the LARGEST-REMAINDER method
    --    distributes the leftover shards to the highest ranks so the paid sum
    --    is ALWAYS exactly the pot — never a shard more or less.
    v_lcm := 1;
    FOR v_r IN 1..v_prize_positions LOOP
        v_lcm := v_lcm / gcd(v_lcm, v_r) * v_r;
    END LOOP;

    v_weights := jsonb_agg(wt) FROM (
        SELECT jsonb_build_object('rank', g.r, 'weight', v_lcm / g.r) AS wt
        FROM generate_series(1, v_prize_positions) AS g(r)
    ) q;
    v_denom := (SELECT sum((wt ->> 'weight')::int) FROM jsonb_array_elements(v_weights) wt);

    -- 6b. Ranked scoreboard (score DESC, participant-order tie-break).
    SELECT jsonb_agg(ranked ORDER BY (ranked ->> 'rank')::int)
    INTO v_prize_rows
    FROM (
        SELECT jsonb_build_object(
                   'participant_id', sc.participant_id,
                   'score', sc.score,
                   'rank', sc.rank
               ) AS ranked
        FROM (
            SELECT s.participant_id,
                   COALESCE(sum(r.value), 0) AS score,
                   row_number() OVER (
                       ORDER BY COALESCE(sum(r.value), 0) DESC, s.ord
                   ) AS rank
            FROM unnest(v_participants) WITH ORDINALITY AS s(participant_id, ord)
            LEFT JOIN LATERAL (
                SELECT (rr ->> 'score')::int AS value
                FROM unnest(v_rounds) rr
                WHERE (rr ->> 'subject_id')::uuid = s.participant_id
            ) r ON true
            GROUP BY s.participant_id, s.ord
        ) sc
        WHERE sc.rank <= v_prize_positions
    ) ranked_rows;

    IF v_prize_rows IS NULL THEN
        v_prize_rows := '[]'::jsonb;
    END IF;

    -- 6c. Compute the base prize per rank (floor), then the remainder.
    v_base := (
        SELECT jsonb_agg(jsonb_build_object(
                   'rank', r.rank,
                   'prize', CASE WHEN v_pot = 0 THEN 0
                                 ELSE (v_pot * (w ->> 'weight')::int) / v_denom END
               ) ORDER BY r.rank)
        FROM (
            SELECT (v ->> 'rank')::int AS rank
            FROM jsonb_array_elements(v_prize_rows) v
        ) r
        JOIN jsonb_array_elements(v_weights) w ON (w ->> 'rank')::int = r.rank
    );

    IF v_pot > 0 THEN
        v_remaining := v_pot - (SELECT sum((b ->> 'prize')::int) FROM jsonb_array_elements(v_base) b);

        -- 6d. Distribute the remainder to the top ranks (largest fractional
        --     part first — approximated by rank order, 1 unit each).
        FOR v_r IN 1..v_remaining LOOP
            v_base := (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'rank', (b ->> 'rank')::int,
                        'prize', CASE
                            WHEN (b ->> 'rank')::int = v_r THEN (b ->> 'prize')::int + 1
                            ELSE (b ->> 'prize')::int
                        END
                    )
                    ORDER BY (b ->> 'rank')::int
                )
                FROM jsonb_array_elements(v_base) b
            );
        END LOOP;
    END IF;

    -- 7. Pay the pot. Free games (v_pot = 0) pay nothing but still write the
    --    leaderboard.
    IF v_pot > 0 THEN
        FOR v_result IN SELECT * FROM jsonb_array_elements(v_prize_rows)
        LOOP
            v_rank := (v_result ->> 'rank')::int;
            SELECT (b ->> 'prize')::int INTO v_prize
            FROM jsonb_array_elements(v_base) b
            WHERE (b ->> 'rank')::int = v_rank;
            IF v_prize IS NULL OR v_prize <= 0 THEN
                CONTINUE;
            END IF;

            UPDATE public.users
            SET personal_shards = personal_shards + v_prize
            WHERE id = (v_result ->> 'participant_id')::uuid;

            INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
            VALUES ((v_result ->> 'participant_id')::uuid, v_prize,
                    'minigame_win', p_session_id);
        END LOOP;
    END IF;

    -- 9. Write the settle-once leaderboard (prize = 0 for free games).
    INSERT INTO public.minigame_results (session_id, results)
    SELECT p_session_id, jsonb_agg(jsonb_build_object(
               'participant_id', v ->> 'participant_id',
               'score', (v ->> 'score')::int,
               'rank', (v ->> 'rank')::int,
               'prize', CASE
                   WHEN v_pot = 0 THEN 0
                   ELSE COALESCE((SELECT (b ->> 'prize')::int
                                  FROM jsonb_array_elements(v_base) b
                                  WHERE (b ->> 'rank')::int = (v ->> 'rank')::int), 0)
               END
           ) ORDER BY (v ->> 'rank')::int)
    FROM jsonb_array_elements(v_prize_rows) v;

    -- 10. Flip the game phase + session status to finished.
    UPDATE public.minigame_game_state
    SET state = state || jsonb_build_object('phase', 'finished')
    WHERE session_id = p_session_id;

    UPDATE public.minigame_sessions
    SET status = 'finished'
    WHERE id = p_session_id;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'finished', 'state', v_row);
END;
$$;

-- ======================================================================
-- Realtime: the reactions + results tables join supabase_realtime so votes
-- (reactions) and the settled leaderboard (results) stream live.
-- Guarded — never fights make supabase-init.
-- ======================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_reactions') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.minigame_reactions;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_results') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.minigame_results;
  END IF;
END
$$;

-- ======================================================================
-- ACLs — hardened posture (no PUBLIC, authenticated/service only, clients
-- never write the reactions/results tables directly).
-- ======================================================================
REVOKE ALL ON FUNCTION public.submit_minigame_reaction(p_session_id uuid, p_reaction text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_minigame_reaction(p_session_id uuid, p_reaction text) TO authenticated;
GRANT ALL ON FUNCTION public.submit_minigame_reaction(p_session_id uuid, p_reaction text) TO service_role;

REVOKE ALL ON FUNCTION public.finish_minigame_game(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finish_minigame_game(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.finish_minigame_game(p_session_id uuid) TO service_role;

-- The 7-arg create keeps the hardened ACL posture (mirror of 140/160/170/191).
REVOKE ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text, p_rounds integer, p_prize_positions integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text, p_rounds integer, p_prize_positions integer) TO authenticated;
GRANT ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text, p_rounds integer, p_prize_positions integer) TO service_role;

REVOKE ALL ON TABLE public.minigame_reactions FROM anon;
REVOKE ALL ON TABLE public.minigame_reactions FROM authenticated;
GRANT SELECT ON TABLE public.minigame_reactions TO authenticated;
GRANT ALL ON TABLE public.minigame_reactions TO service_role;

REVOKE ALL ON TABLE public.minigame_results FROM anon;
REVOKE ALL ON TABLE public.minigame_results FROM authenticated;
GRANT SELECT ON TABLE public.minigame_results TO authenticated;
GRANT ALL ON TABLE public.minigame_results TO service_role;
