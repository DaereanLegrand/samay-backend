-- ======================================================================
-- Charadas (212_minigame_charades) — step 2: word bank + turn engine.
--
-- The game everyone already knows: you hold the phone on your forehead, the
-- word shows to the room, they act it out, you guess. A turn is a countdown
-- with one word on screen at a time; "Acerté" scores it and draws the next,
-- "Paso" skips it. When the clock runs out the turn closes and the score
-- lands on the session's scoreboard.
--
-- Everything rides `minigame_game_state.state` on the existing realtime
-- channel, so the rest of the table watches the word, the timer and the
-- score live while one player plays.
--
-- The deadline is anchored to the SERVER clock (`charades_ends_at`), the
-- same posture the attendance code uses — a client with a skewed clock
-- cannot buy itself extra seconds.
-- ======================================================================

-- ----------------------------------------------------------------------
-- Word bank. Categories are the ones a group actually picks at a party;
-- every word is guessable by acting it out.
-- ----------------------------------------------------------------------
INSERT INTO public.minigame_prompts (game_type, prompt_type, category, body) VALUES
  ('charades', 'palabra', 'peliculas', 'Titanic'),
  ('charades', 'palabra', 'peliculas', 'El Rey León'),
  ('charades', 'palabra', 'peliculas', 'Rápido y Furioso'),
  ('charades', 'palabra', 'peliculas', 'Shrek'),
  ('charades', 'palabra', 'peliculas', 'Harry Potter'),
  ('charades', 'palabra', 'peliculas', 'Spider-Man'),
  ('charades', 'palabra', 'peliculas', 'Frozen'),
  ('charades', 'palabra', 'peliculas', 'Coco'),
  ('charades', 'palabra', 'peliculas', 'Toy Story'),
  ('charades', 'palabra', 'peliculas', 'Jurassic Park'),
  ('charades', 'palabra', 'peliculas', 'Piratas del Caribe'),
  ('charades', 'palabra', 'peliculas', 'Los Vengadores'),
  ('charades', 'palabra', 'animales', 'Elefante'),
  ('charades', 'palabra', 'animales', 'Pingüino'),
  ('charades', 'palabra', 'animales', 'Cocodrilo'),
  ('charades', 'palabra', 'animales', 'Jirafa'),
  ('charades', 'palabra', 'animales', 'Mono'),
  ('charades', 'palabra', 'animales', 'Gallina'),
  ('charades', 'palabra', 'animales', 'Pulpo'),
  ('charades', 'palabra', 'animales', 'Tiburón'),
  ('charades', 'palabra', 'animales', 'Murciélago'),
  ('charades', 'palabra', 'animales', 'Caballo'),
  ('charades', 'palabra', 'animales', 'Llama'),
  ('charades', 'palabra', 'animales', 'Abeja'),
  ('charades', 'palabra', 'acciones', 'Bailar salsa'),
  ('charades', 'palabra', 'acciones', 'Manejar bicicleta'),
  ('charades', 'palabra', 'acciones', 'Lavar los platos'),
  ('charades', 'palabra', 'acciones', 'Tomarse una selfie'),
  ('charades', 'palabra', 'acciones', 'Correr una maratón'),
  ('charades', 'palabra', 'acciones', 'Cocinar'),
  ('charades', 'palabra', 'acciones', 'Nadar'),
  ('charades', 'palabra', 'acciones', 'Cantar en karaoke'),
  ('charades', 'palabra', 'acciones', 'Planchar ropa'),
  ('charades', 'palabra', 'acciones', 'Sacar a pasear al perro'),
  ('charades', 'palabra', 'acciones', 'Estacionar el carro'),
  ('charades', 'palabra', 'acciones', 'Pedir un taxi'),
  ('charades', 'palabra', 'objetos', 'Paraguas'),
  ('charades', 'palabra', 'objetos', 'Licuadora'),
  ('charades', 'palabra', 'objetos', 'Guitarra'),
  ('charades', 'palabra', 'objetos', 'Escoba'),
  ('charades', 'palabra', 'objetos', 'Lentes de sol'),
  ('charades', 'palabra', 'objetos', 'Mochila'),
  ('charades', 'palabra', 'objetos', 'Ventilador'),
  ('charades', 'palabra', 'objetos', 'Control remoto'),
  ('charades', 'palabra', 'objetos', 'Audífonos'),
  ('charades', 'palabra', 'objetos', 'Cepillo de dientes'),
  ('charades', 'palabra', 'objetos', 'Cargador'),
  ('charades', 'palabra', 'objetos', 'Espejo'),
  ('charades', 'palabra', 'famosos', 'Shakira'),
  ('charades', 'palabra', 'famosos', 'Lionel Messi'),
  ('charades', 'palabra', 'famosos', 'Bad Bunny'),
  ('charades', 'palabra', 'famosos', 'Michael Jackson'),
  ('charades', 'palabra', 'famosos', 'Cristiano Ronaldo'),
  ('charades', 'palabra', 'famosos', 'Rosalía'),
  ('charades', 'palabra', 'famosos', 'Karol G'),
  ('charades', 'palabra', 'famosos', 'Chayanne'),
  ('charades', 'palabra', 'famosos', 'Mr. Bean'),
  ('charades', 'palabra', 'famosos', 'Chespirito'),
  ('charades', 'palabra', 'fiesta', 'Brindis'),
  ('charades', 'palabra', 'fiesta', 'Karaoke'),
  ('charades', 'palabra', 'fiesta', 'Pista de baile'),
  ('charades', 'palabra', 'fiesta', 'El DJ'),
  ('charades', 'palabra', 'fiesta', 'Piñata'),
  ('charades', 'palabra', 'fiesta', 'Confeti'),
  ('charades', 'palabra', 'fiesta', 'La resaca'),
  ('charades', 'palabra', 'fiesta', 'Selfie grupal'),
  ('charades', 'palabra', 'fiesta', 'Cumpleaños'),
  ('charades', 'palabra', 'fiesta', 'Bola de disco')
