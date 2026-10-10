-- Samay — 224_minigame_turn_notice/turn.sql (2026-10-09)
--
-- Track-2 PUSH: the generic "it's your turn" producer.
--
-- One notification type (`minigame_turn`) abstracts the per-game turn across
-- the implemented minigames instead of a producer per game:
--   * truth_dare / two_lies_one_truth  -> state.subject_id
--   * drunk_bottle                     -> state.bottle_selected_id
--
-- It fires from a single trigger on `minigame_game_state` whenever the
-- turn-owner key changes (including the initial assignment). Charades is
-- intentionally excluded: the phone holder STARTS their own turn
-- (start_charades_turn), so a push to the actor is noise.
--
-- The push worker allow-lists this type (internal/push worker.go); the in-app
-- center carries it for every game.

CREATE OR REPLACE FUNCTION public.notify_minigame_turn() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_new uuid;
    v_old uuid;
    v_status public.mini_game_status;
BEGIN
    -- Only active sessions notify (finished/cancelled sessions are inert).
    SELECT status INTO v_status
    FROM public.minigame_sessions
    WHERE id = NEW.session_id;
    IF v_status IS DISTINCT FROM 'active' THEN
        RETURN NEW;
    END IF;

    -- Turn-owner key by game: subject_id (truth_dare / two_lies_one_truth),
    -- bottle_selected_id (drunk_bottle).
    v_new := COALESCE(
        NULLIF(NEW.state->>'subject_id', '')::uuid,
        NULLIF(NEW.state->>'bottle_selected_id', '')::uuid
    );
    IF v_new IS NULL THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        v_old := COALESCE(
            NULLIF(OLD.state->>'subject_id', '')::uuid,
            NULLIF(OLD.state->>'bottle_selected_id', '')::uuid
        );
        -- No turn change (e.g. a score/prompt update on the same subject).
        IF v_new IS NOT DISTINCT FROM v_old THEN
            RETURN NEW;
        END IF;
    END IF;

    PERFORM public.insert_notification(
        v_new,
        'minigame_turn',
        'Es tu turno',
        'Es tu turno en ' || NEW.game_type::text,
        jsonb_build_object(
            'sessionId', NEW.session_id,
            'gameType', NEW.game_type::text,
            'deepLink', '/minigames/session/' || NEW.session_id::text
        )
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_minigame_turn_trigger ON public.minigame_game_state;
CREATE TRIGGER notify_minigame_turn_trigger
    AFTER INSERT OR UPDATE ON public.minigame_game_state
    FOR EACH ROW EXECUTE FUNCTION public.notify_minigame_turn();

-- Trigger-only function: never callable by anon/authenticated.
REVOKE ALL ON FUNCTION public.notify_minigame_turn() FROM PUBLIC;
GRANT ALL ON FUNCTION public.notify_minigame_turn() TO service_role;
