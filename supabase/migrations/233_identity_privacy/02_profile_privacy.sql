-- ============================================================================
-- 233_identity_privacy / 02_profile_privacy.sql — Q8 discoverability
--
-- Q8 (owner decision):
--   * private profiles are findable only by EXACT username;
--   * search results never include bio or avatar for a private non-friend;
--   * private profiles do not enter the global ranking unless the owner opts
--     in (profile_public = true);
--   * no directory enumeration.
--
-- How this is enforced:
--   * user_search_view keeps the safe projection but nulls avatar/bio for a
--     private profile unless the caller is that user or an accepted friend.
--   * search_users() matches PREFIX only for opted-in (profile_public) rows;
--     a private row is returned only when lower(username) equals the trimmed
--     query exactly.
--   * get_user_ranking() filters profile_public = true, so a private profile
--     has no ranking entry at all.
--   * DIRECT client SELECT on user_search_view is revoked. The view still
--     feeds SECURITY DEFINER RPCs (search, friend profiles, lobby/invite
--     context joins) but a client can no longer enumerate every row with a
--     single PostgREST request. Clients read profiles through
--     get_public_profiles(uuid[]) or search_users(text).
--
-- Rollback: re-grant SELECT on user_search_view to authenticated and restore
-- the 120_views_ranking definitions. That reopens directory enumeration and
-- prefix discovery of private accounts; only do it with an explicit owner
-- decision.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.is_accepted_friend(p_a uuid, p_b uuid)
RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT EXISTS (
        SELECT 1
          FROM public.friendships f
         WHERE f.status = 'accepted'
           AND (
                (f.requester_id = p_a AND f.addressee_id = p_b)
                OR
                (f.addressee_id = p_a AND f.requester_id = p_b)
           )
    );
$$;

REVOKE ALL ON FUNCTION public.is_accepted_friend(uuid, uuid) FROM PUBLIC;

CREATE OR REPLACE VIEW public.user_search_view WITH (security_barrier='true') AS
 SELECT u.id,
    u.username,
    CASE
        WHEN u.profile_public
          OR u.id = auth.uid()
          OR public.is_accepted_friend(auth.uid(), u.id)
        THEN u.avatar_url
        ELSE NULL
    END AS avatar_url,
    CASE
        WHEN u.profile_public
          OR u.id = auth.uid()
          OR public.is_accepted_friend(auth.uid(), u.id)
        THEN u.bio
        ELSE NULL
    END AS bio,
    u.profile_public
   FROM public.users u
  WHERE u.deleted_at IS NULL
    AND NOT EXISTS (
        SELECT 1
          FROM public.friendships f
         WHERE f.status = 'blocked'
           AND (
                (f.requester_id = u.id AND f.addressee_id = auth.uid())
                OR
                (f.requester_id = auth.uid() AND f.addressee_id = u.id)
           )
    );

COMMENT ON VIEW public.user_search_view IS
    'Q8 safe profile projection. Private rows are exact-username only in search_users(); avatar/bio are NULL unless public, self, or accepted friend. Direct client SELECT is revoked (no directory enumeration); use get_public_profiles(uuid[]) or search_users(text).';

REVOKE ALL ON TABLE public.user_search_view FROM anon;
REVOKE ALL ON TABLE public.user_search_view FROM authenticated;
GRANT SELECT ON TABLE public.user_search_view TO service_role;

CREATE OR REPLACE FUNCTION public.get_public_profiles(p_ids uuid[])
RETURNS TABLE(id uuid, username text, avatar_url text, bio text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT usv.id,
           usv.username,
           usv.avatar_url,
           usv.bio
      FROM public.user_search_view usv
     WHERE usv.id = ANY (COALESCE(p_ids, '{}'::uuid[]));
$$;

REVOKE ALL ON FUNCTION public.get_public_profiles(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_profiles(uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.search_users(p_query text) RETURNS TABLE(id uuid, username text, avatar_url text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_current_user uuid;
    v_trimmed text;
    v_pattern text;
    v_count integer;
BEGIN
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = 'SR003',
            MESSAGE = 'not_authenticated';
    END IF;

    v_trimmed := btrim(coalesce(p_query, ''));
    IF char_length(v_trimmed) < 5 OR char_length(v_trimmed) > 50 THEN
        RAISE EXCEPTION USING
            ERRCODE = 'SR002',
            MESSAGE = 'invalid_query_length';
    END IF;

    INSERT INTO public.search_rate_limits AS srl
        (user_id, window_start, search_count)
    VALUES (v_current_user, now(), 1)
    ON CONFLICT (user_id) DO UPDATE
        SET window_start = CASE
                WHEN srl.window_start < now() - interval '1 minute'
                    THEN EXCLUDED.window_start
                ELSE srl.window_start
            END,
            search_count = CASE
                WHEN srl.window_start < now() - interval '1 minute'
                    THEN 1
                ELSE srl.search_count + 1
            END
    RETURNING srl.search_count INTO v_count;

    IF v_count > 60 THEN
        RAISE EXCEPTION USING
            ERRCODE = 'SR001',
            MESSAGE = 'search_rate_limit_exceeded';
    END IF;

    v_pattern :=
        replace(replace(replace(v_trimmed, '\', '\\'), '%', '\%'), '_', '\_')
        || '%';

    -- Q8: opted-in rows use prefix discovery; private rows require the whole
    -- handle (case-insensitive exact). The view already nulls avatar for a
    -- private non-friend and this RPC never returns bio.
    RETURN QUERY
    SELECT usv.id,
           usv.username,
           usv.avatar_url
      FROM public.user_search_view AS usv
     WHERE usv.id <> v_current_user
       AND (
            (usv.profile_public AND usv.username ILIKE v_pattern)
            OR
            (NOT usv.profile_public AND lower(usv.username) = lower(v_trimmed))
       )
     ORDER BY usv.username ASC
     LIMIT 20;
END;
$$;

REVOKE ALL ON FUNCTION public.search_users(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_users(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_user_ranking(p_limit integer DEFAULT 100)
RETURNS TABLE(user_id uuid, username text, avatar_url text, personal_shards bigint, profile_public boolean)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT
        u.id,
        u.username,
        u.avatar_url,
        u.personal_shards::bigint,
        u.profile_public
    FROM public.users u
    WHERE u.deleted_at IS NULL
      AND u.profile_public = true
    ORDER BY u.personal_shards DESC, u.username ASC
    LIMIT p_limit;
$$;

COMMENT ON FUNCTION public.get_user_ranking(integer) IS
    'Q8: only profile_public = true rows. A private profile has no ranking entry until the owner opts in.';

COMMIT;
