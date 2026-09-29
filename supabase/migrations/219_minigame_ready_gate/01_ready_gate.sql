-- ============================================================================
-- 219_minigame_ready_gate — el anfitrion no puede empezar sin que todos esten
-- listos.
--
-- Hasta ahora `init_minigame_game_state` comprobaba autenticacion, acceso,
-- que el llamante fuese el creador y que la partida estuviese activa — pero
-- NUNCA el mapa `ready`. El boton "Listo" existia y se veia en la sala, y no
-- servia para nada: el anfitrion arrancaba la cuenta atras igual.
--
-- Esta migracion anade la reja en el unico sitio que importa (el arranque de
-- la cuenta atras) y devuelve un estado tipado con los nombres que faltan,
-- siguiendo el contrato jsonb del resto de RPC (I-57), para que la interfaz
-- pueda decir exactamente a quien se espera.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.init_minigame_game_state(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_count integer;
    v_game_type public.mini_game_type;
    v_random_index integer;
    v_next_index integer;
    v_state jsonb;
    v_seeded jsonb;
    v_row jsonb;
    v_existing jsonb;
    v_not_ready text[];
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

    -- 3b. Creator-only Start gate (backend-enforced).
    IF array_length(v_participants, 1) IS NULL
       OR v_participants[1] <> auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_creator');
    END IF;

    -- 4. Lifecycle gate.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 4b. Everyone-ready gate.
    --
    -- The "Listo" toggle was decorative: nothing stopped the host from
    -- starting while the rest of the table was still reading the rules, so
    -- players landed mid-round without knowing what the game was. The host
    -- counts as ready by design (they are the one pressing Start), so only
    -- participants[2..] are checked. A player who never answers is removed
    -- from the lobby with the existing "Quitar jugador" action — that is the
    -- escape hatch, so a silent phone can never wedge the partida.
    SELECT array_agg(u.username ORDER BY u.username)
        INTO v_not_ready
        FROM unnest(v_participants) WITH ORDINALITY AS p(uid, ord)
        JOIN public.users u ON u.id = p.uid
        LEFT JOIN public.minigame_game_state m ON m.session_id = p_session_id
        WHERE p.ord > 1
          AND COALESCE((m.ready ->> p.uid::text)::boolean, false) IS NOT TRUE;

    IF v_not_ready IS NOT NULL AND array_length(v_not_ready, 1) > 0 THEN
        RETURN jsonb_build_object(
            'status', 'not_everyone_ready',
            'pending', to_jsonb(v_not_ready)
        );
    END IF;

    -- 5. Idempotency: an existing row in countdown OR playing is a no-op.
    SELECT to_jsonb(m) INTO v_existing
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_existing IS NOT NULL
       AND v_existing -> 'state' ->> 'phase' IN ('countdown', 'playing') THEN
        RETURN jsonb_build_object('status', 'already_started', 'state', v_existing);
    END IF;

    -- 6. Random first subject + random NEXT subject (server-random).
    v_count := COALESCE(array_length(v_participants, 1), 0);
    IF v_count = 0 THEN
        RETURN jsonb_build_object('status', 'no_participants');
    END IF;
    v_random_index := 1 + floor(random() * v_count)::integer;
    IF v_count = 1 THEN
        v_next_index := v_random_index;
    ELSE
        v_next_index := 1 + floor(random() * (v_count - 1))::integer;
        IF v_next_index >= v_random_index THEN
            v_next_index := v_next_index + 1;
        END IF;
    END IF;

    -- 6b. 202: carry over the mode fields the create seeded into the payload
    --     (they must survive the countdown skeleton rebuild).
    SELECT m.state INTO v_seeded
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    v_state := jsonb_build_object(
        'judge_index', 0,
        'round', 0,
        'phase', 'countdown',
        'subject_id', v_participants[v_random_index],
        'next_subject_id', v_participants[v_next_index],
        'prompt_type', NULL,
        'prompt', NULL
    );
    IF v_seeded IS NOT NULL THEN
        v_state := v_state
            || jsonb_build_object(
                   'play_mode', COALESCE(v_seeded ->> 'play_mode', 'by_turns'),
                   'anonymous', COALESCE((v_seeded ->> 'anonymous')::boolean, false),
                   'async_ends_at', v_seeded -> 'async_ends_at',
                   'async_rounds_per_player', COALESCE((v_seeded ->> 'async_rounds_per_player')::integer, 1),
                   'round_map', COALESCE(v_seeded -> 'round_map', '{}'::jsonb),
                   'answers', COALESCE(v_seeded -> 'answers', '[]'::jsonb),
                   'round_target', v_seeded -> 'round_target',
                   'prize_positions', v_seeded -> 'prize_positions'
               );
    END IF;

    -- 7. Upsert the row (fresh INSERT or lobby-seeded UPDATE).
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
$function$

