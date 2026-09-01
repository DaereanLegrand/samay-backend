-- Samay — 204_minigame_pasar/vote_pass.sql
-- Reactor-side "Pasar" on the reaction deck (2026-09-01 user directive).
--
-- Product contract:
--   * A NON-subject participant who has the current round open to reactions
--     (or an async reactable round) may tap Pasar INSTEAD of an emoji.
--   * The passer is counted as "reacted" for the by_turns all-reacted
--     auto-advance gate (a round closes once every non-subject has either
--     emoji-reacted or passed).
--   * The round's SUBJECT scores: +1 per emoji, minus 0.5 per passer
--     (stacking; exact halves only, so any combination lands on a .5 or
--     integer). A round with ZERO emojis still scores -1 (the no-reactions
--     penalty keeps its precedence over an all-pass round's 0).
--   * The reaction mirror (state.reactions) gains a `pass` count alongside
--     the existing `list` + `count`, so the live tally streams passers too.
--   * The existing SUBJECT-side skip (submit_minigame_pasar, -1) is a
--     DIFFERENT action and is untouched.
--
-- Model: `'pasar'` rides the two existing write RPCs (submit_minigame_reaction
-- for the current by_turns round, react_minigame_round for async reactable
-- rounds). minigame_reactions.reaction becomes NULLABLE — NULL is the pass
-- marker (a CHECK keeps the six emoji values or NULL), so the PK
-- (session, round, voter) still guarantees one action per voter per round.
-- Scoring:
--   * _minigame_advance_round (by_turns round record): emoji_count -
--     pass_count/2, -1 when the round had ZERO emojis, normalized to an
--     integer when integral (jsonb renders 2, not 2.0).
--   * finish_minigame_game (async settle): per round, emoji_count -
--     pass_count/2 for answered rounds and -1 per passed round, summed.
--
-- Posture mirrors 100/140/150/180/190/201/202: FORCE RLS, mutations through
-- SECURITY DEFINER RPCs only, PUBLIC EXECUTE revoked, authenticated +
-- service_role. No new tables, no new RPC signatures, no ACL changes.

-- ======================================================================
-- 1. minigame_reactions: reaction is NULLable (NULL = reactor Pasar)
-- ======================================================================
ALTER TABLE public.minigame_reactions
    ALTER COLUMN reaction DROP NOT NULL;

-- The only legal values: one of the six emojis, or NULL (the pass marker).
-- A passed reactor casts no emoji; the CHECK keeps the wire contract tight.
ALTER TABLE public.minigame_reactions
    ADD CONSTRAINT mgs_reaction_value_check CHECK (
        reaction IS NULL
        OR reaction IN ('disgust', 'sad', 'surprised', 'excited', 'demon', 'heart')
    );

COMMENT ON COLUMN public.minigame_reactions.reaction IS
    '204_minigame_pasar: the reactor emoji, or NULL when the reactor PASSED (the reactor-side Pasar). NULL is the pass marker; the subject scores -0.5 per passer.';

-- ======================================================================
-- 2. submit_minigame_reaction(uuid, text) — CREATE OR REPLACE (201 sig)
-- 204 additions: `p_reaction='pasar'` upserts a NULL-reaction row (the pass
-- marker); the mirror carries a `pass` count; the by_turns auto-advance gate
-- counts passers as reacted (the round closes once every non-subject has
-- emoji-reacted or passed).
-- ======================================================================
CREATE OR REPLACE FUNCTION public.submit_minigame_reaction(p_session_id uuid, p_reaction text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_state jsonb;
    v_phase text;
    v_round integer;
    v_subject_id uuid;
    v_answer jsonb;
    v_reacted_count integer;
    v_required_count integer;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock.
    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate — participant-only on the WRITE path (security
    --    hardening 2026-08-31: invitees / inactive group members can render
    --    the lobby but never vote).
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle + playing gate.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_state IS NULL OR v_state ->> 'phase' <> 'playing' THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    -- 5. Current round + subject (server-authoritative).
    v_round := COALESCE((v_state ->> 'round')::integer, 0);
    v_subject_id := (v_state ->> 'subject_id')::uuid;
    IF v_subject_id IS NULL THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    -- 5b. The SUBJECT can never react to their own round (202 contract).
    IF v_subject_id = auth.uid() THEN
        RETURN jsonb_build_object('status', 'own_round');
    END IF;

    -- 5c. Reactions open ONLY after the subject answered (202 answer-first).
    SELECT to_jsonb(a) INTO v_answer
    FROM public.minigame_answers a
    WHERE a.session_id = p_session_id AND a.round = v_round;
    IF v_answer IS NULL OR v_answer ->> 'passed' = 'true' THEN
        RETURN jsonb_build_object('status', 'answer_pending');
    END IF;

    -- 6. Reaction validation — the six emoji keys OR the reactor Pasar
    --    ('pasar', 204).
    IF p_reaction NOT IN ('disgust', 'sad', 'surprised', 'excited', 'demon', 'heart', 'pasar') THEN
        RETURN jsonb_build_object('status', 'invalid_reaction');
    END IF;

    -- 7. Persist the vote (idempotent upsert). A 'pasar' stores NULL
    --    reaction — the pass marker — so one (session, round, voter) row
    --    holds exactly one action (emoji or pass).
    INSERT INTO public.minigame_reactions (session_id, round, voter_id, reaction)
    VALUES (p_session_id, v_round, auth.uid(), NULLIF(p_reaction, 'pasar'))
    ON CONFLICT (session_id, round, voter_id) DO UPDATE
        SET reaction = EXCLUDED.reaction;

    -- 8. Mirror into the state payload (realtime). The mirror carries the
    --    ordered emoji list, the distinct-voter count (emoji OR pass) and
    --    the `pass` count ({subject_id: {"list": [...], "count": N,
    --    "pass": P}}) so clients render the live tally without re-querying.
    UPDATE public.minigame_game_state
    SET state = jsonb_set(
            state,
            '{reactions}',
            COALESCE((
                SELECT jsonb_build_object(
                    v_subject_id::text,
                    jsonb_build_object(
                        'list',
                        (SELECT COALESCE(jsonb_agg(r.reaction ORDER BY r.created_at), '[]'::jsonb)
                         FROM public.minigame_reactions r
                         WHERE r.session_id = p_session_id AND r.round = v_round
                           AND r.reaction IS NOT NULL),
                        'count',
                        (SELECT count(distinct r.voter_id)
                         FROM public.minigame_reactions r
                         WHERE r.session_id = p_session_id AND r.round = v_round),
                        'pass',
                        (SELECT count(*)
                         FROM public.minigame_reactions r
                         WHERE r.session_id = p_session_id AND r.round = v_round
                           AND r.reaction IS NULL)
                    )
                )
            ), '{}'::jsonb),
            true
        )
    WHERE session_id = p_session_id;

    -- 9. by_turns auto-advance: when every NON-subject participant has
    --    reacted OR passed, the round closes and the next turn begins.
    --    Idempotent — already-advanced rounds reject.
    IF COALESCE(v_state ->> 'play_mode', 'by_turns') = 'by_turns' THEN
        SELECT count(distinct voter_id) INTO v_reacted_count
        FROM public.minigame_reactions
        WHERE session_id = p_session_id AND round = v_round;
        v_required_count := COALESCE(array_length(v_participants, 1), 1) - 1;
        IF v_reacted_count >= v_required_count THEN
            RETURN public._minigame_advance_round(p_session_id);
        END IF;
    END IF;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'submitted', 'state', v_row);
END;
$$;

-- ======================================================================
-- 3. react_minigame_round(uuid, integer, text) — CREATE OR REPLACE (202 sig)
-- 204 addition: `p_reaction='pasar'` targets a completed reactable round
-- (async) the same way — NULL-reaction pass row + `pass` mirror count.
-- ======================================================================
CREATE OR REPLACE FUNCTION public.react_minigame_round(p_session_id uuid, p_round integer, p_reaction text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_answer jsonb;
    v_subject_id uuid;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + lock.
    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate — participant-only on the WRITE path (security
    --    hardening 2026-08-31: invitees / inactive group members can render
    --    the lobby but never vote).
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. The target round must have a completed (non-passed) answer.
    SELECT to_jsonb(a) INTO v_answer
    FROM public.minigame_answers a
    WHERE a.session_id = p_session_id AND a.round = p_round;
    IF v_answer IS NULL OR v_answer ->> 'passed' = 'true' THEN
        RETURN jsonb_build_object('status', 'answer_pending');
    END IF;
    v_subject_id := (v_answer ->> 'subject_id')::uuid;

    -- 5b. The subject of the round can never react to it (202 contract).
    IF v_subject_id = auth.uid() THEN
        RETURN jsonb_build_object('status', 'own_round');
    END IF;

    -- 6. Reaction validation — the six emoji keys OR the reactor Pasar
    --    ('pasar', 204).
    IF p_reaction NOT IN ('disgust', 'sad', 'surprised', 'excited', 'demon', 'heart', 'pasar') THEN
        RETURN jsonb_build_object('status', 'invalid_reaction');
    END IF;

    -- 7. Persist the vote. A 'pasar' stores NULL — the pass marker.
    INSERT INTO public.minigame_reactions (session_id, round, voter_id, reaction)
    VALUES (p_session_id, p_round, auth.uid(), NULLIF(p_reaction, 'pasar'))
    ON CONFLICT (session_id, round, voter_id) DO UPDATE
        SET reaction = EXCLUDED.reaction;

    -- 8. Mirror into the state payload (realtime) under the round's subject.
    --    The mirror carries the ordered emoji list, the distinct-voter count
    --    and the `pass` count (204).
    UPDATE public.minigame_game_state
    SET state = jsonb_set(
            state,
            '{reactions}',
            COALESCE((
                SELECT jsonb_build_object(
                    v_subject_id::text,
                    jsonb_build_object(
                        'list',
                        (SELECT COALESCE(jsonb_agg(r.reaction ORDER BY r.created_at), '[]'::jsonb)
                         FROM public.minigame_reactions r
                         WHERE r.session_id = p_session_id AND r.round = p_round
                           AND r.reaction IS NOT NULL),
                        'count',
                        (SELECT count(distinct r.voter_id)
                         FROM public.minigame_reactions r
                         WHERE r.session_id = p_session_id AND r.round = p_round),
                        'pass',
                        (SELECT count(*)
                         FROM public.minigame_reactions r
                         WHERE r.session_id = p_session_id AND r.round = p_round
                           AND r.reaction IS NULL)
                    )
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
-- 4. _minigame_advance_round(uuid) — CREATE OR REPLACE (202 sig)
-- 204 scoring: emoji_count - pass_count/2 for the round record (-1 when the
-- round had ZERO emojis, keeping the no-reactions penalty over an all-pass
-- round's 0). Scores normalize to an integer when integral so jsonb renders
-- 2 (not 2.0); fractional scores keep one decimal (0.5 / 2.5 ...).
-- ======================================================================
CREATE OR REPLACE FUNCTION public._minigame_advance_round(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
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
    v_pass_count integer;
    v_score numeric;
    v_passed boolean;
    v_round_json jsonb;
    v_row jsonb;
BEGIN
    SELECT status, participants INTO v_status, v_participants
    FROM public.minigame_sessions
    WHERE id = p_session_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_state IS NULL THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    v_phase := v_state ->> 'phase';
    IF v_phase <> 'playing' THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    v_player_count := COALESCE(array_length(v_participants, 1), 0);
    IF v_player_count = 0 THEN
        RETURN jsonb_build_object('status', 'no_participants');
    END IF;

    v_judge_index := COALESCE((v_state ->> 'judge_index')::integer, 0);
    v_round := COALESCE((v_state ->> 'round')::integer, 0);
    v_subject_id := (v_state ->> 'subject_id')::uuid;
    v_round_target := COALESCE((v_state ->> 'round_target')::integer, NULL);

    -- Score (204): emoji_count - pass_count/2. A passed round / a round with
    -- ZERO emojis scores -1 (the no-reactions penalty keeps its precedence
    -- over an all-pass round's 0). Normalized so integral values render as
    -- integers in jsonb (2, not 2.0) while fractional scores keep one decimal.
    SELECT passed INTO v_passed
    FROM public.minigame_answers
    WHERE session_id = p_session_id AND round = v_round;
    v_passed := COALESCE(v_passed, false);

    SELECT count(*) FILTER (WHERE reaction IS NOT NULL),
           count(*) FILTER (WHERE reaction IS NULL)
        INTO v_reaction_count, v_pass_count
    FROM public.minigame_reactions
    WHERE session_id = p_session_id AND round = v_round;

    IF v_passed OR v_reaction_count = 0 THEN
        v_score := -1;
    ELSE
        v_score := v_reaction_count::numeric - v_pass_count::numeric / 2;
    END IF;
    IF v_score = trunc(v_score) THEN
        v_score := v_score::bigint;
    ELSE
        v_score := round(v_score, 1);
    END IF;

    v_round_json := jsonb_build_object(
        'subject_id', v_subject_id,
        'round', v_round,
        'score', v_score,
        'outcome', CASE WHEN v_passed THEN 'skip' ELSE 'done' END
    ) || CASE WHEN (v_state ->> 'prompt_type') IS NOT NULL
              THEN jsonb_build_object('prompt_type', v_state ->> 'prompt_type')
              ELSE '{}'::jsonb END;

    -- Rotate judge + redraw random subject + following subject.
    v_next_judge := (v_judge_index + 1) % v_player_count;
    v_random_index := 1 + floor(random() * v_player_count)::integer;
    IF v_player_count = 1 THEN
        v_next_index := v_random_index;
    ELSE
        v_next_index := 1 + floor(random() * (v_player_count - 1))::integer;
        IF v_next_index >= v_random_index THEN
            v_next_index := v_next_index + 1;
        END IF;
    END IF;

    UPDATE public.minigame_game_state
    SET rounds = rounds || ARRAY[v_round_json],
        state = v_state
                - 'subject_id' - 'next_subject_id' - 'prompt_type' - 'prompt'
                - 'reactions' - 'answer'
                || jsonb_build_object(
                       'judge_index', v_next_judge,
                       'round', v_round + 1,
                       'phase', 'playing',
                       'subject_id', v_participants[v_random_index],
                       'next_subject_id', v_participants[v_next_index],
                       'reactions', '{}'::jsonb
                   )
    WHERE session_id = p_session_id;

    -- Auto-finish at the total-turn target (201).
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
-- 5. finish_minigame_game(uuid) — CREATE OR REPLACE (202 sig)
-- 204 scoring: async settlement uses per-round emoji_count - pass_count/2
-- (and -1 per passed round); the by_turns path reads fractional round scores
-- (was ::int). Scores keep one decimal / integer normalization in results.
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
            WHERE sc.rank <= v_prize_positions
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
            WHERE sc.rank <= v_prize_positions
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
