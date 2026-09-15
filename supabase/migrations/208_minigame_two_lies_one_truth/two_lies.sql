-- Samay — 208_minigame_two_lies_one_truth/two_lies.sql
-- Two Lies, One Truth (2 mentiras, 1 verdad) minigame integration.
--
-- Extends the reusable minigame play engine (150/201/202/204) on top of the
-- 207 reaction-event base (kept verbatim — seq/event, exclusivity, spam
-- gate, voters mirror):
--   1. Adds 'two_lies_one_truth' to the public.mini_game_type enum.
--   2. Extends mgs_reaction_value_check on minigame_reactions to allow
--      vote options ('vote_0', 'vote_1', 'vote_2') alongside the six emojis.
--   3. Re-applies submit_minigame_reaction / react_minigame_round with
--      'vote_0..2' in the valid-reaction list. Votes are emoji-mode actions
--      (non-NULL rows): the 207 cross-mode exclusivity, spam gate, event and
--      mirror cover them with no special-casing — a vote→vote change is a
--      same-mode re-vote (upsert replaces).
--   4. Seeds inspirational topic prompts into public.minigame_prompts for
--      'two_lies_one_truth'.
--
-- Posture: SECURITY DEFINER, search_path='', no privilege changes.

-- ======================================================================
-- 1. mini_game_type enum extension
-- ======================================================================
ALTER TYPE public.mini_game_type ADD VALUE IF NOT EXISTS 'two_lies_one_truth';

-- ======================================================================
-- 2. minigame_reactions: allow vote_0, vote_1, vote_2
-- ======================================================================
ALTER TABLE public.minigame_reactions
    DROP CONSTRAINT IF EXISTS mgs_reaction_value_check;

ALTER TABLE public.minigame_reactions
    ADD CONSTRAINT mgs_reaction_value_check CHECK (
        reaction IS NULL
        OR reaction IN (
            'disgust', 'sad', 'surprised', 'excited', 'demon', 'heart',
            'vote_0', 'vote_1', 'vote_2'
        )
    );

COMMENT ON COLUMN public.minigame_reactions.reaction IS
    '208_minigame_two_lies_one_truth: the reactor emoji, vote_0..2 for 2-mentiras-1-verdad, or NULL when the reactor PASSED.';

-- ======================================================================
-- 3. Additive (207 carry-over): per-(session, round, voter) time of the
--    last ACCEPTED reaction write. Drives the server controlled-spam gate;
--    NULL = none yet.
-- ======================================================================
ALTER TABLE public.minigame_reactions
    ADD COLUMN IF NOT EXISTS last_tap_at timestamp with time zone;

