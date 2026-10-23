-- ============================================================================
-- 234_safety_moderation / 05_erasure_evidence.sql
--
-- Q6: evidence must survive reporter erasure. 221_account_erasure/purge_user()
-- deleted every report authored by the erased user, which cascaded the
-- moderator-readable message snapshot and detached the evidence row. The
-- report queue row (and its evidence, retention clock and legal hold) is now
-- PRESERVED with the reporter reference anonymized to NULL.
--
-- Rollback: restore the 221 purge_user() body (evidence would be lost again —
-- do not roll back without an owner decision). Forward-fix: keep the UPDATE;
-- never DELETE reports during erasure.
-- ============================================================================

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

    -- Q6: preserve moderation queue rows + evidence. Detach the reporter link;
    -- the target snapshot remains under its 2-year/legal-hold clock.
    UPDATE public.reports SET reporter_id = NULL WHERE reporter_id = p_uid;

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
    DELETE FROM public.groups WHERE g.created_by_user_id = p_uid;

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
DO $owner$ BEGIN
    BEGIN
        ALTER FUNCTION public.purge_user(uuid) OWNER TO supabase_admin;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'purge_user: could not set owner to supabase_admin: %', SQLERRM;
    END;
END $owner$;
