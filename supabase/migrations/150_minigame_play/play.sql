-- Samay — 150_minigame_play/play.sql
-- Reusable minigame play engine (Verdad o Reto first consumer).
--
-- The SAME table + RPC family powers all 5 game types (poke_chain,
-- questions, truth_dare, drunk_bottle, challenge): game-specific logic
-- lives in the jsonb `state` payload, never in bespoke tables per game.
--
-- Model:
--   * minigame_game_state — one row per minigame session. `state` holds
--     the game-agnostic turn skeleton (judge_index, round, phase) plus
--     game-specific keys (e.g. subject_id / prompt_type / prompt for
--     truth_dare). `rounds` is the append-only round history. The
--     `minigame_game_state_touch` trigger keeps updated_at fresh.
--   * minigame_prompts — the generic prompt bank (game_type +
--     prompt_type + category + body), seeded es-first for truth_dare.
--   * The RPC family: get (read state), init (start + random first
--     subject), reveal (random prompt of a validated prompt_type), advance
--     (round-robin judge rotation + RANDOM next subject), complete (flip
--     phase + settle the wager as a draw). Server-random subject selection
--     is the product requirement — players do NOT self-select.
--   * RLS posture mirrors the minigame foundation: FORCE RLS, no client
--     table writes, every mutation through SECURITY DEFINER RPCs. The
--     game-state row is readable EXACTLY when the session row is readable
--     (participant / invitee / group member). Prompts are readable by
--     authenticated users only while active.