-- ======================================================================
-- 4. submit_minigame_reaction(uuid, text) — CREATE OR REPLACE (201 sig)
-- 208: the exact 207 body (seq/event + exclusivity + spam gate + voters
-- mirror) with 'vote_0..2' added to the valid-reaction list.
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
    v_last_tap timestamp with time zone;
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

    -- 6. Reaction validation — the six emoji keys, the reactor Pasar
    --    ('pasar', 204), or a Two-Lies vote ('vote_0..2', 208).
    IF p_reaction NOT IN ('disgust', 'sad', 'surprised', 'excited', 'demon', 'heart', 'pasar', 'vote_0', 'vote_1', 'vote_2') THEN
        RETURN jsonb_build_object('status', 'invalid_reaction');
    END IF;

    -- 6b. Emoji ↔ Pasar exclusivity (2026-09-09 fix). A Pasar row stores a
    --    NULL reaction (204), so "no row yet" and "already passed" are told
    --    apart by row EXISTENCE, never by the reaction value. A Pasar tap that
    --    finds an EMOJI row is a cross-mode switch (already_reacted); a
    --    re-pasar over an existing pass row is an idempotent no-op that stays
    --    allowed. An emoji tap that finds a PASS row (reaction IS NULL) is a
    --    cross-mode switch (already_passed). A fresh voter and an emoji voter
    --    tap freely — same-emoji re-taps and emoji → emoji re-votes stay
    --    allowed (the upsert replaces). Votes are emoji-mode actions, so the
    --    same rules cover vote taps with no special-casing.
    IF p_reaction = 'pasar' THEN
        IF EXISTS (
            SELECT 1 FROM public.minigame_reactions
            WHERE session_id = p_session_id AND round = v_round
              AND voter_id = auth.uid() AND reaction IS NOT NULL
        ) THEN
            RETURN jsonb_build_object('status', 'already_reacted');
        END IF;
    ELSE
        IF EXISTS (
            SELECT 1 FROM public.minigame_reactions
            WHERE session_id = p_session_id AND round = v_round
              AND voter_id = auth.uid() AND reaction IS NULL
        ) THEN
            RETURN jsonb_build_object('status', 'already_passed');
        END IF;
    END IF;

    -- 6c. Controlled-spam server threshold: at most ONE accepted reaction
    --    write per voter per round inside the 250 ms window (the client's tap
    --    timer is 350 ms, so a well-behaved device never trips this). No
    --    write, no seq bump, no event — the tapper's device already animated
    --    its own tap locally.
    SELECT last_tap_at INTO v_last_tap
    FROM public.minigame_reactions
    WHERE session_id = p_session_id AND round = v_round AND voter_id = auth.uid();
    IF v_last_tap IS NOT NULL
       AND clock_timestamp() - v_last_tap < interval '250 milliseconds' THEN
        RETURN jsonb_build_object('status', 'too_fast');
    END IF;

    -- 7. Persist the vote (idempotent upsert). A 'pasar' stores NULL
    --    reaction — the pass marker — so one (session, round, voter) row
    --    holds exactly one action (emoji or pass).
    INSERT INTO public.minigame_reactions (session_id, round, voter_id, reaction, last_tap_at)
    VALUES (p_session_id, v_round, auth.uid(), NULLIF(p_reaction, 'pasar'), clock_timestamp())
    ON CONFLICT (session_id, round, voter_id) DO UPDATE
        SET reaction = EXCLUDED.reaction,
            last_tap_at = clock_timestamp();

    -- 8. Mirror into the state payload (realtime): the ordered emoji list +
    --    distinct-voter count + `pass` count + the per-voter `voters` map +
    --    the per-tap event + the bumped sequence — ALL in one atomic UPDATE
    --    (one realtime emission). The event's `round` tells a client whether
    --    the event belongs to the window it is showing; a `reaction` of NULL
    --    is a Pasar (no rise); the `voters` map (voter_id → emoji wire, null
    --    for a pass) drives the client-side emoji ↔ Pasar exclusivity grey-out.
    UPDATE public.minigame_game_state
    SET state = jsonb_set(
            jsonb_set(
                jsonb_set(
                    state,
                    '{reactions_seq}',
                    to_jsonb((COALESCE((state ->> 'reactions_seq')::bigint, 0)) + 1)
                ),
                '{reactions_event}',
                jsonb_build_object(
                    'seq', (COALESCE((state ->> 'reactions_seq')::bigint, 0)) + 1,
                    'round', v_round,
                    'reaction', NULLIF(p_reaction, 'pasar'),
                    'voter_id', auth.uid()
                )
            ),
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
                           AND r.reaction IS NULL),
                        'voters',
                        COALESCE((
                            SELECT jsonb_object_agg(r.voter_id::text, r.reaction)
                            FROM public.minigame_reactions r
                            WHERE r.session_id = p_session_id AND r.round = v_round
                        ), '{}'::jsonb)
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
-- 5. react_minigame_round(uuid, integer, text) — CREATE OR REPLACE (202 sig)
-- 208: the exact 207 async path with 'vote_0..2' added to the
-- valid-reaction list (same emoji-mode semantics as above).
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
    v_last_tap timestamp with time zone;
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

    -- 6. Reaction validation — the six emoji keys, the reactor Pasar
    --    ('pasar', 204), or a Two-Lies vote ('vote_0..2', 208).
    IF p_reaction NOT IN ('disgust', 'sad', 'surprised', 'excited', 'demon', 'heart', 'pasar', 'vote_0', 'vote_1', 'vote_2') THEN
        RETURN jsonb_build_object('status', 'invalid_reaction');
    END IF;

    -- 6b. Emoji ↔ Pasar exclusivity (2026-09-09 fix) — the same corrected
    --    contract as submit_minigame_reaction on the async reactable-round
    --    path: a Pasar tap that finds an EMOJI row is already_reacted; an
    --    emoji tap that finds a PASS row (reaction IS NULL) is already_passed.
    --    A fresh voter and an emoji voter tap freely (same-emoji re-taps +
    --    emoji → emoji re-votes allowed). Votes are emoji-mode actions.
    IF p_reaction = 'pasar' THEN
        IF EXISTS (
            SELECT 1 FROM public.minigame_reactions
            WHERE session_id = p_session_id AND round = p_round
              AND voter_id = auth.uid() AND reaction IS NOT NULL
        ) THEN
            RETURN jsonb_build_object('status', 'already_reacted');
        END IF;
    ELSE
        IF EXISTS (
            SELECT 1 FROM public.minigame_reactions
            WHERE session_id = p_session_id AND round = p_round
              AND voter_id = auth.uid() AND reaction IS NULL
        ) THEN
            RETURN jsonb_build_object('status', 'already_passed');
        END IF;
    END IF;

    -- 6c. Controlled-spam server threshold (same contract as the by_turns
    --    path): one accepted reaction write per voter per round inside 250 ms.
    SELECT last_tap_at INTO v_last_tap
    FROM public.minigame_reactions
    WHERE session_id = p_session_id AND round = p_round AND voter_id = auth.uid();
    IF v_last_tap IS NOT NULL
       AND clock_timestamp() - v_last_tap < interval '250 milliseconds' THEN
        RETURN jsonb_build_object('status', 'too_fast');
    END IF;

    -- 7. Persist the vote. A 'pasar' stores NULL — the pass marker.
    INSERT INTO public.minigame_reactions (session_id, round, voter_id, reaction, last_tap_at)
    VALUES (p_session_id, p_round, auth.uid(), NULLIF(p_reaction, 'pasar'), clock_timestamp())
    ON CONFLICT (session_id, round, voter_id) DO UPDATE
        SET reaction = EXCLUDED.reaction,
            last_tap_at = clock_timestamp();

    -- 8. Mirror into the state payload (realtime): the reactions tally under
    --    the round's subject (incl. the per-voter action map) + the per-tap
    --    event + the bumped sequence — one atomic UPDATE (one realtime
    --    emission).
    UPDATE public.minigame_game_state
    SET state = jsonb_set(
            jsonb_set(
                jsonb_set(
                    state,
                    '{reactions_seq}',
                    to_jsonb((COALESCE((state ->> 'reactions_seq')::bigint, 0)) + 1)
                ),
                '{reactions_event}',
                jsonb_build_object(
                    'seq', (COALESCE((state ->> 'reactions_seq')::bigint, 0)) + 1,
                    'round', p_round,
                    'reaction', NULLIF(p_reaction, 'pasar'),
                    'voter_id', auth.uid()
                )
            ),
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
                           AND r.reaction IS NULL),
                        'voters',
                        COALESCE((
                            SELECT jsonb_object_agg(r.voter_id::text, r.reaction)
                            FROM public.minigame_reactions r
                            WHERE r.session_id = p_session_id AND r.round = p_round
                        ), '{}'::jsonb)
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
-- 6. Seed topic prompts for two_lies_one_truth
-- ======================================================================
INSERT INTO public.minigame_prompts (id, game_type, prompt_type, category, body, is_active) VALUES
    ('c0000000-0000-4000-8000-000000000001', 'two_lies_one_truth', 'topic', 'anecdotas', 'Una anécdota de fiesta o salida nocturna', true),
    ('c0000000-0000-4000-8000-000000000002', 'two_lies_one_truth', 'topic', 'viajes',    'Algo insólito que te ocurrió viajando', true),
    ('c0000000-0000-4000-8000-000000000003', 'two_lies_one_truth', 'topic', 'citas',     'Una cita desastrosa o inesperada', true),
    ('c0000000-0000-4000-8000-000000000004', 'two_lies_one_truth', 'topic', 'secretos',  'Un talento o habilidad secreta que nadie conoce', true),
    ('c0000000-0000-4000-8000-000000000005', 'two_lies_one_truth', 'topic', 'verguenza', 'El mayor oso o vergüenza de tu vida', true),
    ('c0000000-0000-4000-8000-000000000006', 'two_lies_one_truth', 'topic', 'infancia',  'Una travesura de tu infancia que nunca confesaste', true)
ON CONFLICT (id) DO NOTHING;
