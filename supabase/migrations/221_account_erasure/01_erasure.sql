-- Samay — 221_account_erasure/01_erasure.sql (2026-10-04)
--
-- True full account erasure with BOTH modes:
--   * request_account_deletion()  -> tombstone + revoke sessions + schedule
--   * purge_my_account_now()      -> immediate full erasure
--   * restore_my_account()        -> undo within the grace window
--   * purge_user(uuid)            -> the transactional full erase (public +
--                                    auth + storage outbox), used by the cron
--   * hard_delete_expired_users() -> rewritten to use the configurable grace and
--                                    to survive per-user failures
--
-- Requirement (owner 2026-10-04): "when deleted, delete everything" — including
-- the GoTrue auth.users row (email + password hash), which the previous
-- lifecycle code never touched. Apple/Google-compliant.
--
-- Storage bytes are deleted by the Go admin surface via the Storage API (direct
-- SQL deletes only drop metadata); purge_user records the object paths in the
-- pending_object_deletions outbox in the SAME transaction.
--
-- NOTE: validation must run on supabase-testing before production. The
-- auth.users delete requires the function to be owned by a role with DELETE on
-- auth.* (ALTER ... OWNER TO supabase_admin below); the Go backstop deletes via
-- the GoTrue admin API if the SQL path lacks privilege.

-- ── 1. configurable grace ──────────────────────────────────────────────────
INSERT INTO public.app_config (key, value, description, default_value)
VALUES ('account.deletion_grace_days', '30',
        'Days between an account-deletion request and full purge (0 = immediate).',
        '30')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.account_deletion_grace_days() RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT COALESCE(
        NULLIF((SELECT value FROM public.app_config WHERE key = 'account.deletion_grace_days'), ''),
        '30')::integer;
$$;
REVOKE ALL ON FUNCTION public.account_deletion_grace_days() FROM PUBLIC;
GRANT ALL ON FUNCTION public.account_deletion_grace_days() TO service_role;

-- ── 2. preserve the username so a within-grace restore is lossless ─────────
ALTER TABLE ONLY public.users
    ADD COLUMN IF NOT EXISTS deletion_previous_username text;

-- ── 3. storage-deletion outbox (drained by the Go admin surface) ───────────
CREATE TABLE IF NOT EXISTS public.pending_object_deletions (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bucket       text NOT NULL,
    object_name  text NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone
);
ALTER TABLE ONLY public.pending_object_deletions FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.pending_object_deletions FROM anon;
REVOKE ALL ON TABLE public.pending_object_deletions FROM authenticated;
GRANT ALL ON TABLE public.pending_object_deletions TO service_role;

