-- Samay — 217_minigame_two_lies_no_prompt/no_prompt.sql
-- Two Lies, One Truth (208) plays WITHOUT a topic prompt: the subject freely
-- writes their 3 statements (2 lies + 1 truth). The shared by_turns answer RPC
-- (202) still REQUIRES a revealed prompt, so a two_lies subject could never
-- submit — `submit_minigame_answer` returned `no_prompt` ("El reto aún no se ha
-- revelado") and the round stalled.
--
-- This migration re-applies submit_minigame_answer(uuid, text, text) with the
-- exact 202 body plus a game_type-aware prompt gate: the prompt is required for
-- every game EXCEPT 'two_lies_one_truth', which answers prompt-less (the answer
-- row stores NULL prompt_type/prompt_id — both columns are nullable). The 208
-- `topic` prompts stay in the bank as harmless unused data.
--
-- Posture: SECURITY DEFINER, search_path='', signature/ACL unchanged.

-- ======================================================================
-- submit_minigame_answer(uuid, text, text) — CREATE OR REPLACE (202 sig)
-- ======================================================================
CREATE OR REPLACE FUNCTION public.submit_minigame_answer(p_session_id uuid, p_answer_ciphertext text, p_image_storage_path text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_game_type public.mini_game_type;
    v_state jsonb;
    v_phase text;
    v_round integer;
    v_subject_id uuid;
    v_prompt_type text;
    v_prompt_id uuid;
    v_already boolean;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + lock.
    SELECT group_id, status, participants, game_type
        INTO v_group_id, v_status, v_participants, v_game_type
        FROM public.minigame_sessions
        WHERE id = p_session_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate — participant-only on the WRITE path (security
    --    hardening 2026-08-31: invitees / inactive group members can render
    --    the lobby but never answer).
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle + by_turns-only + playing gate.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_state IS NULL OR v_state ->> 'phase' <> 'playing' THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;
    IF COALESCE(v_state ->> 'play_mode', 'by_turns') <> 'by_turns' THEN
        RETURN jsonb_build_object('status', 'wrong_mode');
    END IF;

    -- 5. The SUBJECT only submits their own round's answer.
    v_round := COALESCE((v_state ->> 'round')::integer, 0);
    v_subject_id := (v_state ->> 'subject_id')::uuid;
    IF v_subject_id IS NULL OR v_subject_id <> auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_subject');
    END IF;

    -- 6. The round must not already be answered/passed.
    SELECT EXISTS (
        SELECT 1 FROM public.minigame_answers
        WHERE session_id = p_session_id AND round = v_round
    ) INTO v_already;
    IF v_already THEN
        RETURN jsonb_build_object('status', 'already_answered');
    END IF;

    -- 7. The prompt must be revealed for this round — EXCEPT for
    --    'two_lies_one_truth' (217), which is prompt-less by design: the
    --    subject writes their own 3 statements with no topic. The answer row
    --    then keeps NULL prompt_type/prompt_id.
    v_prompt_type := v_state ->> 'prompt_type';
    IF v_game_type <> 'two_lies_one_truth'
       AND (v_prompt_type IS NULL OR v_state -> 'prompt' IS NULL) THEN
        RETURN jsonb_build_object('status', 'no_prompt');
    END IF;
    v_prompt_id := (v_state -> 'prompt' ->> 'id')::uuid;

    -- 8. Persist the E2EE answer (ciphertext only — the server never sees
    --    plaintext).
    INSERT INTO public.minigame_answers
        (session_id, round, subject_id, prompt_type, prompt_id,
         answer_ciphertext, image_storage_path, passed)
    VALUES
        (p_session_id, v_round, v_subject_id, v_prompt_type, v_prompt_id,
         p_answer_ciphertext, p_image_storage_path, false);

    -- 9. Mirror into the state payload (realtime): the answer ciphertext
    --    streams to every participant on the existing channel.
    UPDATE public.minigame_game_state
    SET state = jsonb_set(
            state,
            '{answer}',
            jsonb_build_object(
                'subject_id', v_subject_id,
                'round', v_round,
                'prompt_type', v_prompt_type,
                'answer_ciphertext', p_answer_ciphertext,
                'image_storage_path', p_image_storage_path,
                'passed', false
            ),
            true
        )
    WHERE session_id = p_session_id;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'submitted', 'state', v_row);
END;
$$;

-- ACL posture (202 carry-over): never PUBLIC-executable.
REVOKE ALL ON FUNCTION public.submit_minigame_answer(p_session_id uuid, p_answer_ciphertext text, p_image_storage_path text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_minigame_answer(p_session_id uuid, p_answer_ciphertext text, p_image_storage_path text) TO authenticated;
GRANT ALL ON FUNCTION public.submit_minigame_answer(p_session_id uuid, p_answer_ciphertext text, p_image_storage_path text) TO service_role;
