-- ============================================================================
-- 234_safety_moderation / 06_forward_fixes.sql
--
-- Forward fixes after the first pgTAP run:
--   1. users.notification_preferences has an IMMUTABLE default expression, so
--      the inserting role needs EXECUTE on notification_preference_defaults().
--      The defaults are public, non-sensitive data; grant to anon/authenticated
--      (otherwise the INSERT fails on the function privilege before RLS, which
--      also breaks the "no direct INSERT" contract test).
--   2. notify_minigame_invite() must keep the 170/200 payload (gameType,
--      sessionName, wager, inviterName, groupName) and the minigame_invites
--      AFTER INSERT shape. 01 replaced it with the older 110 sessions shape by
--      mistake; this restores the latest body and adds actorId for the
--      block/mute gate.
--
-- Rollback: none needed beyond restoring a prior function body.
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.notification_preference_defaults()
    TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.notify_minigame_invite() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_game_type public.mini_game_type;
    v_session_name text;
    v_wager integer;
    v_inviter_name text;
    v_group_name text;
BEGIN
    SELECT group_id, game_type,
           COALESCE(NULLIF(btrim(name), ''), auto_name),
           shard_wager
        INTO v_group_id, v_game_type, v_session_name, v_wager
        FROM public.minigame_sessions
        WHERE id = NEW.session_id;

    SELECT username INTO v_inviter_name
    FROM public.user_search_view
    WHERE id = NEW.created_by;

    IF v_group_id IS NOT NULL THEN
        SELECT name INTO v_group_name
        FROM public.groups
        WHERE id = v_group_id;
    END IF;

    PERFORM public.insert_notification(
        NEW.invitee_id,
        'minigame_invite',
        'Invitación a minijuego',
        CASE WHEN v_wager > 0 THEN v_wager || ' shards.' ELSE 'FREE' END,
        jsonb_build_object(
            'groupId', v_group_id,
            'sessionId', NEW.session_id,
            'inviteId', NEW.id,
            'gameType', v_game_type::text,
            'sessionName', v_session_name,
            'wager', v_wager,
            'inviterName', v_inviter_name,
            'groupName', v_group_name,
            'actorId', NEW.created_by
        )
    );
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_minigame_invite() FROM PUBLIC;
GRANT ALL ON FUNCTION public.notify_minigame_invite() TO service_role;