-- ── 4. purge_user(uuid): the transactional full erase ──────────────────────
CREATE OR REPLACE FUNCTION public.purge_user(p_uid uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_email text;
BEGIN
    IF p_uid IS NULL THEN
        RAISE EXCEPTION 'purge_user: null uid' USING ERRCODE = 'P0001';
    END IF;

    -- capture the auth email before the auth row disappears (frees signup_tracker)
    BEGIN
        SELECT email INTO v_email FROM auth.users WHERE id = p_uid;
    EXCEPTION WHEN insufficient_privilege THEN
        v_email := NULL;
    END;

    -- capture storage object paths BEFORE deleting the rows that reference them
    INSERT INTO public.pending_object_deletions (bucket, object_name)
    SELECT 'events', storage_path
      FROM public.event_photos
     WHERE uploaded_by_user_id = p_uid AND storage_path IS NOT NULL
    UNION
    SELECT 'minigame_images', image_storage_path
      FROM public.minigame_answers
     WHERE subject_id = p_uid AND image_storage_path IS NOT NULL;

    BEGIN
        INSERT INTO public.pending_object_deletions (bucket, object_name)
        SELECT o.bucket_id::text, o.name::text
          FROM storage.objects o
         WHERE o.owner_id::text = p_uid::text;
    EXCEPTION WHEN insufficient_privilege OR undefined_table THEN
        NULL;
    END;

    -- rows holding a raw user id without an FK
    DELETE FROM public.message_reads          WHERE user_id = p_uid;
    DELETE FROM public.minigame_reactions     WHERE voter_id = p_uid;
    DELETE FROM public.minigame_aliases       WHERE participant_id = p_uid;
    DELETE FROM public.minigame_e2ee_bundles  WHERE sender_id = p_uid OR recipient_id = p_uid;
    DELETE FROM public.minigame_answers       WHERE subject_id = p_uid;
    DELETE FROM public.event_photos           WHERE uploaded_by_user_id = p_uid;
    DELETE FROM public.reports                WHERE reporter_id = p_uid;
    DELETE FROM public.feature_requests       WHERE requested_by_user_id = p_uid;

    -- minigames
    DELETE FROM public.minigame_invites       WHERE invitee_id = p_uid OR created_by = p_uid;
    UPDATE public.minigame_sessions SET winner_id = NULL WHERE winner_id = p_uid;
    UPDATE public.minigame_sessions SET participants = array_remove(participants, p_uid)
     WHERE p_uid = ANY(participants);
    DELETE FROM public.minigame_sessions
     WHERE coalesce(array_length(participants, 1), 0) = 0;

    -- events/groups: transfer ownership to a surviving host/member, else delete
    UPDATE public.events e
       SET created_by_user_id = (
             SELECT h.user_id FROM public.event_hosts h
              WHERE h.event_id = e.id AND h.user_id <> p_uid LIMIT 1)
     WHERE e.created_by_user_id = p_uid
       AND EXISTS (SELECT 1 FROM public.event_hosts h
                    WHERE h.event_id = e.id AND h.user_id <> p_uid);
    DELETE FROM public.events WHERE created_by_user_id = p_uid;

    UPDATE public.groups g
       SET created_by_user_id = (
             SELECT m.user_id FROM public.group_members m
              WHERE m.group_id = g.id AND m.user_id <> p_uid LIMIT 1)
     WHERE g.created_by_user_id = p_uid
       AND EXISTS (SELECT 1 FROM public.group_members m
                    WHERE m.group_id = g.id AND m.user_id <> p_uid);
    DELETE FROM public.groups WHERE created_by_user_id = p_uid;

    DELETE FROM public.event_hosts    WHERE user_id = p_uid;
    DELETE FROM public.event_invites  WHERE user_id = p_uid OR invited_by_user_id = p_uid;
    DELETE FROM public.group_members  WHERE user_id = p_uid;

    -- chat: anonymize (preserve peers' threads; E2EE means ciphertext is unreadable)
    UPDATE public.messages SET sender_id = NULL, content = '[deleted]' WHERE sender_id = p_uid;

    -- financial ledgers: preserve integrity, drop the identity link
    UPDATE public.shard_ledger    SET user_id = NULL WHERE user_id = p_uid;
    UPDATE public.preshard_ledger SET user_id = NULL WHERE user_id = p_uid;

    -- free the email so the person can re-register
    IF v_email IS NOT NULL THEN
        DELETE FROM public.signup_tracker WHERE email = v_email;
    END IF;

    -- public identity row (cascades the remaining FK-linked tables)
    DELETE FROM public.users WHERE id = p_uid;

    -- GoTrue credentials — the missing piece. Best-effort: needs privilege.
    BEGIN
        DELETE FROM auth.users WHERE id = p_uid;
        DELETE FROM auth.refresh_tokens WHERE user_id = p_uid::text;
        DELETE FROM auth.flow_state WHERE user_id = p_uid;
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE WARNING 'purge_user: no privilege to delete auth rows for % (Go backstop required)', p_uid;
    END;
END;
$$;
REVOKE ALL ON FUNCTION public.purge_user(uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.purge_user(uuid) TO service_role;
-- Ensure the DEFINER context can write auth.* (ignored if role absent).
DO $owner$ BEGIN
    BEGIN
        ALTER FUNCTION public.purge_user(uuid) OWNER TO supabase_admin;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'purge_user: could not set owner to supabase_admin: %', SQLERRM;
    END;
END $owner$;

-- ── 5. client RPCs (mode A: request, mode B: immediate, + restore) ─────────
CREATE OR REPLACE FUNCTION public.request_account_deletion() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.users
       SET deleted_at = now(),
           deletion_previous_username = COALESCE(deletion_previous_username, username),
           username = 'deleted_user_' || v_uid::text,
           avatar_url = NULL,
           bio = NULL
     WHERE id = v_uid AND deleted_at IS NULL;

    -- cut live sessions immediately (best-effort; needs auth privilege)
    BEGIN
        DELETE FROM auth.sessions WHERE user_id = v_uid;
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
END;
$$;

CREATE OR REPLACE FUNCTION public.purge_my_account_now() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = 'P0001';
    END IF;
    PERFORM public.purge_user(v_uid);
END;
$$;

CREATE OR REPLACE FUNCTION public.restore_my_account() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
    v_grace integer;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = 'P0001';
    END IF;
    v_grace := public.account_deletion_grace_days();

    UPDATE public.users
       SET deleted_at = NULL,
           username = COALESCE(deletion_previous_username, username),
           deletion_previous_username = NULL
     WHERE id = v_uid
       AND deleted_at IS NOT NULL
       AND deleted_at > now() - make_interval(days => v_grace);
END;
$$;

-- Backwards compatibility: the existing app calls delete_my_account().
CREATE OR REPLACE FUNCTION public.delete_my_account() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    PERFORM public.request_account_deletion();
END;
$$;

REVOKE ALL ON FUNCTION public.request_account_deletion() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_my_account_now() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.restore_my_account() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_my_account() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_account_deletion() TO authenticated;
GRANT EXECUTE ON FUNCTION public.purge_my_account_now() TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_my_account() TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_my_account() TO authenticated;

-- ── 6. hard_delete_expired_users(): configurable grace + resilient loop ────
CREATE OR REPLACE FUNCTION public.hard_delete_expired_users() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    expired_user RECORD;
    v_grace integer;
BEGIN
    v_grace := public.account_deletion_grace_days();
    FOR expired_user IN
        SELECT id FROM public.users
         WHERE deleted_at IS NOT NULL
           AND deleted_at < now() - make_interval(days => v_grace)
    LOOP
        BEGIN
            PERFORM public.purge_user(expired_user.id);
        EXCEPTION WHEN OTHERS THEN
            -- one bad user must not abort the whole batch
            RAISE WARNING 'hard_delete_expired_users: purge failed for %: %',
                expired_user.id, SQLERRM;
        END;
    END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.hard_delete_expired_users() FROM PUBLIC;
GRANT ALL ON FUNCTION public.hard_delete_expired_users() TO service_role;
DO $owner$ BEGIN
    BEGIN
        ALTER FUNCTION public.hard_delete_expired_users() OWNER TO supabase_admin;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'hard_delete_expired_users: could not set owner: %', SQLERRM;
    END;
END $owner$;
