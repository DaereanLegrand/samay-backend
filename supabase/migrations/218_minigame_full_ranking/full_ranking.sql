-- ======================================================================
-- 218_minigame_full_ranking — full ranking in the settle-once leaderboard
-- (2026-09-20).
--
-- The finished-match player list must show a rank for EVERY participant and
-- the amount each won. The 204 settle filtered the ranked set to the paid
-- positions (WHERE sc.rank <= prize_positions), so minigame_results only
-- carried the top N players: everyone else had no rank on the client.
--
-- This replaces finish_minigame_game(uuid) (204 sig, unchanged) with the same
-- body minus those two filters: v_prize_rows now holds ALL participants with
-- their row_number() rank (and real score). The harmonic split is untouched —
-- v_base joins v_prize_rows to the rank weights (1..N), so prizes remain
-- exactly the pot and every rank > N writes prize 0 via the existing COALESCE.
-- ACLs are preserved by CREATE OR REPLACE (204 re-issued none).
-- ======================================================================
CREATE OR REPLACE FUNCTION public.finish_minigame_game(p_session_id uuid) RETURNS jsonb
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
    v_state jsonb;
    v_play_mode text;
    v_pot integer;
    v_prize_rows jsonb;
    v_row jsonb;
    v_result jsonb;
    v_prize integer;
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

    -- 2. Session lookup + row lock.
    SELECT group_id, status, participants, shard_wager, prize_positions
        INTO v_group_id, v_status, v_participants, v_wager, v_prize_positions
        FROM public.minigame_sessions
        WHERE id = p_session_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate.
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

    -- 4. Lifecycle gate (idempotent no-op on repeat).
    IF v_status <> 'active' THEN
        SELECT to_jsonb(m) INTO v_row
        FROM public.minigame_game_state m
        WHERE m.session_id = p_session_id;
        IF v_row IS NULL THEN
            RETURN jsonb_build_object('status', 'already_finished');
        END IF;
        RETURN jsonb_build_object('status', 'finished', 'state', v_row);
    END IF;

    v_player_count := COALESCE(array_length(v_participants, 1), 0);
    v_pot := v_wager * v_player_count;
    v_prize_positions := LEAST(COALESCE(v_prize_positions, 3), v_player_count);

    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    v_play_mode := COALESCE(v_state ->> 'play_mode', 'by_turns');

    -- 5. Scoreboard source of truth: by_turns = rounds history (fractional
    --    scores allowed since 204); async = per-round emoji_count -
    --    pass_count/2 summed across the player's rounds, -1 per passed round.
    IF v_play_mode = 'async' THEN
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
                       CASE WHEN COALESCE(SUM(CASE
                           WHEN (a.passed) THEN -1
                           ELSE (SELECT count(*) FROM public.minigame_reactions r
                                 WHERE r.session_id = p_session_id
                                   AND r.round = a.round
                                   AND r.reaction IS NOT NULL)
                                  - (SELECT count(*) FROM public.minigame_reactions r
                                     WHERE r.session_id = p_session_id
                                       AND r.round = a.round
                                       AND r.reaction IS NULL)::numeric / 2
                       END), 0) = trunc(COALESCE(SUM(CASE
                           WHEN (a.passed) THEN -1
                           ELSE (SELECT count(*) FROM public.minigame_reactions r
                                 WHERE r.session_id = p_session_id
                                   AND r.round = a.round
                                   AND r.reaction IS NOT NULL)
                                  - (SELECT count(*) FROM public.minigame_reactions r
                                     WHERE r.session_id = p_session_id
                                       AND r.round = a.round
                                       AND r.reaction IS NULL)::numeric / 2
                       END), 0))
                            THEN COALESCE(SUM(CASE
                           WHEN (a.passed) THEN -1
                           ELSE (SELECT count(*) FROM public.minigame_reactions r
                                 WHERE r.session_id = p_session_id
                                   AND r.round = a.round
                                   AND r.reaction IS NOT NULL)
                                  - (SELECT count(*) FROM public.minigame_reactions r
                                     WHERE r.session_id = p_session_id
                                       AND r.round = a.round
                                       AND r.reaction IS NULL)::numeric / 2
                       END), 0)::bigint
                            ELSE round(COALESCE(SUM(CASE
                           WHEN (a.passed) THEN -1
                           ELSE (SELECT count(*) FROM public.minigame_reactions r
                                 WHERE r.session_id = p_session_id
                                   AND r.round = a.round
                                   AND r.reaction IS NOT NULL)
                                  - (SELECT count(*) FROM public.minigame_reactions r
                                     WHERE r.session_id = p_session_id
                                       AND r.round = a.round
                                       AND r.reaction IS NULL)::numeric / 2
                       END), 0), 1) END AS score,
                       row_number() OVER (
                           ORDER BY COALESCE(SUM(CASE
                               WHEN (a.passed) THEN -1
                               ELSE (SELECT count(*) FROM public.minigame_reactions r
                                     WHERE r.session_id = p_session_id
                                       AND r.round = a.round
                                       AND r.reaction IS NOT NULL)
                                      - (SELECT count(*) FROM public.minigame_reactions r
                                         WHERE r.session_id = p_session_id
                                           AND r.round = a.round
                                           AND r.reaction IS NULL)::numeric / 2
                               END), 0) DESC, s.ord
                       ) AS rank
                FROM unnest(v_participants) WITH ORDINALITY AS s(participant_id, ord)
                LEFT JOIN LATERAL (
                    SELECT a.passed, a.round
                    FROM public.minigame_answers a
                    WHERE a.session_id = p_session_id
                      AND a.subject_id = s.participant_id
                ) a ON true
                GROUP BY s.participant_id, s.ord
            ) sc
        ) ranked_rows;
    ELSE
        SELECT rounds INTO v_rounds
        FROM public.minigame_game_state
        WHERE session_id = p_session_id;
        IF v_rounds IS NULL THEN
            v_rounds := '{}'::jsonb[];
        END IF;

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
                       CASE WHEN COALESCE(sum(r.value), 0) = trunc(COALESCE(sum(r.value), 0))
                            THEN COALESCE(sum(r.value), 0)::bigint
                            ELSE round(COALESCE(sum(r.value), 0), 1) END AS score,
                       row_number() OVER (
                           ORDER BY COALESCE(sum(r.value), 0) DESC, s.ord
                       ) AS rank
                FROM unnest(v_participants) WITH ORDINALITY AS s(participant_id, ord)
                LEFT JOIN LATERAL (
                    SELECT (rr ->> 'score')::numeric AS value
                    FROM unnest(v_rounds) rr
                    WHERE (rr ->> 'subject_id')::uuid = s.participant_id
                ) r ON true
                GROUP BY s.participant_id, s.ord
            ) sc
        ) ranked_rows;
    END IF;

    IF v_prize_rows IS NULL THEN
        v_prize_rows := '[]'::jsonb;
    END IF;

    -- 6. HARMONIC prize weights (201, unchanged — integer-exact split).
    v_lcm := 1;
    FOR v_r IN 1..v_prize_positions LOOP
        v_lcm := v_lcm / gcd(v_lcm, v_r) * v_r;
    END LOOP;

    v_weights := jsonb_agg(wt) FROM (
        SELECT jsonb_build_object('rank', g.r, 'weight', v_lcm / g.r) AS wt
        FROM generate_series(1, v_prize_positions) AS g(r)
    ) q;
    v_denom := (SELECT sum((wt ->> 'weight')::int) FROM jsonb_array_elements(v_weights) wt);

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

    -- 7. Pay the pot.
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

    -- 8. Write the settle-once leaderboard.
    INSERT INTO public.minigame_results (session_id, results)
    SELECT p_session_id, jsonb_agg(jsonb_build_object(
               'participant_id', v ->> 'participant_id',
               'score', (v ->> 'score')::numeric,
               'rank', (v ->> 'rank')::int,
               'prize', CASE
                   WHEN v_pot = 0 THEN 0
                   ELSE COALESCE((SELECT (b ->> 'prize')::int
                                  FROM jsonb_array_elements(v_base) b
                                  WHERE (b ->> 'rank')::int = (v ->> 'rank')::int), 0)
               END
           ) ORDER BY (v ->> 'rank')::int)
    FROM jsonb_array_elements(v_prize_rows) v;

    -- 9. Flip the game phase + session status to finished.
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
