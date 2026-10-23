-- ============================================================================
-- 235_events_links / 02_share_links.sql — canonical bearer links (Q9).
--
-- One table holds every shareable bearer token. The raw token is NEVER stored
-- (only its SHA-256 hash); the subject id is not part of the URL. Routes are
-- served by samay.qallariy.lat as /e/<token>, /g/<token>, /u/<token>.
--
--   kind = event   -> subject_id = events.id
--   kind = group   -> subject_id = groups.id
--   kind = profile -> subject_id = users.id
--
-- Expiry: general links default to 7 days; event links default to the event
-- end (they die with the event). `single_use` is DEFAULT TRUE for non-open
-- events (approval / invite-only) and may be forced by the creator.
--
-- Consent is explicit: resolving a link only previews it. Joining/requesting
-- is a separate RPC (03_event_join.sql), so no route auto-adds a member.
--
-- RLS: FORCE + zero policies. The table is reachable only through the
-- SECURITY DEFINER RPCs below.
--
-- Rollback:
--   DROP FUNCTION resolve_share_link(text);
--   DROP FUNCTION revoke_share_link(text, uuid);
--   DROP FUNCTION rotate_share_link(text, uuid);
--   DROP FUNCTION create_share_link(text, uuid, timestamptz, boolean);
--   DROP TABLE public.share_links;
-- Forward-fix: keep the table; never store raw tokens.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.share_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    kind text NOT NULL,
    token_hash text NOT NULL,
    subject_id uuid NOT NULL,
    created_by_user_id uuid NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    single_use boolean DEFAULT false NOT NULL,
    max_uses integer,
    use_count integer DEFAULT 0 NOT NULL,
    last_used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT share_links_pkey PRIMARY KEY (id),
    CONSTRAINT share_links_kind_check CHECK (kind IN ('event', 'group', 'profile')),
    CONSTRAINT share_links_token_hash_check CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT share_links_use_count_check CHECK (use_count >= 0),
    CONSTRAINT share_links_max_uses_check CHECK (max_uses IS NULL OR max_uses >= 1),
    CONSTRAINT share_links_created_by_user_id_fkey
        FOREIGN KEY (created_by_user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS share_links_token_hash_key
    ON public.share_links USING btree (token_hash);
CREATE INDEX IF NOT EXISTS idx_share_links_subject
    ON public.share_links USING btree (kind, subject_id);
CREATE INDEX IF NOT EXISTS idx_share_links_active
    ON public.share_links USING btree (kind, subject_id, expires_at)
    WHERE revoked_at IS NULL;

ALTER TABLE public.share_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.share_links FORCE ROW LEVEL SECURITY;
-- NO policies by design: clients never read/write tokens directly.

REVOKE ALL ON TABLE public.share_links FROM anon;
REVOKE ALL ON TABLE public.share_links FROM authenticated;
REVOKE ALL ON TABLE public.share_links FROM service_role;

-- Backfill the legacy `events.invite_token` values as expiry-bound event
-- links. Old URLs keep resolving (by hash) until the event ends, but they now
-- inherit revoke/rotation semantics; no indefinite bearer token remains.
INSERT INTO public.share_links (
    kind, token_hash, subject_id, created_by_user_id,
    expires_at, single_use, max_uses, created_at
)
SELECT 'event',
       encode(extensions.digest(e.invite_token, 'sha256'), 'hex'),
       e.id,
       e.created_by_user_id,
       e.ends_at,
       false,
       NULL,
       e.created_at
  FROM public.events e
 WHERE e.invite_token IS NOT NULL
   AND e.ends_at > now()
   AND e.status NOT IN ('ended', 'cancelled')
ON CONFLICT (token_hash) DO NOTHING;

-- New events keep a matching expiry-bound legacy link row, so
-- `events.invite_token` never escapes the share_links lifecycle.
CREATE OR REPLACE FUNCTION public.sync_legacy_event_link()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    IF NEW.invite_token IS NULL OR NEW.ends_at <= now()
       OR NEW.status IN ('ended', 'cancelled') THEN
        RETURN NEW;
    END IF;
    INSERT INTO public.share_links (
        kind, token_hash, subject_id, created_by_user_id,
        expires_at, single_use, max_uses, created_at
    ) VALUES (
        'event',
        encode(extensions.digest(NEW.invite_token, 'sha256'), 'hex'),
        NEW.id,
        NEW.created_by_user_id,
        NEW.ends_at,
        false,
        NULL,
        NEW.created_at
    )
    ON CONFLICT (token_hash) DO NOTHING;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_legacy_event_link_trigger ON public.events;
CREATE TRIGGER sync_legacy_event_link_trigger
    AFTER INSERT ON public.events
    FOR EACH ROW EXECUTE FUNCTION public.sync_legacy_event_link();

REVOKE ALL ON FUNCTION public.sync_legacy_event_link() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_legacy_event_link() FROM authenticated;
REVOKE ALL ON FUNCTION public.sync_legacy_event_link() FROM service_role;

-- ----------------------------------------------------------------------------
-- create_share_link(kind, subject, expires_at, single_use)
--
-- Returns the raw token ONCE. Creating a new link revokes the subject's prior
-- active links (rotation semantics: one canonical link per subject).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_share_link(
    p_kind text,
    p_subject_id uuid,
    p_expires_at timestamp with time zone DEFAULT NULL,
    p_single_use boolean DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_token text;
    v_hash text;
    v_expires timestamp with time zone;
    v_single boolean;
    v_event public.events%ROWTYPE;
    v_allowed boolean := false;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;
    IF p_kind NOT IN ('event', 'group', 'profile') THEN
        RETURN jsonb_build_object('status', 'invalid_kind');
    END IF;

    IF p_kind = 'event' THEN
        SELECT * INTO v_event FROM public.events WHERE id = p_subject_id;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'not_found');
        END IF;
        IF v_event.status IN ('ended', 'cancelled') THEN
            RETURN jsonb_build_object('status', 'event_closed');
        END IF;
        v_allowed := v_event.created_by_user_id = v_me OR EXISTS (
            SELECT 1 FROM public.event_hosts h
             WHERE h.event_id = p_subject_id AND h.user_id = v_me
               AND h.role = 'host'
        );
        v_expires := COALESCE(p_expires_at, v_event.ends_at);
        v_single := COALESCE(p_single_use, v_event.join_mode IS DISTINCT FROM 'open');
    ELSIF p_kind = 'group' THEN
        v_allowed := EXISTS (
            SELECT 1 FROM public.group_members gm
             WHERE gm.group_id = p_subject_id AND gm.user_id = v_me
               AND gm.status = 'active'
               AND gm.role IN ('host', 'staff')
        ) OR EXISTS (
            SELECT 1 FROM public.groups g
             WHERE g.id = p_subject_id AND g.created_by_user_id = v_me
        );
        v_expires := COALESCE(p_expires_at, now() + interval '7 days');
        v_single := COALESCE(p_single_use, false);
    ELSE
        v_allowed := p_subject_id = v_me AND EXISTS (
            SELECT 1 FROM public.users u
             WHERE u.id = v_me AND u.deleted_at IS NULL AND u.banned_at IS NULL
        );
        v_expires := COALESCE(p_expires_at, now() + interval '7 days');
        v_single := COALESCE(p_single_use, false);
    END IF;

    IF NOT v_allowed THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;
    IF v_expires <= now() THEN
        RETURN jsonb_build_object('status', 'invalid_expiry');
    END IF;
    -- Cap the requested lifetime at 30 days (events still die at event end).
    IF v_expires > now() + interval '30 days' THEN
        v_expires := now() + interval '30 days';
    END IF;

    -- Rotate: the previous active link stops working immediately.
    UPDATE public.share_links
       SET revoked_at = now()
     WHERE kind = p_kind
       AND subject_id = p_subject_id
       AND revoked_at IS NULL
       AND expires_at > now();

    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');

    INSERT INTO public.share_links (
        kind, token_hash, subject_id, created_by_user_id,
        expires_at, single_use, max_uses
    ) VALUES (
        p_kind, v_hash, p_subject_id, v_me,
        v_expires, v_single, CASE WHEN v_single THEN 1 ELSE NULL END
    );

    RETURN jsonb_build_object(
        'status', 'ok',
        'token', v_token,
        'kind', p_kind,
        'subject_id', p_subject_id,
        'expires_at', v_expires,
        'single_use', v_single
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.rotate_share_link(
    p_kind text,
    p_subject_id uuid
) RETURNS jsonb
    LANGUAGE sql
    SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT public.create_share_link(p_kind, p_subject_id, NULL, NULL);
$$;

CREATE OR REPLACE FUNCTION public.revoke_share_link(
    p_kind text,
    p_subject_id uuid
) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_allowed boolean := false;
    v_count integer;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;
    IF p_kind = 'event' THEN
        v_allowed := EXISTS (SELECT 1 FROM public.events e
                              WHERE e.id = p_subject_id
                                AND e.created_by_user_id = v_me)
            OR EXISTS (SELECT 1 FROM public.event_hosts h
                        WHERE h.event_id = p_subject_id AND h.user_id = v_me
                          AND h.role = 'host');
    ELSIF p_kind = 'group' THEN
        v_allowed := EXISTS (SELECT 1 FROM public.group_members gm
                              WHERE gm.group_id = p_subject_id AND gm.user_id = v_me
                                AND gm.status = 'active'
                                AND gm.role IN ('host', 'staff'));
    ELSIF p_kind = 'profile' THEN
        v_allowed := p_subject_id = v_me;
    ELSE
        RETURN jsonb_build_object('status', 'invalid_kind');
    END IF;

    IF NOT v_allowed THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    UPDATE public.share_links
       SET revoked_at = now()
     WHERE kind = p_kind AND subject_id = p_subject_id
       AND revoked_at IS NULL;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN jsonb_build_object('status', 'ok', 'revoked', v_count);
END;
$$;

-- ----------------------------------------------------------------------------
-- resolve_share_link(token, lat, lng)
--
-- Read-only preview. Does NOT consume a single-use token and never returns an
-- exact venue to a viewer who is not host/staff/accepted. Also accepts the
-- legacy events.invite_token as an event link (pre-235 links keep working).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_share_link(
    p_token text,
    p_lat double precision DEFAULT NULL,
    p_lng double precision DEFAULT NULL
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
    v_group public.groups%ROWTYPE;
    v_user public.users%ROWTYPE;
    v_state text;
    v_exact boolean := false;
    v_distance double precision;
    v_member_count integer;
    v_friend_state text := 'none';
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;
    IF p_token IS NULL OR btrim(p_token) = '' THEN
        RETURN jsonb_build_object('status', 'invalid_link');
    END IF;

    v_hash := encode(extensions.digest(btrim(p_token), 'sha256'), 'hex');
    SELECT * INTO v_link FROM public.share_links WHERE token_hash = v_hash;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'invalid_link');
    END IF;

    IF v_link.revoked_at IS NOT NULL
       OR v_link.expires_at <= now()
       OR (v_link.max_uses IS NOT NULL AND v_link.use_count >= v_link.max_uses) THEN
        RETURN jsonb_build_object('status', 'invalid_link');
    END IF;

    IF v_link.kind = 'event' THEN
        SELECT * INTO v_event FROM public.events WHERE id = v_link.subject_id;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'invalid_link');
        END IF;
        v_exact := EXISTS (SELECT 1 FROM public.event_hosts h
                            WHERE h.event_id = v_event.id AND h.user_id = v_me)
            OR EXISTS (SELECT 1 FROM public.event_invites i
                        WHERE i.event_id = v_event.id AND i.user_id = v_me
                          AND i.status IN ('accepted', 'attended'));
        v_state := CASE
            WHEN v_exact THEN 'member'
            WHEN EXISTS (SELECT 1 FROM public.event_invites i
                          WHERE i.event_id = v_event.id AND i.user_id = v_me
                            AND i.status = 'pending') THEN 'pending'
            WHEN EXISTS (SELECT 1 FROM public.event_join_requests jr
                          WHERE jr.event_id = v_event.id AND jr.user_id = v_me
                            AND jr.status = 'pending') THEN 'requested'
            ELSE 'viewer'
        END;
        IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
            v_distance := public.haversine_km(
                p_lat, p_lng,
                v_event.location_lat::double precision,
                v_event.location_lng::double precision);
        END IF;

        RETURN jsonb_build_object(
            'status', 'ok',
            'kind', 'event',
            'subject_id', v_event.id,
            'viewer_state', v_state,
            'can_join', v_state IN ('viewer', 'pending') AND v_event.status IN ('upcoming', 'live'),
            'single_use', v_link.single_use,
            'expires_at', v_link.expires_at,
            'name', v_event.name,
            'description', v_event.description,
            'cover_url', v_event.cover_url,
            'event_type', v_event.type,
            'event_status', v_event.status,
            'starts_at', v_event.starts_at,
            'ends_at', v_event.ends_at,
            'join_mode', v_event.join_mode,
            'location_city', v_event.location_city,
            'location_name', CASE WHEN v_exact THEN v_event.location_name END,
            'location_lat', NULL,
            'location_lng', NULL,
            'distance_km', v_distance
        );
    ELSIF v_link.kind = 'group' THEN
        SELECT * INTO v_group FROM public.groups WHERE id = v_link.subject_id;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'invalid_link');
        END IF;
        v_state := CASE
            WHEN EXISTS (SELECT 1 FROM public.group_members gm
                          WHERE gm.group_id = v_group.id AND gm.user_id = v_me
                            AND gm.status = 'active') THEN 'member'
            WHEN EXISTS (SELECT 1 FROM public.group_members gm
                          WHERE gm.group_id = v_group.id AND gm.user_id = v_me
                            AND gm.status = 'invited') THEN 'invited'
            ELSE 'viewer'
        END;
        SELECT count(*)::integer INTO v_member_count
          FROM public.group_members gm
         WHERE gm.group_id = v_group.id AND gm.status = 'active';

        RETURN jsonb_build_object(
            'status', 'ok',
            'kind', 'group',
            'subject_id', v_group.id,
            'viewer_state', v_state,
            'can_join', v_state = 'viewer' AND v_group.frozen_at IS NULL,
            'single_use', v_link.single_use,
            'expires_at', v_link.expires_at,
            'name', v_group.name,
            'description', v_group.description,
            'cover_url', v_group.cover_url,
            'member_count', v_member_count
        );
    ELSE
        SELECT * INTO v_user FROM public.users WHERE id = v_link.subject_id;
        IF NOT FOUND OR v_user.deleted_at IS NOT NULL OR v_user.banned_at IS NOT NULL THEN
            RETURN jsonb_build_object('status', 'invalid_link');
        END IF;
        IF v_user.id = v_me THEN
            v_friend_state := 'self';
        ELSIF EXISTS (SELECT 1 FROM public.friendships f
                       WHERE f.status = 'accepted'
                         AND ((f.requester_id = v_me AND f.addressee_id = v_user.id)
                           OR (f.requester_id = v_user.id AND f.addressee_id = v_me))) THEN
            v_friend_state := 'friends';
        ELSIF EXISTS (SELECT 1 FROM public.friendships f
                       WHERE f.status = 'blocked'
                         AND ((f.requester_id = v_me AND f.addressee_id = v_user.id)
                           OR (f.requester_id = v_user.id AND f.addressee_id = v_me))) THEN
            v_friend_state := 'blocked';
        ELSIF EXISTS (SELECT 1 FROM public.friendships f
                       WHERE f.status = 'pending'
                         AND f.requester_id = v_me AND f.addressee_id = v_user.id) THEN
            v_friend_state := 'requested';
        ELSIF EXISTS (SELECT 1 FROM public.friendships f
                       WHERE f.status = 'pending'
                         AND f.requester_id = v_user.id AND f.addressee_id = v_me) THEN
            v_friend_state := 'incoming';
        END IF;

        RETURN jsonb_build_object(
            'status', 'ok',
            'kind', 'profile',
            'subject_id', v_user.id,
            'viewer_state', v_friend_state,
            'can_join', v_friend_state = 'none',
            'single_use', v_link.single_use,
            'expires_at', v_link.expires_at,
            'name', v_user.username,
            'username', v_user.username,
            'avatar_url', v_user.avatar_url,
            'bio', v_user.bio,
            'profile_public', v_user.profile_public
        );
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.create_share_link(text, uuid, timestamp with time zone, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_share_link(text, uuid, timestamp with time zone, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_share_link(text, uuid, timestamp with time zone, boolean) TO service_role;

REVOKE ALL ON FUNCTION public.rotate_share_link(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rotate_share_link(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rotate_share_link(text, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.revoke_share_link(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.revoke_share_link(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_share_link(text, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.resolve_share_link(text, double precision, double precision) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_share_link(text, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_share_link(text, double precision, double precision) TO service_role;
