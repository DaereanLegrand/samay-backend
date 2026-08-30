-- Samay — 200_minigame_invite_notice/invite_notice.sql
-- Wager amount + inviter/group in the minigame-invite notification
-- (2026-08-30).
--
-- The invite notification body previously said only "Te invitaron a un
-- minijuego" — an invitee could not tell whether the match cost shards until
-- opening the session detail. The wager is the amount that will be TAKEN from
-- each participant until the game finishes or is cancelled, so it must be
-- explicit up front (a player without the funds cannot participate — the
-- accept RPC enforces `insufficient_shards` server-side).
--
-- The invitee must ALSO see who invited them wherever the invite can be
-- accepted: the inviter's username for a DIRECT session, or the group name
-- for a GROUP session. Both are unreadable through RLS from a non-member
-- invitee (the group row requires membership; another user's profile requires
-- the user_search_view security barrier), so the notification payload carries
-- them from the server: `inviterName` (via user_search_view — deleted/blocked
-- excluded, so a deleted inviter degrades to NULL) and `groupName` (null for
-- direct sessions).
--
-- notify_minigame_invite (CREATE OR REPLACE, same no-arg signature) now:
--
--   * Reads shard_wager from the session (0 = free game).
--   * Body (Spanish, like every notification body — inserted server-side):
--       wagered -> "{N} shards."
--       free    -> "FREE"
--   * data payload gains "wager", "inviterName" and "groupName" so clients
--     render the cost and the inviter/group without re-querying the session.
--
-- Everything else is byte-identical to 170: fires for BOTH scopes, keeps
-- gameType + sessionName + sessionId + inviteId + groupId in the payload.
-- Posture mirrors 140/170: SECURITY DEFINER, SET search_path = '',
-- service_role EXECUTE only (the ACL grants at the bottom re-assert it).
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
    SELECT group_id, game_type, COALESCE(NULLIF(btrim(name), ''), auto_name), shard_wager
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
            'groupName', v_group_name
        )
    );
    RETURN NEW;
END;
$$;

-- ACL — re-assert the 170 posture (PUBLIC revoked, service_role only; the
-- trigger fires SECURITY DEFINER so the invitee never calls it directly).
REVOKE ALL ON FUNCTION public.notify_minigame_invite() FROM PUBLIC;
GRANT ALL ON FUNCTION public.notify_minigame_invite() TO service_role;
