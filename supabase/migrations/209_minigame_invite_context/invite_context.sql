-- 209_minigame_invite_context — get_minigame_invite_context(uuid)
--
-- WHY (2026-09-11): the partida LOBBY's pending-invite view must show the
-- INVITER only ("INVITADO POR" + avatar), never the participant roster. The
-- generic get_minigame_participants RPC intentionally lets a pending invitee
-- read the whole roster (its invite gate has no status filter), so the client
-- could briefly render the player list before the invite row resolves. This
-- scoped RPC returns the narrowest possible context: the caller's inviter
-- profile + the group name (null for a direct session). A non-invitee gets
-- `invite_not_found` and learns nothing.
--
-- Posture mirrors get_minigame_participants (180_minigame_lobby): SECURITY
-- DEFINER, SET search_path = '', authenticated EXECUTE only. Reads the
-- security-barrier `user_search_view` (deleted + blocked excluded) by the
-- invite's `created_by`; it NEVER touches `participants`.

CREATE FUNCTION public.get_minigame_invite_context(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_created_by uuid;
    v_group_id uuid;
    v_inviter jsonb;
    v_group_name text;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. The caller's own invite for this session (never another invitee's).
    SELECT mi.created_by, ms.group_id
        INTO v_created_by, v_group_id
        FROM public.minigame_invites AS mi
        JOIN public.minigame_sessions AS ms ON ms.id = mi.session_id
        WHERE mi.session_id = p_session_id
          AND mi.invitee_id = auth.uid()
        LIMIT 1;
    IF NOT FOUND THEN
        -- Not invited: reveal nothing (no roster, no session shape).
        RETURN jsonb_build_object('status', 'invite_not_found');
    END IF;

    -- 3. Resolve ONLY the inviter through the security-barrier view.
    SELECT jsonb_build_object(
               'id', usv.id,
               'username', usv.username,
               'avatar_url', usv.avatar_url
           )
        INTO v_inviter
        FROM public.user_search_view AS usv
        WHERE usv.id = v_created_by;

    -- 4. Group name context (null for a direct session).
    IF v_group_id IS NOT NULL THEN
        SELECT name INTO v_group_name
        FROM public.groups
        WHERE id = v_group_id;
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok',
        'inviter', v_inviter,
        'groupName', v_group_name
    );
END;
$$;

-- ACL — PUBLIC revoked, authenticated only (mirrors 180).
REVOKE ALL ON FUNCTION public.get_minigame_invite_context(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_minigame_invite_context(uuid) TO authenticated;
