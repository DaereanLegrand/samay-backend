-- ======================================================================
-- Charadas: no repeated words inside a turn (212_charades_no_repeats).
--
-- 211's draw only excluded the word currently on screen, so a 30s turn on a
-- 12-word category handed the same word back two or three times — it reads
-- as a bug to the players. Exclude everything the turn has already shown
-- (the charades_log), and only fall back to repeats once the category is
-- exhausted (better a repeat than an empty screen).
-- ======================================================================

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
    v_seen text[];
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

    -- Everything this turn already showed (log + the word on screen).
    SELECT COALESCE(array_agg(entry->>'word'), ARRAY[]::text[]) INTO v_seen
      FROM jsonb_array_elements(COALESCE(v_state->'charades_log', '[]'::jsonb)) AS entry;
    v_seen := v_seen || ARRAY[v_word];

    SELECT body INTO v_next
      FROM public.minigame_prompts
     WHERE game_type = 'charades' AND prompt_type = 'palabra' AND is_active
       AND (v_category IS NULL OR category = v_category)
       AND NOT (body = ANY (v_seen))
     ORDER BY random() LIMIT 1;

    -- Category exhausted: allow a repeat rather than stalling the turn, but
    -- never hand back the word that is still on screen.
    IF v_next IS NULL THEN
        SELECT body INTO v_next
          FROM public.minigame_prompts
         WHERE game_type = 'charades' AND prompt_type = 'palabra' AND is_active
           AND (v_category IS NULL OR category = v_category)
           AND body IS DISTINCT FROM v_word
         ORDER BY random() LIMIT 1;
    END IF;

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
