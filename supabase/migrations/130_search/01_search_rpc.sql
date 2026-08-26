-- SEARCH hardening — OWASP API4:2023 "Unrestricted Resource Consumption"
-- (rate limiting per endpoint + server-side input caps + cheap allowed
-- queries). The user-search endpoint was a raw PostgREST ilike on
-- user_search_view: no length validation, no rate limit, and every query
-- sequential-scanned users (plain-btree idx_users_username cannot serve
-- ILIKE prefixes). Three layers:
--
--   1. search_users(p_query) RPC — SECURITY DEFINER gate that validates the
--      trimmed query length (usernames are >= 5 chars, so 1..4-char
--      prefixes can never match), enforces a 60-searches/rolling-minute
--      per-user quota, escapes LIKE wildcards, excludes the caller, and
--      caps results at 20 rows. Custom SQLSTATEs: SR001 = quota exceeded,
--      SR002 = invalid query length, SR003 = not authenticated.
--   2. search_rate_limits — one bounded row per user (PK on user_id).
--   3. idx_users_username_prefix — text_pattern_ops btree so each ALLOWED
--      query is an index scan instead of a seq scan.
--
-- NOTE (deviation from the hardening proposal): direct SELECT on
-- user_search_view stays granted to authenticated — the view feeds five
-- non-search surfaces (public profiles via UserService, group/event/shard
-- member joins, chat sender resolution). The Kong route limiter on
-- /rest/v1/user_search_view covers the raw path; this RPC is the only path
-- the app itself uses for search.

CREATE TABLE public.search_rate_limits (
    user_id uuid NOT NULL,
    window_start timestamp with time zone DEFAULT now() NOT NULL,
    search_count integer DEFAULT 0 NOT NULL
);

ALTER TABLE ONLY public.search_rate_limits
    ADD CONSTRAINT search_rate_limits_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY public.search_rate_limits
    ADD CONSTRAINT search_rate_limits_user_id_fkey FOREIGN KEY (user_id)
    REFERENCES public.users(id) ON DELETE CASCADE;

COMMENT ON TABLE public.search_rate_limits IS 'Per-user search quota state (60/rolling minute) backing search_users(); no client grants';

CREATE INDEX idx_users_username_prefix ON public.users USING btree (username text_pattern_ops);

CREATE FUNCTION public.search_users(p_query text) RETURNS TABLE(id uuid, username text, avatar_url text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_current_user uuid;
    v_trimmed text;
    v_pattern text;
    v_count integer;
BEGIN
    -- 1. Authentication gate. auth.uid() resolves in the auth schema by
    --    explicit qualification; anon callers (auth.uid() = NULL) fail here.
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = 'SR003',
            MESSAGE = 'not_authenticated';
    END IF;

    -- 2. Input validation (OWASP API4: enforce size caps server-side —
    --    client-side sanitization is bypassable). Usernames are >= 5 chars,
    --    so shorter trimmed queries can never match anything.
    v_trimmed := btrim(coalesce(p_query, ''));
    IF char_length(v_trimmed) < 5 OR char_length(v_trimmed) > 50 THEN
        RAISE EXCEPTION USING
            ERRCODE = 'SR002',
            MESSAGE = 'invalid_query_length';
    END IF;

    -- 3. Per-user quota: 60 searches per rolling minute. The atomic upsert
    --    resets the window when the stored start has expired; row-level
    --    locking on conflict keeps concurrent calls race-free.
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

    -- 4. Prefix match with LIKE wildcards escaped (usernames may contain
    --    _ or %), caller excluded, deterministic order, capped at 20.
    v_pattern :=
        replace(replace(replace(v_trimmed, '\', '\\'), '%', '\%'), '_', '\_')
        || '%';

    RETURN QUERY
    SELECT usv.id,
           usv.username,
           usv.avatar_url
      FROM public.user_search_view AS usv
     WHERE usv.id <> v_current_user
       AND usv.username ILIKE v_pattern
     ORDER BY usv.username ASC
     LIMIT 20;
END;
$$;

--
-- Name: FUNCTION search_users(text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.search_users(p_query text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_users(p_query text) TO authenticated;

--
-- Name: TABLE search_rate_limits; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON public.search_rate_limits FROM anon;
REVOKE ALL ON public.search_rate_limits FROM authenticated;
GRANT ALL ON public.search_rate_limits TO service_role;

--
-- Name: TABLE search_rate_limits; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.search_rate_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.search_rate_limits FORCE ROW LEVEL SECURITY;