ON CONFLICT DO NOTHING;

-- ----------------------------------------------------------------------
-- _charades_guard(uuid) — the gate every charades RPC repeats: auth,
-- session exists, right game, caller is a participant, session active.
-- Returns NULL when the caller passes, or the typed rejection jsonb.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._charades_guard(p_session_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_status public.mini_game_status;
    v_participants uuid[];
    v_game_type public.mini_game_type;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT status, participants, game_type
        INTO v_status, v_participants, v_game_type
        FROM public.minigame_sessions
        WHERE id = p_session_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;
    IF v_game_type <> 'charades' THEN
        RETURN jsonb_build_object('status', 'wrong_game_type');
    END IF;
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;
    RETURN NULL;
END;
$$;

-- ----------------------------------------------------------------------
-- start_charades_turn(uuid, text, int) — the caller takes the turn.
-- Draws the first word of [p_category] and starts the server-clock timer.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.start_charades_turn(
    p_session_id uuid,
    p_category text DEFAULT NULL,
    p_seconds int DEFAULT 60
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_guard jsonb;
    v_word text;
    v_seconds int;
    v_ends_at timestamptz;
BEGIN
    v_guard := public._charades_guard(p_session_id);
    IF v_guard IS NOT NULL THEN RETURN v_guard; END IF;

    v_seconds := LEAST(GREATEST(COALESCE(p_seconds, 60), 20), 180);

    SELECT body INTO v_word
      FROM public.minigame_prompts
     WHERE game_type = 'charades' AND prompt_type = 'palabra' AND is_active
       AND (p_category IS NULL OR category = p_category)
     ORDER BY random() LIMIT 1;

    IF v_word IS NULL THEN
        RETURN jsonb_build_object('status', 'no_words');
    END IF;

    v_ends_at := now() + make_interval(secs => v_seconds);

    INSERT INTO public.minigame_game_state (session_id, game_type, state, ready)
    SELECT p_session_id, s.game_type,
           jsonb_build_object(
               'phase', 'playing',
               'charades_phase', 'playing',
               'charades_turn_id', to_jsonb(auth.uid()),
               'charades_word', to_jsonb(v_word),
               'charades_category', to_jsonb(p_category),
               'charades_ends_at', to_jsonb(v_ends_at),
               'charades_seconds', v_seconds,
               'charades_hits', 0,
               'charades_misses', 0,
               'charades_log', '[]'::jsonb,
               'charades_scores', '{}'::jsonb,
               'charades_seq', 1
           ),
           '{}'::jsonb
      FROM public.minigame_sessions AS s
     WHERE s.id = p_session_id
    ON CONFLICT (session_id) DO UPDATE
        SET state = minigame_game_state.state || jsonb_build_object(
                        'phase', 'playing',
                        'charades_phase', 'playing',
                        'charades_turn_id', to_jsonb(auth.uid()),
                        'charades_word', to_jsonb(v_word),
                        'charades_category', to_jsonb(p_category),
                        'charades_ends_at', to_jsonb(v_ends_at),
                        'charades_seconds', v_seconds,
                        'charades_hits', 0,
                        'charades_misses', 0,
                        'charades_log', '[]'::jsonb,
                        'charades_seq',
                        COALESCE((minigame_game_state.state->>'charades_seq')::int, 0) + 1
                    ),
            updated_at = now();

    RETURN jsonb_build_object(
        'status', 'ok',
        'word', v_word,
        'ends_at', v_ends_at,
        'server_now', now()
    );
END;
$$;

-- ----------------------------------------------------------------------
-- charades_answer(uuid, boolean) — score the word on screen and draw the
-- next one. Only the player holding the turn may call it, and only while
-- the server clock still has time on it.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.charades_answer(
    p_session_id uuid,
    p_correct boolean
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_guard jsonb;
    v_state jsonb;
    v_word text;
    v_category text;
    v_next text;
    v_ends_at timestamptz;
BEGIN
    v_guard := public._charades_guard(p_session_id);
    IF v_guard IS NOT NULL THEN RETURN v_guard; END IF;

    SELECT state INTO v_state
      FROM public.minigame_game_state WHERE session_id = p_session_id
      FOR UPDATE;
    IF v_state IS NULL OR COALESCE(v_state->>'charades_phase', '') <> 'playing' THEN
        RETURN jsonb_build_object('status', 'not_playing');
    END IF;
    IF (v_state->>'charades_turn_id')::uuid IS DISTINCT FROM auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_your_turn');
    END IF;

    v_ends_at := (v_state->>'charades_ends_at')::timestamptz;
    IF v_ends_at IS NOT NULL AND now() > v_ends_at THEN
        RETURN jsonb_build_object('status', 'time_up');
    END IF;

    v_word := v_state->>'charades_word';
    v_category := v_state->>'charades_category';

    SELECT body INTO v_next
      FROM public.minigame_prompts
     WHERE game_type = 'charades' AND prompt_type = 'palabra' AND is_active
       AND (v_category IS NULL OR category = v_category)
       AND body IS DISTINCT FROM v_word
     ORDER BY random() LIMIT 1;

    UPDATE public.minigame_game_state
       SET state = state || jsonb_build_object(
                       'charades_word', to_jsonb(COALESCE(v_next, v_word)),
                       'charades_hits',
                       COALESCE((state->>'charades_hits')::int, 0)
                           + CASE WHEN p_correct THEN 1 ELSE 0 END,
                       'charades_misses',
                       COALESCE((state->>'charades_misses')::int, 0)
                           + CASE WHEN p_correct THEN 0 ELSE 1 END,
                       'charades_log',
                       COALESCE(state->'charades_log', '[]'::jsonb)
                           || jsonb_build_array(jsonb_build_object(
                               'word', v_word, 'correct', p_correct)),
                       'charades_seq',
                       COALESCE((state->>'charades_seq')::int, 0) + 1
                   ),
           updated_at = now()
     WHERE session_id = p_session_id;

    RETURN jsonb_build_object('status', 'ok', 'word', COALESCE(v_next, v_word));
END;
$$;

-- ----------------------------------------------------------------------
-- end_charades_turn(uuid) — closes the turn (clock ran out, or the player
-- stopped early) and banks the hits onto the session scoreboard. Any
-- participant may close a turn whose clock already expired, so a player who
-- walked away never freezes the table.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.end_charades_turn(p_session_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_guard jsonb;
    v_state jsonb;
    v_turn uuid;
    v_hits int;
    v_ends_at timestamptz;
    v_scores jsonb;
BEGIN
    v_guard := public._charades_guard(p_session_id);
    IF v_guard IS NOT NULL THEN RETURN v_guard; END IF;

    SELECT state INTO v_state
      FROM public.minigame_game_state WHERE session_id = p_session_id
      FOR UPDATE;
    IF v_state IS NULL OR COALESCE(v_state->>'charades_phase', '') <> 'playing' THEN
        RETURN jsonb_build_object('status', 'not_playing');
    END IF;

    v_turn := (v_state->>'charades_turn_id')::uuid;
    v_ends_at := (v_state->>'charades_ends_at')::timestamptz;
    -- Only the turn holder may stop early; anyone may close an expired turn.
    IF v_turn IS DISTINCT FROM auth.uid()
       AND (v_ends_at IS NULL OR now() <= v_ends_at) THEN
        RETURN jsonb_build_object('status', 'not_your_turn');
    END IF;

    v_hits := COALESCE((v_state->>'charades_hits')::int, 0);
    v_scores := COALESCE(v_state->'charades_scores', '{}'::jsonb);
    v_scores := v_scores || jsonb_build_object(
        v_turn::text,
        COALESCE((v_scores->>v_turn::text)::int, 0) + v_hits
    );

    UPDATE public.minigame_game_state
       SET state = state || jsonb_build_object(
                       'charades_phase', 'summary',
                       'charades_scores', v_scores,
                       'charades_seq',
                       COALESCE((state->>'charades_seq')::int, 0) + 1
                   ),
           updated_at = now()
     WHERE session_id = p_session_id;

    RETURN jsonb_build_object('status', 'ok', 'hits', v_hits, 'scores', v_scores);
END;
$$;

REVOKE ALL ON FUNCTION public._charades_guard(uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public._charades_guard(uuid) TO authenticated;
GRANT ALL ON FUNCTION public._charades_guard(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.start_charades_turn(uuid, text, int) FROM PUBLIC;
GRANT ALL ON FUNCTION public.start_charades_turn(uuid, text, int) TO authenticated;
GRANT ALL ON FUNCTION public.start_charades_turn(uuid, text, int) TO service_role;

REVOKE ALL ON FUNCTION public.charades_answer(uuid, boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.charades_answer(uuid, boolean) TO authenticated;
GRANT ALL ON FUNCTION public.charades_answer(uuid, boolean) TO service_role;

REVOKE ALL ON FUNCTION public.end_charades_turn(uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.end_charades_turn(uuid) TO authenticated;
GRANT ALL ON FUNCTION public.end_charades_turn(uuid) TO service_role;
