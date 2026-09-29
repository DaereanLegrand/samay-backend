-- ======================================================================
-- Botella (drunk_bottle) v2 — "modo pizza" (210_minigame_bottle_pizza).
--
-- 208 let the CLIENT pick the winner and only synced the result, which
-- meant the bottle's drawn angle and the announced player were two
-- unrelated facts. Here the SERVER owns the whole draw:
--
--   * the roster is dealt onto a pizza — n equal sectors of 360/n degrees,
--     sector k belongs to seats[k] — so wherever the bottle lands it ALWAYS
--     lands inside exactly one player's slice (no "nobody" outcome),
--   * every spin RESEATS the players (fresh shuffle) so the same two people
--     are not neighbours all night,
--   * the stop draws a random angle, derives the winner from the sector that
--     angle falls into, and draws a random reto from minigame_prompts.
--
-- Every client renders the same pizza from `bottle_seats` and rotates to the
-- same `bottle_angle`, so the animation and the announced winner agree by
-- construction. All of it rides the state jsonb on the existing game-state
-- realtime channel (no new table, no new subscription).
-- ======================================================================

DROP FUNCTION IF EXISTS public.set_drunk_bottle_spin(uuid, boolean, uuid);

-- ----------------------------------------------------------------------
-- Reto bank for the bottle (mirrors the truth_dare rows already seeded in
-- minigame_prompts: game_type + prompt_type + category + body).
-- Tone: party game for friends — silly first, flirty at most, never cruel.
-- ----------------------------------------------------------------------
INSERT INTO public.minigame_prompts (game_type, prompt_type, category, body) VALUES
  ('drunk_bottle', 'reto', 'suave', 'Imita a alguien de la sala hasta que adivinen quién es.'),
  ('drunk_bottle', 'reto', 'suave', 'Cuenta un chiste. Si nadie se ríe, tomas.'),
  ('drunk_bottle', 'reto', 'suave', 'Habla con acento de otro país hasta tu próximo turno.'),
  ('drunk_bottle', 'reto', 'suave', 'Canta el coro de la última canción que escuchaste.'),
  ('drunk_bottle', 'reto', 'suave', 'Deja que la persona de tu derecha te despeine.'),
  ('drunk_bottle', 'reto', 'suave', 'Haz 10 sentadillas mientras el grupo cuenta en voz alta.'),
  ('drunk_bottle', 'reto', 'suave', 'Ponte de pie y haz tu mejor paso de baile por 15 segundos.'),
  ('drunk_bottle', 'reto', 'suave', 'Di el nombre completo de todos los que están aquí. Si fallas uno, tomas.'),
  ('drunk_bottle', 'reto', 'suave', 'Habla sin usar la letra "a" hasta que la botella gire otra vez.'),
  ('drunk_bottle', 'reto', 'suave', 'Imita el sonido de un animal y que el grupo adivine cuál es.'),
  ('drunk_bottle', 'reto', 'medio', 'Muestra la última foto de tu galería. Sin buscar, la última.'),
  ('drunk_bottle', 'reto', 'medio', 'Deja que el grupo revise tus últimas 3 canciones reproducidas.'),
  ('drunk_bottle', 'reto', 'medio', 'Llama a un contacto al azar y cántale feliz cumpleaños.'),
  ('drunk_bottle', 'reto', 'medio', 'Publica una historia con la cara que te pida el grupo.'),
  ('drunk_bottle', 'reto', 'medio', 'Deja que alguien escriba un mensaje desde tu cuenta. Tú eliges a quién se lo manda.'),
  ('drunk_bottle', 'reto', 'medio', 'Cuenta la anécdota más vergonzosa que te haya pasado este año.'),
  ('drunk_bottle', 'reto', 'medio', 'Deja que el grupo elija tu foto de perfil por las próximas 24 horas.'),
  ('drunk_bottle', 'reto', 'medio', 'Di en voz alta el último mensaje que enviaste.'),
  ('drunk_bottle', 'reto', 'medio', 'Imita a la persona que giró la botella hasta que se ría.'),
  ('drunk_bottle', 'reto', 'medio', 'Confiesa algo que nadie de esta sala sepa de ti.'),
  ('drunk_bottle', 'reto', 'picante', 'Dile un piropo a la persona de tu izquierda mirándola a los ojos.'),
  ('drunk_bottle', 'reto', 'picante', 'Elige a alguien de la sala y dile qué fue lo primero que pensaste cuando lo conociste.'),
  ('drunk_bottle', 'reto', 'picante', 'Manda un mensaje a tu último match diciendo "estaba pensando en ti".'),
  ('drunk_bottle', 'reto', 'picante', 'Dile a alguien de la sala algo que te guste de esa persona.'),
  ('drunk_bottle', 'reto', 'picante', 'Baila pegado con quien te señale el grupo por 20 segundos.'),
  ('drunk_bottle', 'reto', 'picante', 'Cuenta cuál fue tu peor cita y por qué salió tan mal.'),
  ('drunk_bottle', 'reto', 'picante', 'Deja que el grupo lea el nombre de tus últimos 3 chats.'),
  ('drunk_bottle', 'reto', 'picante', 'Dile a la persona de enfrente qué canción le pondrías si tuvieras que conquistarla.'),
  ('drunk_bottle', 'reto', 'castigo', 'Tomas. No hay reto, no hay salida.'),
  ('drunk_bottle', 'reto', 'castigo', 'Tú repartes: elige quién toma en esta ronda.'),
  ('drunk_bottle', 'reto', 'castigo', 'Todos toman menos tú. Disfrútalo.')
