-- ============================================================================
-- 233_identity_privacy / 03_erasure_export.sql — Q1 deletion + SEC-049/050/051
--
-- Q1 (owner decision): delete the account and its content immediately; there
-- is no 30-day restore. Keep only:
--   * pseudonymized shard/preshard ledgers and event attendance (5 years);
--   * restricted report evidence (2 years, CSAM per law);
--   * infra logs/backups rotate within 90 days (not stored in this schema).
--
-- Changes:
--   * delete_my_account() / request_account_deletion() now purge immediately;
--     restore_my_account() and the grace-period helper are REMOVED.
--   * reports survive account deletion with reporter_id = NULL and a stable
--     pseudonym (FK changed to ON DELETE SET NULL). moderation_evidence and
--     message_reports are report evidence and stay restricted.
--   * attendance/contributions keep their row, lose user_id, and carry
--     pseudonymized_at + retention_until.
--   * messages authored by the user are hard-deleted; received messages stay
--     available to the other participants (their content), with recipient_id
--     detached.
--   * auth.users/sessions/refresh_tokens are deleted; failures are queued in
--     auth_cleanup_queue and recorded in account_deletion_audit.
--   * storage object paths are queued in pending_object_deletions (drained by
--     the Go storage worker) BEFORE the metadata rows disappear.
--   * export_my_data() v2 includes received messages, minigame answers,
--     device tokens, reports, and an explicit exclusions list.
--
-- Rollback: forward-fix only. Reinstating the grace window would require a new
-- product decision (Q1) and a new migration; never restore the old
-- anonymize-in-place semantics.
-- ============================================================================

BEGIN;

-- ── 0. Allow the purging user's own cascade deletes ───────────────────────
-- assert_active_actor() guards every content table (230). During a purge the
-- parent users row is already gone when FK cascades fire, so the guard would
-- abort the purge with account_inactive. The GUC is set transaction-locally by
-- purge_user() and is accepted only when it equals the caller's auth.uid();
-- clients cannot set custom GUCs through PostgREST.
CREATE OR REPLACE FUNCTION public.assert_active_actor() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    IF auth.uid() IS NOT NULL
       AND current_setting('app.purge_user', true) IS DISTINCT FROM auth.uid()::text
       AND NOT public.is_active_user(auth.uid()) THEN
        RAISE EXCEPTION 'account_inactive' USING ERRCODE = 'P0001';
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

-- ── 1. Report evidence survives the reporter's account ────────────────────
ALTER TABLE public.reports
    ADD COLUMN IF NOT EXISTS reporter_pseudonym text;
ALTER TABLE public.reports
    ADD COLUMN IF NOT EXISTS retention_until timestamp with time zone;
UPDATE public.reports
   SET retention_until = created_at + interval '2 years'
 WHERE retention_until IS NULL;
UPDATE public.reports
   SET retention_until = now() + interval '2 years'
 WHERE retention_until IS NULL;
ALTER TABLE public.reports
    ALTER COLUMN retention_until SET DEFAULT now() + interval '2 years';
ALTER TABLE public.reports
    ALTER COLUMN retention_until SET NOT NULL;
ALTER TABLE public.reports
    ALTER COLUMN reporter_id DROP NOT NULL;
ALTER TABLE public.reports
    DROP CONSTRAINT IF EXISTS reports_reporter_id_fkey;
