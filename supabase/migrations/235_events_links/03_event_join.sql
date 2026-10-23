-- ============================================================================
-- 235_events_links / 03_event_join.sql — consent-based joins (Q9).
--
-- Nothing here auto-joins:
--   * event link  -> open events create an ACCEPTED invite (the user tapped
--     Join); approval/invite-only events create a pending join REQUEST that a
--     host must approve.
--   * group link  -> a pending `invited` group_members row (the user still
--     accepts in the app; existing group invite UX).
--   * profile link-> a pending friendship request.
--
-- Capacity is checked under an event row lock; single-use tokens are consumed
-- only after a successful request/join (resolving a token does not consume).
--
-- Rollback:
--   DROP FUNCTION decide_event_join_request(uuid, boolean);
--   DROP FUNCTION get_event_join_requests(uuid);
--   DROP FUNCTION request_friend_by_profile_link(text);
--   DROP FUNCTION join_group_by_link(text);
--   DROP FUNCTION join_event_by_link(text, text);
--   DROP TABLE public.event_join_requests;
-- Forward-fix: replace the RPC bodies; never bypass the consent step.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.event_join_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_id uuid NOT NULL,
    user_id uuid NOT NULL,
    note text,
    status text DEFAULT 'pending' NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    decided_at timestamp with time zone,
    decided_by_user_id uuid,
    CONSTRAINT event_join_requests_pkey PRIMARY KEY (id),
    CONSTRAINT event_join_requests_event_id_user_id_key UNIQUE (event_id, user_id),
    CONSTRAINT event_join_requests_status_check
        CHECK (status IN ('pending', 'approved', 'declined')),
    CONSTRAINT event_join_requests_event_id_fkey
        FOREIGN KEY (event_id) REFERENCES public.events(id) ON DELETE CASCADE,
    CONSTRAINT event_join_requests_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE,
    CONSTRAINT event_join_requests_decided_by_fkey
        FOREIGN KEY (decided_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_event_join_requests_event
    ON public.event_join_requests USING btree (event_id);
CREATE INDEX IF NOT EXISTS idx_event_join_requests_user
    ON public.event_join_requests USING btree (user_id);

ALTER TABLE public.event_join_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_join_requests FORCE ROW LEVEL SECURITY;
-- No policies: request rows are read through get_event_join_requests (host).

REVOKE ALL ON TABLE public.event_join_requests FROM anon;
REVOKE ALL ON TABLE public.event_join_requests FROM authenticated;
REVOKE ALL ON TABLE public.event_join_requests FROM service_role;

-- ----------------------------------------------------------------------------
-- join_event_by_link(token, note)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.join_event_by_link(
    p_token text,
    p_note text DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_hash text;
    v_link public.share_links%ROWTYPE;
    v_event public.events%ROWTYPE;
    v_seats integer;
    v_pending_requests integer;
    v_request_id uuid;
    v_invite_id uuid;
    v_joined boolean := false;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    v_hash := encode(extensions.digest(btrim(COALESCE(p_token, '')), 'sha256'), 'hex');
    SELECT * INTO v_link FROM public.share_links
     WHERE token_hash = v_hash AND kind = 'event'
     FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'invalid_link');
    END IF;
    IF v_link.revoked_at IS NOT NULL
       OR v_link.expires_at <= now()
       OR (v_link.max_uses IS NOT NULL AND v_link.use_count >= v_link.max_uses) THEN
        RETURN jsonb_build_object('status', 'invalid_link');
    END IF;

    SELECT * INTO v_event FROM public.events WHERE id = v_link.subject_id FOR UPDATE;
    IF NOT FOUND OR v_event.status IN ('ended', 'cancelled') THEN
        RETURN jsonb_build_object('status', 'event_closed');
    END IF;

    IF EXISTS (SELECT 1 FROM public.event_hosts h
                WHERE h.event_id = v_event.id AND h.user_id = v_me) THEN
        RETURN jsonb_build_object('status', 'already_member');
    END IF;
    IF EXISTS (SELECT 1 FROM public.event_invites i
                WHERE i.event_id = v_event.id AND i.user_id = v_me
                  AND i.status IN ('accepted', 'attended')) THEN
        RETURN jsonb_build_object('status', 'already_member');
    END IF;
    IF EXISTS (SELECT 1 FROM public.event_invites i
                WHERE i.event_id = v_event.id AND i.user_id = v_me
                  AND i.status = 'pending') THEN
        RETURN jsonb_build_object('status', 'request_pending');
    END IF;
    IF EXISTS (SELECT 1 FROM public.event_join_requests jr
                WHERE jr.event_id = v_event.id AND jr.user_id = v_me
                  AND jr.status = 'pending') THEN
        RETURN jsonb_build_object('status', 'request_pending');
    END IF;

    SELECT public.event_seats_used(v_event.id) INTO v_seats;
    SELECT count(*)::integer INTO v_pending_requests
      FROM public.event_join_requests
     WHERE event_id = v_event.id AND status = 'pending';

    IF v_event.join_mode = 'open' THEN
        IF v_seats + v_pending_requests >= v_event.capacity THEN
            RETURN jsonb_build_object('status', 'capacity_reached');
        END IF;
        INSERT INTO public.event_invites (
            event_id, user_id, invited_by_user_id, status, responded_at
        ) VALUES (
            v_event.id, v_me, v_link.created_by_user_id, 'accepted', now()
        ) ON CONFLICT (event_id, user_id) DO UPDATE
            SET status = 'accepted', responded_at = now()
        RETURNING id INTO v_invite_id;
        v_joined := true;
    ELSE
        IF v_seats + v_pending_requests >= v_event.capacity THEN
            RETURN jsonb_build_object('status', 'capacity_reached');
        END IF;
        INSERT INTO public.event_join_requests (event_id, user_id, note)
        VALUES (v_event.id, v_me, NULLIF(btrim(COALESCE(p_note, '')), ''))
        ON CONFLICT (event_id, user_id) DO UPDATE
            SET status = 'pending', requested_at = now(), decided_at = NULL,
                decided_by_user_id = NULL, note = EXCLUDED.note
        RETURNING id INTO v_request_id;
    END IF;

    UPDATE public.share_links
       SET use_count = use_count + 1,
           last_used_at = now(),
           revoked_at = CASE WHEN single_use THEN now() ELSE revoked_at END
     WHERE id = v_link.id;

    IF v_joined THEN
        RETURN jsonb_build_object(
            'status', 'joined',
            'event_id', v_event.id,
            'invite_id', v_invite_id
        );
    END IF;
    RETURN jsonb_build_object(
        'status', 'requested',
        'event_id', v_event.id,
        'request_id', v_request_id
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- join_group_by_link(token) — pending `invited` membership, never active.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.join_group_by_link(p_token text)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_hash text;
    v_link public.share_links%ROWTYPE;
    v_group public.groups%ROWTYPE;
    v_membership_id uuid;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    v_hash := encode(extensions.digest(btrim(COALESCE(p_token, '')), 'sha256'), 'hex');
    SELECT * INTO v_link FROM public.share_links
     WHERE token_hash = v_hash AND kind = 'group'
     FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'invalid_link');
    END IF;
    IF v_link.revoked_at IS NOT NULL
       OR v_link.expires_at <= now()
       OR (v_link.max_uses IS NOT NULL AND v_link.use_count >= v_link.max_uses) THEN
        RETURN jsonb_build_object('status', 'invalid_link');
    END IF;

    SELECT * INTO v_group FROM public.groups WHERE id = v_link.subject_id;
    IF NOT FOUND OR v_group.frozen_at IS NOT NULL THEN
        RETURN jsonb_build_object('status', 'group_closed');
    END IF;
    IF EXISTS (SELECT 1 FROM public.users u
                WHERE u.id = v_me AND (u.deleted_at IS NOT NULL OR u.banned_at IS NOT NULL)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;
    IF EXISTS (SELECT 1 FROM public.group_members gm
                WHERE gm.group_id = v_group.id AND gm.user_id = v_me
                  AND gm.status = 'active') THEN
        RETURN jsonb_build_object('status', 'already_member');
    END IF;
    IF EXISTS (SELECT 1 FROM public.group_members gm
                WHERE gm.group_id = v_group.id AND gm.user_id = v_me
                  AND gm.status = 'invited') THEN
        RETURN jsonb_build_object('status', 'already_invited', 'group_id', v_group.id);
    END IF;

    INSERT INTO public.group_members (group_id, user_id, role, status)
    VALUES (v_group.id, v_me, 'member', 'invited')
    ON CONFLICT (group_id, user_id) DO UPDATE SET status = 'invited'
    RETURNING id INTO v_membership_id;

    UPDATE public.share_links
       SET use_count = use_count + 1,
           last_used_at = now(),
           revoked_at = CASE WHEN single_use THEN now() ELSE revoked_at END
     WHERE id = v_link.id;

    RETURN jsonb_build_object(
        'status', 'invited',
        'group_id', v_group.id,
        'membership_id', v_membership_id
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- request_friend_by_profile_link(token) — pending friendship only.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_friend_by_profile_link(p_token text)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_hash text;
    v_link public.share_links%ROWTYPE;
    v_target public.users%ROWTYPE;
    v_friendship_id uuid;
    v_state text := 'none';
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    v_hash := encode(extensions.digest(btrim(COALESCE(p_token, '')), 'sha256'), 'hex');
    SELECT * INTO v_link FROM public.share_links
     WHERE token_hash = v_hash AND kind = 'profile'
     FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'invalid_link');
    END IF;
    IF v_link.revoked_at IS NOT NULL
       OR v_link.expires_at <= now()
       OR (v_link.max_uses IS NOT NULL AND v_link.use_count >= v_link.max_uses) THEN
        RETURN jsonb_build_object('status', 'invalid_link');
    END IF;

    SELECT * INTO v_target FROM public.users WHERE id = v_link.subject_id;
    IF NOT FOUND OR v_target.deleted_at IS NOT NULL OR v_target.banned_at IS NOT NULL THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;
    IF v_target.id = v_me THEN
        RETURN jsonb_build_object('status', 'self');
    END IF;

    IF EXISTS (SELECT 1 FROM public.friendships f
                WHERE f.status = 'accepted'
                  AND ((f.requester_id = v_me AND f.addressee_id = v_target.id)
                    OR (f.requester_id = v_target.id AND f.addressee_id = v_me))) THEN
        RETURN jsonb_build_object('status', 'already_friends');
    END IF;
    IF EXISTS (SELECT 1 FROM public.friendships f
                WHERE f.status = 'blocked'
                  AND ((f.requester_id = v_me AND f.addressee_id = v_target.id)
                    OR (f.requester_id = v_target.id AND f.addressee_id = v_me))) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;
    IF EXISTS (SELECT 1 FROM public.friendships f
                WHERE f.status = 'pending'
                  AND f.requester_id = v_me AND f.addressee_id = v_target.id) THEN
        RETURN jsonb_build_object('status', 'already_requested');
    END IF;
    IF EXISTS (SELECT 1 FROM public.friendships f
                WHERE f.status = 'pending'
                  AND f.requester_id = v_target.id AND f.addressee_id = v_me) THEN
        RETURN jsonb_build_object('status', 'request_incoming');
    END IF;

    INSERT INTO public.friendships (requester_id, addressee_id, status)
    VALUES (v_me, v_target.id, 'pending')
    RETURNING id INTO v_friendship_id;

    UPDATE public.share_links
       SET use_count = use_count + 1,
           last_used_at = now(),
           revoked_at = CASE WHEN single_use THEN now() ELSE revoked_at END
     WHERE id = v_link.id;

    RETURN jsonb_build_object(
        'status', 'requested',
        'friendship_id', v_friendship_id,
        'target_user_id', v_target.id
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Host approval of an event join request.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_event_join_requests(p_event_id uuid)
    RETURNS TABLE(
        id uuid,
        user_id uuid,
        username text,
        note text,
        status text,
        requested_at timestamp with time zone
    )
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
BEGIN
    IF v_me IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.event_hosts h
         WHERE h.event_id = p_event_id AND h.user_id = v_me
           AND h.role IN ('host', 'staff')
    ) THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT jr.id, jr.user_id, u.username, jr.note, jr.status, jr.requested_at
      FROM public.event_join_requests jr
      LEFT JOIN public.users u ON u.id = jr.user_id
     WHERE jr.event_id = p_event_id
     ORDER BY jr.requested_at ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.decide_event_join_request(
    p_request_id uuid,
    p_approve boolean
) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_req public.event_join_requests%ROWTYPE;
    v_event public.events%ROWTYPE;
    v_seats integer;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;
    SELECT * INTO v_req FROM public.event_join_requests
     WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'request_not_found');
    END IF;
    SELECT * INTO v_event FROM public.events WHERE id = v_req.event_id FOR UPDATE;
    IF NOT FOUND OR v_event.status IN ('ended', 'cancelled') THEN
        RETURN jsonb_build_object('status', 'event_closed');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.event_hosts h
                    WHERE h.event_id = v_event.id AND h.user_id = v_me
                      AND h.role IN ('host', 'staff')) THEN
        RETURN jsonb_build_object('status', 'not_host');
    END IF;
    IF v_req.status <> 'pending' THEN
        RETURN jsonb_build_object('status', 'not_pending');
    END IF;

    IF p_approve THEN
        SELECT public.event_seats_used(v_event.id) INTO v_seats;
        IF v_seats >= v_event.capacity THEN
            RETURN jsonb_build_object('status', 'capacity_reached');
        END IF;
        INSERT INTO public.event_invites (
            event_id, user_id, invited_by_user_id, status, responded_at
        ) VALUES (
            v_event.id, v_req.user_id, v_me, 'accepted', now()
        ) ON CONFLICT (event_id, user_id) DO UPDATE
            SET status = 'accepted', responded_at = now();
        UPDATE public.event_join_requests
           SET status = 'approved', decided_at = now(), decided_by_user_id = v_me
         WHERE id = p_request_id;
        RETURN jsonb_build_object('status', 'approved');
    END IF;

    UPDATE public.event_join_requests
       SET status = 'declined', decided_at = now(), decided_by_user_id = v_me
     WHERE id = p_request_id;
    RETURN jsonb_build_object('status', 'declined');
END;
$$;

REVOKE ALL ON FUNCTION public.join_event_by_link(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.join_event_by_link(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.join_event_by_link(text, text) TO service_role;

REVOKE ALL ON FUNCTION public.join_group_by_link(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.join_group_by_link(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.join_group_by_link(text) TO service_role;

REVOKE ALL ON FUNCTION public.request_friend_by_profile_link(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_friend_by_profile_link(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_friend_by_profile_link(text) TO service_role;

REVOKE ALL ON FUNCTION public.get_event_join_requests(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_join_requests(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_event_join_requests(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.decide_event_join_request(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.decide_event_join_request(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decide_event_join_request(uuid, boolean) TO service_role;