ON CONFLICT DO NOTHING;

-- ----------------------------------------------------------------------
-- spin_drunk_bottle(uuid)
-- Starts a spin: RESEATS the roster (fresh shuffle → new pizza order) and
-- clears the previous result. Any participant may spin (host-only gating is
-- a product decision for later).
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.spin_drunk_bottle(p_session_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_game_type public.mini_game_type;
    v_seats uuid[];
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT group_id, status, participants, game_type
        INTO v_group_id, v_status, v_participants, v_game_type
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;
    IF v_game_type <> 'drunk_bottle' THEN
        RETURN jsonb_build_object('status', 'wrong_game_type');
    END IF;
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;
    IF COALESCE(array_length(v_participants, 1), 0) < 2 THEN
        RETURN jsonb_build_object('status', 'not_enough_players');
    END IF;

    -- Reseat: a fresh random order every spin (the pizza is redealt).
    SELECT array_agg(p ORDER BY random()) INTO v_seats
      FROM unnest(v_participants) AS p;

    INSERT INTO public.minigame_game_state (session_id, game_type, state, ready)
    SELECT p_session_id, s.game_type,
           jsonb_build_object(
               'phase', 'playing',
               'bottle_seats', to_jsonb(v_seats),
               'bottle_spinning', true,
               'bottle_angle', NULL,
               'bottle_selected_id', NULL,
               'bottle_dare', NULL,
               'bottle_dare_category', NULL,
               'bottle_spun_by', auth.uid(),
               'bottle_seq', 1
           ),
           '{}'::jsonb
      FROM public.minigame_sessions AS s
     WHERE s.id = p_session_id
    ON CONFLICT (session_id) DO UPDATE
        SET state = minigame_game_state.state || jsonb_build_object(
                        'phase', 'playing',
                        'bottle_seats', to_jsonb(v_seats),
                        'bottle_spinning', true,
                        'bottle_angle', NULL,
                        'bottle_selected_id', NULL,
                        'bottle_dare', NULL,
                        'bottle_dare_category', NULL,
                        'bottle_spun_by', auth.uid(),
                        'bottle_seq',
                        COALESCE((minigame_game_state.state->>'bottle_seq')::int, 0) + 1
                    ),
            updated_at = now();

    RETURN jsonb_build_object('status', 'ok', 'seats', to_jsonb(v_seats));
END;
$$;

-- ----------------------------------------------------------------------
-- stop_drunk_bottle(uuid)
-- Stops the spin: draws the resting angle, derives the winner from the
-- pizza sector that angle lands in, and draws a random reto. Any
-- participant may stop.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.stop_drunk_bottle(p_session_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_game_type public.mini_game_type;
    v_state jsonb;
    v_seats uuid[];
    v_n int;
    v_angle numeric;
    v_sector int;
    v_winner uuid;
    v_dare text;
    v_category text;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT group_id, status, participants, game_type
        INTO v_group_id, v_status, v_participants, v_game_type
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;
    IF v_game_type <> 'drunk_bottle' THEN
        RETURN jsonb_build_object('status', 'wrong_game_type');
    END IF;
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    SELECT state INTO v_state
      FROM public.minigame_game_state WHERE session_id = p_session_id;
    IF v_state IS NULL OR NOT COALESCE((v_state->>'bottle_spinning')::boolean, false) THEN
        RETURN jsonb_build_object('status', 'not_spinning');
    END IF;

    -- The seats the spin dealt; fall back to the raw roster for a state
    -- written before this migration.
    SELECT array_agg(value::uuid) INTO v_seats
      FROM jsonb_array_elements_text(COALESCE(v_state->'bottle_seats', to_jsonb(v_participants)));
    v_n := COALESCE(array_length(v_seats, 1), 0);
    IF v_n = 0 THEN
        RETURN jsonb_build_object('status', 'no_seats');
    END IF;

    -- Random resting angle in [0, 360); the sector it falls into owns it.
    v_angle := random() * 360.0;
    v_sector := floor(v_angle / (360.0 / v_n))::int;
    IF v_sector >= v_n THEN v_sector := v_n - 1; END IF;  -- guard the 360.0 edge
    v_winner := v_seats[v_sector + 1];                    -- SQL arrays are 1-based

    SELECT body, category INTO v_dare, v_category
      FROM public.minigame_prompts
     WHERE game_type = 'drunk_bottle' AND prompt_type = 'reto' AND is_active
     ORDER BY random() LIMIT 1;

    UPDATE public.minigame_game_state
       SET state = state || jsonb_build_object(
                       'bottle_spinning', false,
                       'bottle_angle', v_angle,
                       'bottle_selected_id', to_jsonb(v_winner),
                       'bottle_dare', to_jsonb(v_dare),
                       'bottle_dare_category', to_jsonb(v_category),
                       'bottle_seq', COALESCE((state->>'bottle_seq')::int, 0) + 1
                   ),
           updated_at = now()
     WHERE session_id = p_session_id;

    RETURN jsonb_build_object(
        'status', 'ok',
        'angle', v_angle,
        'selected_id', v_winner,
        'dare', v_dare
    );
END;
$$;

REVOKE ALL ON FUNCTION public.spin_drunk_bottle(uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.spin_drunk_bottle(uuid) TO authenticated;
GRANT ALL ON FUNCTION public.spin_drunk_bottle(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.stop_drunk_bottle(uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.stop_drunk_bottle(uuid) TO authenticated;
GRANT ALL ON FUNCTION public.stop_drunk_bottle(uuid) TO service_role;

ALTER TABLE ONLY public.minigame_game_state REPLICA IDENTITY FULL;