-- Name: minigame_game_state; Type: TABLE; Schema: public; Owner: -
CREATE TABLE public.minigame_game_state (
    session_id uuid NOT NULL,
    -- Denormalized convenience — the session already carries it.
    game_type public.mini_game_type NOT NULL,
    -- Game-agnostic turn skeleton + game-specific payload:
    --   {"judge_index":0,"round":0,"phase":"playing",
    --    "subject_id":<uuid>,"prompt_type":"verdad","prompt":<prompt row>}
    state jsonb DEFAULT '{}'::jsonb NOT NULL,
    -- Append-only round history (one jsonb object per completed round).
    rounds jsonb[] DEFAULT '{}'::jsonb[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.minigame_game_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE ONLY public.minigame_game_state FORCE ROW LEVEL SECURITY;

-- Name: minigame_game_state minigame_game_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
ALTER TABLE ONLY public.minigame_game_state
    ADD CONSTRAINT minigame_game_state_pkey PRIMARY KEY (session_id);

ALTER TABLE ONLY public.minigame_game_state
    ADD CONSTRAINT minigame_game_state_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.minigame_sessions(id) ON DELETE CASCADE;

-- ======================================================================
-- minigame_game_state_touch()
-- Keeps updated_at fresh on every UPDATE (mirror of the baseline
-- moddatetime pattern; the 100_minigames session table has no updated_at,
-- so this touch trigger is the play-engine-local stamp).
-- ======================================================================
CREATE FUNCTION public.minigame_game_state_touch() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER minigame_game_state_touch BEFORE UPDATE ON public.minigame_game_state
    FOR EACH ROW EXECUTE FUNCTION public.minigame_game_state_touch();

-- ======================================================================
-- mgs_read_participant — the game-state row is readable EXACTLY when the
-- session row is readable: direct-session participant, invitee, or group
-- member (semantic union of ms_read_direct_participant + ms_read_invitee +
-- ms_read_group_member). No INSERT/UPDATE/DELETE policies — the RPC family
-- owns every write (FORCE RLS).
-- ======================================================================
CREATE POLICY mgs_read_participant ON public.minigame_game_state FOR SELECT USING (
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

-- Name: minigame_prompts; Type: TABLE; Schema: public; Owner: -
CREATE TABLE public.minigame_prompts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    game_type public.mini_game_type NOT NULL,
    -- truth_dare: 'verdad' | 'reto'; other games may use 'quick',
    -- 'challenge', etc.
    prompt_type text NOT NULL,
    -- 'amor' (primer beso / primer amor / inicial), 'foto'/'reto' for
    -- photo challenges, 'general' is the default.
    category text DEFAULT 'general' NOT NULL,
    body text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.minigame_prompts ENABLE ROW LEVEL SECURITY;
ALTER TABLE ONLY public.minigame_prompts FORCE ROW LEVEL SECURITY;

-- Name: minigame_prompts minigame_prompts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
ALTER TABLE ONLY public.minigame_prompts
    ADD CONSTRAINT minigame_prompts_pkey PRIMARY KEY (id);

-- ======================================================================
-- mgs_prompts_select — authenticated users read active prompts only
-- (the reveal RPC re-gates the SELECT explicitly; this policy covers the
-- direct PostgREST reads used by any future prompt-browser UI).
-- ======================================================================
CREATE POLICY mgs_prompts_select ON public.minigame_prompts FOR SELECT USING (
    (is_active = true)
);

-- ======================================================================
-- Seed the prompt bank (es-first locale, matching the app). Deterministic
-- ids + ON CONFLICT (id) DO NOTHING make re-runs idempotent.
-- ======================================================================
INSERT INTO public.minigame_prompts (id, game_type, prompt_type, category, body, is_active) VALUES
    ('b0000000-0000-4000-8000-000000000001', 'truth_dare', 'verdad', 'amor',    '¿Cuál fue tu primer beso?', true),
    ('b0000000-0000-4000-8000-000000000002', 'truth_dare', 'verdad', 'amor',    '¿Quién fue tu primer amor?', true),
    ('b0000000-0000-4000-8000-000000000003', 'truth_dare', 'verdad', 'amor',    'Di la inicial de quien te gusta', true),
    ('b0000000-0000-4000-8000-000000000004', 'truth_dare', 'verdad', 'general', '¿Cuál es tu mayor vergüenza?', true),
    ('b0000000-0000-4000-8000-000000000005', 'truth_dare', 'verdad', 'general', '¿Qué es lo más raro que has comido?', true),
    ('b0000000-0000-4000-8000-000000000006', 'truth_dare', 'verdad', 'general', '¿Cuál es tu peor cita?', true),
    ('b0000000-0000-4000-8000-000000000007', 'truth_dare', 'reto',   'foto',    'Envía una foto de tu perro', true),
    ('b0000000-0000-4000-8000-000000000008', 'truth_dare', 'reto',   'foto',    'Hazte una selfie con un objeto', true),
    ('b0000000-0000-4000-8000-000000000009', 'truth_dare', 'reto',   'general', 'Haz un challenge', true),
    ('b0000000-0000-4000-8000-00000000000a', 'truth_dare', 'reto',   'general', 'Cuenta un chiste en voz alta', true),
    ('b0000000-0000-4000-8000-00000000000b', 'truth_dare', 'reto',   'general', 'Canta una canción durante 10 segundos', true)
ON CONFLICT (id) DO NOTHING;

-- ======================================================================
-- get_minigame_game_state(uuid)
-- Reads the game-state row (if any) for a session the caller may see.
-- Returns {'status':'ok','state':<row>} or {'status':'not_started'} when
-- the session has no game-state row yet. Gates: auth, session exists,
-- caller is participant / invitee / group member.
-- ======================================================================
CREATE FUNCTION public.get_minigame_game_state(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_row jsonb;
    v_group_id uuid;
    v_participants uuid[];
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup (no lock — read-only).
    SELECT group_id, participants
        INTO v_group_id, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate (participant / invitee / group member — mirrors
    --    mgs_read_participant; SECURITY DEFINER would otherwise bypass RLS).
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

    -- 4. Read the state row (game-specific payload rides state jsonb).
    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_row IS NULL THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    RETURN jsonb_build_object('status', 'ok', 'state', v_row);
END;
$$;

-- ======================================================================
-- init_minigame_game_state(uuid)
-- Starts the play engine for an active session. Idempotent: an existing
-- game-state row returns already_started (with the existing state). The
-- FIRST SUBJECT is picked RANDOMLY from the participants — the product
-- requirement (players do NOT self-select). state seeds the generic
-- skeleton (judge_index=0, round=0, phase='playing') + the random
-- subject_id; prompt_type/prompt start NULL.
-- ======================================================================
CREATE FUNCTION public.init_minigame_game_state(p_session_id uuid) RETURNS jsonb
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

    -- 3. Access gate — a NON-participant may never initialize the game.
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

    -- 4. Lifecycle gate: only active sessions start a play engine.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. Idempotency: an existing game-state row is a no-op.
    SELECT to_jsonb(m) INTO v_existing
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_existing IS NOT NULL THEN
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

    -- 7. Insert the row (game_type denormalized from the session).
    INSERT INTO public.minigame_game_state (session_id, game_type, state)
    VALUES (p_session_id, v_game_type, v_state);

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'started', 'state', v_row);
END;
$$;

-- ======================================================================
-- reveal_minigame_prompt(uuid, text)
-- Draws a RANDOM active prompt of the requested prompt_type for the
-- session's game type and persists it into state (prompt_type + prompt
-- row). p_prompt_type must be a valid type for the session's game_type in
-- minigame_prompts, else invalid_prompt_type. The prompt read is a
-- separate table — SECURITY DEFINER bypasses RLS, so the active-prompt
-- gate is explicit (is_active = true).
-- ======================================================================
CREATE FUNCTION public.reveal_minigame_prompt(p_session_id uuid, p_prompt_type text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_game_type public.mini_game_type;
    v_prompt jsonb;
    v_state jsonb;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock.
    SELECT group_id, status, participants, game_type
        INTO v_group_id, v_status, v_participants, v_game_type
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

    -- 5. prompt_type validation against the bank for THIS game type.
    IF NOT EXISTS (
        SELECT 1 FROM public.minigame_prompts
        WHERE game_type = v_game_type AND prompt_type = p_prompt_type
    ) THEN
        RETURN jsonb_build_object('status', 'invalid_prompt_type');
    END IF;

    -- 6. Random draw of one active prompt (server-random).
    SELECT to_jsonb(p) INTO v_prompt
    FROM public.minigame_prompts p
    WHERE p.game_type = v_game_type
      AND p.prompt_type = p_prompt_type
      AND p.is_active = true
    ORDER BY random()
    LIMIT 1;
    IF v_prompt IS NULL THEN
        RETURN jsonb_build_object('status', 'no_prompts_available');
    END IF;

    -- 7. Persist prompt_type + prompt (the prompt row) into the payload.
    UPDATE public.minigame_game_state
    SET state = state || jsonb_build_object('prompt_type', p_prompt_type, 'prompt', v_prompt)
    WHERE session_id = p_session_id;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object(
        'status', 'revealed',
        'prompt_type', p_prompt_type,
        'prompt', v_prompt,
        'state', v_row
    );
END;
$$;

-- ======================================================================
-- advance_minigame_turn(uuid, jsonb)
-- Closes the current turn: appends the completed round to `rounds`
-- (e.g. {"subject_id":..,"prompt_type":"verdad","prompt_id":..,"outcome":"go"}),
-- advances judge_index round-robin to the NEXT participant (skipping
-- nobody), picks the new subject_id RANDOMLY (server-random — players do
-- NOT self-select), bumps round, clears prompt_type/prompt, keeps
-- phase='playing'.
-- ======================================================================
CREATE FUNCTION public.advance_minigame_turn(p_session_id uuid, p_round jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_state jsonb;
    v_judge_index integer;
    v_round integer;
    v_player_count integer;
    v_next_judge integer;
    v_random_index integer;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (serialize concurrent turn advances).
    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
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

    -- 6. Round-robin judge rotation (generic across all 5 games).
    v_player_count := COALESCE(array_length(v_participants, 1), 0);
    IF v_player_count = 0 THEN
        RETURN jsonb_build_object('status', 'no_participants');
    END IF;
    v_judge_index := COALESCE((v_state ->> 'judge_index')::integer, 0);
    v_next_judge := (v_judge_index + 1) % v_player_count;
    v_round := COALESCE((v_state ->> 'round')::integer, 0);

    -- 7. Random next subject (server-random — players never self-select).
    v_random_index := 1 + floor(random() * v_player_count)::integer;

    -- 8. Append the completed round + rotate the skeleton; clear the
    --    prompt fields for the next turn.
    UPDATE public.minigame_game_state
    SET rounds = rounds || ARRAY[p_round],
        state = v_state
                - 'subject_id' - 'prompt_type' - 'prompt'
                || jsonb_build_object(
                       'judge_index', v_next_judge,
                       'round', v_round + 1,
                       'phase', 'playing',
                       'subject_id', v_participants[v_random_index]
                   )
    WHERE session_id = p_session_id;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'advanced', 'state', v_row);
END;
$$;

-- ======================================================================
-- complete_minigame_game(uuid)
-- Ends the party game: flips state.phase='finished' and settles the wager
-- exactly like finish_minigame_session with a NULL winner (draw → refund
-- every participant via shard_ledger minigame_refund), then flips
-- minigame_sessions.status='finished'. Party games have no winner — the
-- draw-refund path is the settlement. service_role keeps EXECUTE for
-- future admin settlement.
-- ======================================================================
CREATE FUNCTION public.complete_minigame_game(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_wager integer;
    v_participant uuid;
    v_state jsonb;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock (serialize against concurrent finishes).
    SELECT group_id, status, participants, shard_wager
        INTO v_group_id, v_status, v_participants, v_wager
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
        RETURN jsonb_build_object('status', 'already_finished');
    END IF;

    -- 5. Draw settlement (GWAG Wager Resolution, NULL-winner mirror of
    --    finish_minigame_session): refund every participant.
    IF v_wager > 0 THEN
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
    END IF;

    -- 6. Flip the game phase to finished.
    UPDATE public.minigame_game_state
    SET state = state || jsonb_build_object('phase', 'finished')
    WHERE session_id = p_session_id;

    -- 7. Flip the session status to finished.
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
-- Realtime: minigame_game_state joins supabase_realtime so state changes
-- (init / reveal / advance / complete) stream LIVE to every participant.
-- Guarded — never fights make supabase-init (mirror of 140_minigame_invites).
-- ======================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_game_state') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.minigame_game_state;
  END IF;
END
$$;

-- ======================================================================
-- ACLs — hardened posture (no PUBLIC, authenticated/service only, clients
-- never write the game-state or prompts tables directly).
-- ======================================================================
REVOKE ALL ON FUNCTION public.get_minigame_game_state(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_minigame_game_state(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_minigame_game_state(p_session_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.init_minigame_game_state(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.init_minigame_game_state(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.init_minigame_game_state(p_session_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.reveal_minigame_prompt(p_session_id uuid, p_prompt_type text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reveal_minigame_prompt(p_session_id uuid, p_prompt_type text) TO authenticated;
GRANT ALL ON FUNCTION public.reveal_minigame_prompt(p_session_id uuid, p_prompt_type text) TO service_role;

REVOKE ALL ON FUNCTION public.advance_minigame_turn(p_session_id uuid, p_round jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.advance_minigame_turn(p_session_id uuid, p_round jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.advance_minigame_turn(p_session_id uuid, p_round jsonb) TO service_role;

REVOKE ALL ON FUNCTION public.complete_minigame_game(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.complete_minigame_game(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.complete_minigame_game(p_session_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.minigame_game_state_touch() FROM PUBLIC;
GRANT ALL ON FUNCTION public.minigame_game_state_touch() TO service_role;

REVOKE ALL ON TABLE public.minigame_game_state FROM anon;
REVOKE ALL ON TABLE public.minigame_game_state FROM authenticated;
GRANT SELECT ON TABLE public.minigame_game_state TO authenticated;
GRANT ALL ON TABLE public.minigame_game_state TO service_role;

REVOKE ALL ON TABLE public.minigame_prompts FROM anon;
REVOKE ALL ON TABLE public.minigame_prompts FROM authenticated;
GRANT SELECT ON TABLE public.minigame_prompts TO authenticated;
GRANT ALL ON TABLE public.minigame_prompts TO service_role;