ALTER TABLE public.reports
    ADD CONSTRAINT reports_reporter_id_fkey
    FOREIGN KEY (reporter_id) REFERENCES public.users(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.reports.reporter_pseudonym IS
    'Q1: stable non-reversible marker written when the reporter account is deleted. reporter_id becomes NULL; the report and its evidence are retained for 2 years (CSAM per law).';
COMMENT ON COLUMN public.reports.retention_until IS
    'Q1 retention: report + evidence kept until this instant (default created_at + 2 years). CSAM evidence is retained per law and must not be auto-purged.';

ALTER TABLE public.moderation_evidence
    ADD COLUMN IF NOT EXISTS retention_until timestamp with time zone;
ALTER TABLE public.moderation_evidence
    ADD COLUMN IF NOT EXISTS retention_exempt boolean NOT NULL DEFAULT false;
UPDATE public.moderation_evidence
   SET retention_until = created_at + interval '2 years'
 WHERE retention_until IS NULL;
ALTER TABLE public.moderation_evidence
    ALTER COLUMN retention_until SET DEFAULT now() + interval '2 years';
COMMENT ON COLUMN public.moderation_evidence.retention_exempt IS
    'Q1: set true for CSAM/legal-hold evidence; purge_expired_retention() skips it.';

ALTER TABLE public.message_reports
    ADD COLUMN IF NOT EXISTS retention_until timestamp with time zone;
UPDATE public.message_reports
   SET retention_until = created_at + interval '2 years'
 WHERE retention_until IS NULL;
ALTER TABLE public.message_reports
    ALTER COLUMN retention_until SET DEFAULT now() + interval '2 years';

-- ── 2. Retention columns for pseudonymized ledgers/attendance ─────────────
ALTER TABLE public.shard_ledger
    ADD COLUMN IF NOT EXISTS pseudonymized_at timestamp with time zone;
ALTER TABLE public.shard_ledger
    ADD COLUMN IF NOT EXISTS retention_until timestamp with time zone;
ALTER TABLE public.preshard_ledger
    ADD COLUMN IF NOT EXISTS pseudonymized_at timestamp with time zone;
ALTER TABLE public.preshard_ledger
    ADD COLUMN IF NOT EXISTS retention_until timestamp with time zone;

ALTER TABLE public.group_shard_contributions
    ADD COLUMN IF NOT EXISTS pseudonymized_at timestamp with time zone;
ALTER TABLE public.group_shard_contributions
    ADD COLUMN IF NOT EXISTS retention_until timestamp with time zone;
ALTER TABLE public.group_shard_contributions
    ALTER COLUMN user_id DROP NOT NULL;
ALTER TABLE public.group_shard_contributions
    DROP CONSTRAINT IF EXISTS group_shard_contributions_user_id_fkey;
ALTER TABLE public.group_shard_contributions
    ADD CONSTRAINT group_shard_contributions_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE public.event_attendances
    ADD COLUMN IF NOT EXISTS pseudonymized_at timestamp with time zone;
ALTER TABLE public.event_attendances
    ADD COLUMN IF NOT EXISTS retention_until timestamp with time zone;
ALTER TABLE public.event_attendances
    ALTER COLUMN user_id DROP NOT NULL;
ALTER TABLE public.event_attendances
    DROP CONSTRAINT IF EXISTS event_attendances_user_id_fkey;
ALTER TABLE public.event_attendances
    ADD CONSTRAINT event_attendances_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.event_attendances.pseudonymized_at IS
    'Q1: set when the attendee account is deleted; user_id becomes NULL and the attendance fact is retained for 5 years.';
COMMENT ON COLUMN public.event_attendances.retention_until IS
    'Q1 retention: pseudonymized attendance is kept until this instant (5 years).';

-- ── 3. Invites created by the deleted user no longer block the delete ─────
ALTER TABLE public.event_invites
    ALTER COLUMN invited_by_user_id DROP NOT NULL;
ALTER TABLE public.event_invites
    DROP CONSTRAINT IF EXISTS event_invites_invited_by_user_id_fkey;
ALTER TABLE public.event_invites
    ADD CONSTRAINT event_invites_invited_by_user_id_fkey
    FOREIGN KEY (invited_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;

-- ── 4. Verification/backstop tables ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.auth_cleanup_queue (
    user_id uuid NOT NULL,
    enqueued_at timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE ONLY public.auth_cleanup_queue
    ADD CONSTRAINT auth_cleanup_queue_pkey PRIMARY KEY (user_id);
ALTER TABLE public.auth_cleanup_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE ONLY public.auth_cleanup_queue FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.auth_cleanup_queue FROM anon;
REVOKE ALL ON TABLE public.auth_cleanup_queue FROM authenticated;
GRANT ALL ON TABLE public.auth_cleanup_queue TO service_role;
COMMENT ON TABLE public.auth_cleanup_queue IS
    'Q1: auth.users rows that survived the transactional purge (privilege/GoTrue race). retry_auth_cleanup() drains it; no client access.';

CREATE TABLE IF NOT EXISTS public.account_deletion_audit (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id_hash text NOT NULL,
    auth_rows_remaining integer NOT NULL DEFAULT 0,
    storage_objects_queued integer NOT NULL DEFAULT 0,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    verified_at timestamp with time zone
);
ALTER TABLE public.account_deletion_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE ONLY public.account_deletion_audit FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.account_deletion_audit FROM anon;
REVOKE ALL ON TABLE public.account_deletion_audit FROM authenticated;
GRANT ALL ON TABLE public.account_deletion_audit TO service_role;
COMMENT ON TABLE public.account_deletion_audit IS
    'Q1/SEC-049 verification: one row per purge. user_id_hash is md5(id) (no reversible identifier); auth_rows_remaining > 0 means retry_auth_cleanup()/Go backstop is still required.';

-- ── 5. purge_user(uuid): immediate full erase ─────────────────────────────
CREATE OR REPLACE FUNCTION public.purge_user(p_uid uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_email text;
    v_auth_remaining integer := 0;
    v_storage_queued integer := 0;
    v_rowcount integer := 0;
BEGIN
    IF p_uid IS NULL THEN
        RAISE EXCEPTION 'purge_user: null uid' USING ERRCODE = 'P0001';
    END IF;

    -- Scoped only to this transaction; assert_active_actor() accepts it only
    -- when it matches auth.uid(), so a client cannot disable the guard.
    PERFORM set_config('app.purge_user', p_uid::text, true);

    BEGIN
        SELECT email INTO v_email FROM auth.users WHERE id = p_uid;
    EXCEPTION WHEN insufficient_privilege THEN
        v_email := NULL;
    END;

    -- Storage paths BEFORE the metadata rows disappear. The drain worker
    -- deletes the bytes; the audit records how many paths were queued.
    BEGIN
        INSERT INTO public.pending_object_deletions (bucket, object_name)
        SELECT 'events', storage_path
          FROM public.event_photos
         WHERE uploaded_by_user_id = p_uid AND storage_path IS NOT NULL
        UNION
        SELECT 'minigame_images', image_storage_path
          FROM public.minigame_answers
         WHERE subject_id = p_uid AND image_storage_path IS NOT NULL;
        GET DIAGNOSTICS v_rowcount = ROW_COUNT;
        v_storage_queued := v_storage_queued + v_rowcount;
    EXCEPTION WHEN undefined_table THEN
        NULL;
    END;

    BEGIN
        INSERT INTO public.pending_object_deletions (bucket, object_name)
        SELECT o.bucket_id::text, o.name::text
          FROM storage.objects o
         WHERE o.owner_id::text = p_uid::text;
        GET DIAGNOSTICS v_rowcount = ROW_COUNT;
        v_storage_queued := v_storage_queued + v_rowcount;
    EXCEPTION WHEN insufficient_privilege OR undefined_table THEN
        NULL;
    END;

    -- Retained facts: drop the identity link, keep the ledger/attendance row.
    UPDATE public.shard_ledger
       SET user_id = NULL,
           pseudonymized_at = COALESCE(pseudonymized_at, now()),
           retention_until = COALESCE(retention_until, now() + interval '5 years')
     WHERE user_id = p_uid;
    UPDATE public.preshard_ledger
       SET user_id = NULL,
           pseudonymized_at = COALESCE(pseudonymized_at, now()),
           retention_until = COALESCE(retention_until, now() + interval '5 years')
     WHERE user_id = p_uid;
    UPDATE public.group_shard_contributions
       SET user_id = NULL,
           pseudonymized_at = COALESCE(pseudonymized_at, now()),
           retention_until = COALESCE(retention_until, now() + interval '5 years')
     WHERE user_id = p_uid;
    UPDATE public.event_attendances
       SET user_id = NULL,
           pseudonymized_at = COALESCE(pseudonymized_at, now()),
           retention_until = COALESCE(retention_until, now() + interval '5 years')
     WHERE user_id = p_uid;

    -- Report evidence survives, with a non-reversible reporter marker.
    UPDATE public.reports
       SET reporter_id = NULL,
           reporter_pseudonym = COALESCE(
               reporter_pseudonym,
               'deleted:' || substr(md5(p_uid::text), 1, 16)
           ),
           retention_until = GREATEST(
               COALESCE(retention_until, now()),
               now() + interval '2 years'
           )
     WHERE reporter_id = p_uid;

    -- Content: sent messages are erased; received messages belong to the
    -- remaining participants and lose the detached recipient pointer.
    DELETE FROM public.messages           WHERE sender_id = p_uid;
    UPDATE public.messages                SET recipient_id = NULL WHERE recipient_id = p_uid;
    DELETE FROM public.message_reads      WHERE user_id = p_uid;
    DELETE FROM public.chat_participants  WHERE user_id = p_uid;
    DELETE FROM public.chats c
     WHERE c.type = 'direct'
       AND NOT EXISTS (SELECT 1 FROM public.chat_participants cp WHERE cp.chat_id = c.id);

    DELETE FROM public.minigame_reactions     WHERE voter_id = p_uid;
    DELETE FROM public.minigame_aliases       WHERE participant_id = p_uid;
    DELETE FROM public.minigame_e2ee_bundles  WHERE sender_id = p_uid OR recipient_id = p_uid;
    DELETE FROM public.minigame_answers       WHERE subject_id = p_uid;
    DELETE FROM public.event_photos           WHERE uploaded_by_user_id = p_uid;
    DELETE FROM public.feature_requests       WHERE requested_by_user_id = p_uid;

    DELETE FROM public.minigame_invites       WHERE invitee_id = p_uid OR created_by = p_uid;
    UPDATE public.minigame_sessions SET winner_id = NULL WHERE winner_id = p_uid;
    UPDATE public.minigame_sessions SET participants = array_remove(participants, p_uid)
     WHERE p_uid = ANY (participants);
    DELETE FROM public.minigame_sessions
     WHERE COALESCE(array_length(participants, 1), 0) = 0;

    -- Ownership transfers, then delete owned rows that no one can inherit.
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
    UPDATE public.event_invites       SET invited_by_user_id = NULL WHERE invited_by_user_id = p_uid;
    DELETE FROM public.event_invites  WHERE user_id = p_uid;
    DELETE FROM public.group_members  WHERE user_id = p_uid;

    IF v_email IS NOT NULL THEN
        DELETE FROM public.signup_tracker WHERE email = v_email;
    END IF;

    DELETE FROM public.users WHERE id = p_uid;

    -- GoTrue credentials + sessions. Any surviving row is queued and audited;
    -- the Go admin surface can also delete via the GoTrue admin API.
    BEGIN
        DELETE FROM auth.sessions       WHERE user_id = p_uid;
        DELETE FROM auth.refresh_tokens WHERE user_id = p_uid::text;
        DELETE FROM auth.flow_state     WHERE user_id = p_uid;
        DELETE FROM auth.users          WHERE id = p_uid;
        SELECT count(*) INTO v_auth_remaining FROM auth.users WHERE id = p_uid;
    EXCEPTION WHEN insufficient_privilege THEN
        v_auth_remaining := 1;
        RAISE WARNING 'purge_user: no privilege to delete auth rows for % (queued for retry)', p_uid;
    END;

    IF v_auth_remaining > 0 THEN
        INSERT INTO public.auth_cleanup_queue (user_id)
        VALUES (p_uid)
        ON CONFLICT (user_id) DO NOTHING;
    END IF;

    INSERT INTO public.account_deletion_audit
        (user_id_hash, auth_rows_remaining, storage_objects_queued, verified_at)
    VALUES
        (md5(p_uid::text), v_auth_remaining, v_storage_queued,
         CASE WHEN v_auth_remaining = 0 THEN now() ELSE NULL END);

    PERFORM set_config('app.purge_user', '', true);
END;
$$;
REVOKE ALL ON FUNCTION public.purge_user(uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.purge_user(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.retry_auth_cleanup() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    r RECORD;
    v_cleared integer := 0;
BEGIN
    FOR r IN SELECT user_id FROM public.auth_cleanup_queue LOOP
        BEGIN
            DELETE FROM auth.sessions       WHERE user_id = r.user_id;
            DELETE FROM auth.refresh_tokens WHERE user_id = r.user_id::text;
            DELETE FROM auth.flow_state     WHERE user_id = r.user_id;
            DELETE FROM auth.users          WHERE id = r.user_id;
            IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = r.user_id) THEN
                DELETE FROM public.auth_cleanup_queue WHERE user_id = r.user_id;
                UPDATE public.account_deletion_audit
                   SET auth_rows_remaining = 0, verified_at = now()
                 WHERE user_id_hash = md5(r.user_id::text)
                   AND verified_at IS NULL;
                v_cleared := v_cleared + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'retry_auth_cleanup: %: %', r.user_id, SQLERRM;
        END;
    END LOOP;
    RETURN v_cleared;
END;
$$;
REVOKE ALL ON FUNCTION public.retry_auth_cleanup() FROM PUBLIC;
GRANT ALL ON FUNCTION public.retry_auth_cleanup() TO service_role;

-- ── 6. Client deletion RPCs: immediate, no restore ───────────────────────
CREATE OR REPLACE FUNCTION public.delete_my_account() RETURNS void
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

CREATE OR REPLACE FUNCTION public.request_account_deletion() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    -- Deprecated name kept for older clients; Q1 made deletion immediate.
    PERFORM public.delete_my_account();
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

DROP FUNCTION IF EXISTS public.restore_my_account();
DROP FUNCTION IF EXISTS public.account_deletion_grace_days();

REVOKE ALL ON FUNCTION public.delete_my_account() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_account_deletion() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_my_account_now() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_my_account() TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_account_deletion() TO authenticated;
GRANT EXECUTE ON FUNCTION public.purge_my_account_now() TO authenticated;

CREATE OR REPLACE FUNCTION public.hard_delete_expired_users() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    expired_user RECORD;
BEGIN
    -- Q1: no grace window. This is a legacy-row drain only (rows tombstoned by
    -- the pre-233 code); new deletions purge inside delete_my_account().
    FOR expired_user IN
        SELECT id FROM public.users WHERE deleted_at IS NOT NULL
    LOOP
        BEGIN
            PERFORM public.purge_user(expired_user.id);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'hard_delete_expired_users: purge failed for %: %',
                expired_user.id, SQLERRM;
        END;
    END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.hard_delete_expired_users() FROM PUBLIC;
GRANT ALL ON FUNCTION public.hard_delete_expired_users() TO service_role;

-- ── 7. export_my_data(): v2, complete + explicit exclusions ───────────────
CREATE OR REPLACE FUNCTION public.export_my_data() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    STABLE
    AS $$
DECLARE
    v_uid uuid;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = 'P0001';
    END IF;

    RETURN jsonb_build_object(
        'schema', 'samay.export.v2',
        'generated_at', now(),
        'exclusions', jsonb_build_array(
            'E2EE identity/prekey/key material (e2ee_identity_keys, minigame_e2ee_bundles) is end-to-end encrypted and not exportable by the server.',
            'event_code_keys.secret is not exportable.',
            'admin_audit_log, search_rate_limits, processed_webhooks, and subscription_overrides are operational records, not account data.',
            'moderation_evidence / message_reports plaintext is restricted report evidence retained under Q1; only the reports you submitted are listed here.',
            'Server logs and backups rotate within 90 days and are not part of this document.',
            'Storage object bytes (avatars, event photos, encrypted minigame images) are exported as paths/metadata only; download the files separately.'
        ),
        'retention', COALESCE((
            SELECT jsonb_agg(to_jsonb(rm) ORDER BY rm.data_class)
              FROM public.retention_matrix rm
        ), '[]'::jsonb),
        'user', (
            SELECT to_jsonb(u) FROM public.users u WHERE u.id = v_uid
        ),
        'friendships', COALESCE((
            SELECT jsonb_agg(to_jsonb(f)) FROM public.friendships f
             WHERE f.requester_id = v_uid OR f.addressee_id = v_uid
        ), '[]'::jsonb),
        'groups', COALESCE((
            SELECT jsonb_agg(to_jsonb(g)) FROM public.groups g
             WHERE g.created_by_user_id = v_uid
                OR EXISTS (SELECT 1 FROM public.group_members m
                            WHERE m.group_id = g.id AND m.user_id = v_uid)
        ), '[]'::jsonb),
        'group_members', COALESCE((
            SELECT jsonb_agg(to_jsonb(m)) FROM public.group_members m
             WHERE m.user_id = v_uid
        ), '[]'::jsonb),
        'group_shard_contributions', COALESCE((
            SELECT jsonb_agg(to_jsonb(c)) FROM public.group_shard_contributions c
             WHERE c.user_id = v_uid
        ), '[]'::jsonb),
        'events', COALESCE((
            SELECT jsonb_agg(to_jsonb(e)) FROM public.events e
             WHERE e.created_by_user_id = v_uid
                OR EXISTS (SELECT 1 FROM public.event_hosts h
                            WHERE h.event_id = e.id AND h.user_id = v_uid)
                OR EXISTS (SELECT 1 FROM public.event_attendances a
                            WHERE a.event_id = e.id AND a.user_id = v_uid)
                OR EXISTS (SELECT 1 FROM public.event_invites i
                            WHERE i.event_id = e.id AND i.user_id = v_uid)
        ), '[]'::jsonb),
        'event_hosts', COALESCE((
            SELECT jsonb_agg(to_jsonb(h)) FROM public.event_hosts h
             WHERE h.user_id = v_uid
        ), '[]'::jsonb),
        'event_invites', COALESCE((
            SELECT jsonb_agg(to_jsonb(i)) FROM public.event_invites i
             WHERE i.user_id = v_uid OR i.invited_by_user_id = v_uid
        ), '[]'::jsonb),
        'event_attendances', COALESCE((
            SELECT jsonb_agg(to_jsonb(a)) FROM public.event_attendances a
             WHERE a.user_id = v_uid
        ), '[]'::jsonb),
        'event_photos', COALESCE((
            SELECT jsonb_agg(to_jsonb(p)) FROM public.event_photos p
             WHERE p.uploaded_by_user_id = v_uid
        ), '[]'::jsonb),
        'event_photo_likes', COALESCE((
            SELECT jsonb_agg(to_jsonb(l)) FROM public.event_photo_likes l
             WHERE l.user_id = v_uid
        ), '[]'::jsonb),
        'chats', COALESCE((
            SELECT jsonb_agg(to_jsonb(c)) FROM public.chats c
             WHERE c.id IN (SELECT cp.chat_id FROM public.chat_participants cp
                             WHERE cp.user_id = v_uid)
        ), '[]'::jsonb),
        'chat_participants', COALESCE((
            SELECT jsonb_agg(to_jsonb(cp)) FROM public.chat_participants cp
             WHERE cp.user_id = v_uid
        ), '[]'::jsonb),
        'messages_sent', COALESCE((
            SELECT jsonb_agg(to_jsonb(m)) FROM public.messages m
             WHERE m.sender_id = v_uid
        ), '[]'::jsonb),
        'messages_received', COALESCE((
            SELECT jsonb_agg(to_jsonb(m)) FROM public.messages m
             WHERE m.sender_id <> v_uid
               AND m.chat_id IN (SELECT cp.chat_id FROM public.chat_participants cp
                                  WHERE cp.user_id = v_uid)
        ), '[]'::jsonb),
        'message_reads', COALESCE((
            SELECT jsonb_agg(to_jsonb(r)) FROM public.message_reads r
             WHERE r.user_id = v_uid
        ), '[]'::jsonb),
        'shard_ledger', COALESCE((
            SELECT jsonb_agg(to_jsonb(s)) FROM public.shard_ledger s
             WHERE s.user_id = v_uid
        ), '[]'::jsonb),
        'preshard_ledger', COALESCE((
            SELECT jsonb_agg(to_jsonb(s)) FROM public.preshard_ledger s
             WHERE s.user_id = v_uid
        ), '[]'::jsonb),
        'notifications', COALESCE((
            SELECT jsonb_agg(to_jsonb(n)) FROM public.notifications n
             WHERE n.user_id = v_uid
        ), '[]'::jsonb),
        'user_cosmetics', COALESCE((
            SELECT jsonb_agg(to_jsonb(uc)) FROM public.user_cosmetics uc
             WHERE uc.user_id = v_uid
        ), '[]'::jsonb),
        'minigame_sessions', COALESCE((
            SELECT jsonb_agg(to_jsonb(ms)) FROM public.minigame_sessions ms
             WHERE v_uid = ANY (ms.participants) OR ms.winner_id = v_uid
        ), '[]'::jsonb),
        'minigame_invites', COALESCE((
            SELECT jsonb_agg(to_jsonb(mi)) FROM public.minigame_invites mi
             WHERE mi.invitee_id = v_uid OR mi.created_by = v_uid
        ), '[]'::jsonb),
        'minigame_answers', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', a.id,
                       'session_id', a.session_id,
                       'round', a.round,
                       'prompt_type', a.prompt_type,
                       'prompt_id', a.prompt_id,
                       'answer_ciphertext', a.answer_ciphertext,
                       'image_storage_path', a.image_storage_path,
                       'passed', a.passed,
                       'created_at', a.created_at))
              FROM public.minigame_answers a
             WHERE a.subject_id = v_uid
        ), '[]'::jsonb),
        'device_tokens', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'token', dt.token,
                       'platform', dt.platform,
                       'created_at', dt.created_at,
                       'last_seen_at', dt.last_seen_at))
              FROM public.device_tokens dt
             WHERE dt.user_id = v_uid
        ), '[]'::jsonb),
        'reports', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', r.id,
                       'target_type', r.target_type,
                       'target_id', r.target_id,
                       'reason', r.reason,
                       'status', r.status,
                       'created_at', r.created_at,
                       'retention_until', r.retention_until))
              FROM public.reports r
             WHERE r.reporter_id = v_uid
        ), '[]'::jsonb),
        'reports_about_me', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', r.id,
                       'target_type', r.target_type,
                       'reason', r.reason,
                       'status', r.status,
                       'created_at', r.created_at,
                       'retention_until', r.retention_until))
              FROM public.reports r
             WHERE r.target_type = 'user'::public.report_target_type
               AND r.target_id = v_uid
        ), '[]'::jsonb),
        'feature_requests', COALESCE((
            SELECT jsonb_agg(to_jsonb(fr)) FROM public.feature_requests fr
             WHERE fr.requested_by_user_id = v_uid
        ), '[]'::jsonb)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.export_my_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.export_my_data() TO authenticated;

COMMIT;
