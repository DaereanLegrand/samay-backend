-- Samay — 207_minigame_reaction_event/reaction_event.sql
-- Per-tap reaction EVENT on the game-state payload (2026-09-03 user directive).
--
-- The problem: a same-emoji RE-TAP replaces the voter's row in place
-- (ON CONFLICT DO UPDATE keeps created_at), so the realtime `state.reactions`
-- mirror is byte-identical to the previous tap — clients that diff the mirror
-- cannot tell "reacted the same emoji again" from "nothing", so a per-tap
-- animation on every device cannot fire.
--
-- Model (no new tables, no new RPC signatures, no ACL changes):
--   * state.reactions_seq  bigint — monotonic per-session reaction-write
--     counter, bumped by 1 on EVERY reaction write (including a same-emoji
--     re-tap). NEVER reset on round advance (the counter is session-global so
--     ordering stays unambiguous); a round change is signalled by the event's
--     own `round` field, not by the counter.
--   * state.reactions_event jsonb — the LAST reaction event
--     {"seq": N, "round": R, "reaction": "<emoji wire>", "voter_id": "<uuid>"}.
--     Persisted in the SAME UPDATE that rewrites the `reactions` mirror, so the
--     seq, the tapped emoji and the voter ship atomically on the one realtime
--     row every device already receives. `reaction` stays NULL for a reactor
--     Pasar ('pasar' → NULL reaction, 204); the client renders no rise for a
--     pass.
--
-- Both reaction write RPCs (submit_minigame_reaction for the current by_turns
-- round, react_minigame_round for an async reactable round) get the identical
-- treatment. The counter + event are stored INSIDE state so they stream to
-- every participant on the existing minigame_game_state realtime UPDATE — no
-- new channel, no new subscription.
--
-- The counter is computed INLINE from the OLD row snapshot inside the mirror
-- UPDATE (Postgres evaluates the whole RHS against the pre-UPDATE value, so
-- the seq baked into `reactions_seq` and into `reactions_event.seq` is the
-- SAME +1 even though it appears in two nested jsonb_set calls). No extra
-- SELECT for the counter — the RPC bodies keep their exact 204 behavior apart
-- from the additions below.
--
-- Emoji ↔ Pasar exclusivity (2026-09-04 user directive): a voter who has
-- already emoji-reacted can no longer Pasar and a voter who has already
-- PASSED can no longer emoji-react — the server rejects the cross-mode switch
-- (already_reacted / already_passed). Emoji → emoji re-votes remain allowed.
-- The mirror also carries a per-voter `voters` map (voter_id → emoji wire, or
-- json null for a pass) inside `state.reactions.<subject>`, so every client
-- greys out the OTHER mode on its own deck once it has acted.
--
-- Posture mirrors 204: CREATE OR REPLACE of the existing signatures, SECURITY
-- DEFINER, search_path='', no privilege changes.

-- ======================================================================
-- 1. submit_minigame_reaction(uuid, text) — CREATE OR REPLACE (201 sig)
-- 207 addition: bumps state.reactions_seq and records state.reactions_event
-- alongside the existing reactions mirror (one atomic UPDATE).
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
    v_existing text;
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

    -- 6b. Emoji ↔ Pasar exclusivity (2026-09-04 user directive): a voter who
    --    has already emoji-reacted cannot switch to Pasar (already_reacted),
    --    and a voter who has already PASSED cannot switch to an emoji
    --    (already_passed). Emoji → emoji re-votes stay allowed (the upsert
    --    replaces); a repeated same-mode tap is an idempotent upsert.
    SELECT reaction INTO v_existing
    FROM public.minigame_reactions
    WHERE session_id = p_session_id AND round = v_round AND voter_id = auth.uid();
    IF p_reaction = 'pasar' THEN
        IF v_existing IS NOT NULL THEN
            RETURN jsonb_build_object('status', 'already_reacted');
        END IF;
    ELSE
        IF v_existing IS NULL THEN
            RETURN jsonb_build_object('status', 'already_passed');
        END IF;
    END IF;

    -- 7. Persist the vote (idempotent upsert). A 'pasar' stores NULL
    --    reaction — the pass marker — so one (session, round, voter) row
    --    holds exactly one action (emoji or pass).
    INSERT INTO public.minigame_reactions (session_id, round, voter_id, reaction)
    VALUES (p_session_id, v_round, auth.uid(), NULLIF(p_reaction, 'pasar'))
    ON CONFLICT (session_id, round, voter_id) DO UPDATE
        SET reaction = EXCLUDED.reaction;

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
-- 2. react_minigame_round(uuid, integer, text) — CREATE OR REPLACE (202 sig)
-- 207 addition: the async reactable-round path bumps reactions_seq + records
-- reactions_event + mirrors the per-voter `voters` map exactly like
-- submit_minigame_reaction, and enforces the same emoji ↔ Pasar exclusivity.
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
    v_existing text;
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

    -- 6b. Emoji ↔ Pasar exclusivity (2026-09-04 user directive) — the same
    --    contract as submit_minigame_reaction on the async path: a voter who
    --    already emoji-reacted cannot Pasar (already_reacted) and a voter who
    --    already passed cannot emoji-react (already_passed).
    SELECT reaction INTO v_existing
    FROM public.minigame_reactions
    WHERE session_id = p_session_id AND round = p_round AND voter_id = auth.uid();
    IF p_reaction = 'pasar' THEN
        IF v_existing IS NOT NULL THEN
            RETURN jsonb_build_object('status', 'already_reacted');
        END IF;
    ELSE
        IF v_existing IS NULL THEN
            RETURN jsonb_build_object('status', 'already_passed');
        END IF;
    END IF;

    -- 7. Persist the vote. A 'pasar' stores NULL — the pass marker.
    INSERT INTO public.minigame_reactions (session_id, round, voter_id, reaction)
    VALUES (p_session_id, p_round, auth.uid(), NULLIF(p_reaction, 'pasar'))
    ON CONFLICT (session_id, round, voter_id) DO UPDATE
        SET reaction = EXCLUDED.reaction;

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
