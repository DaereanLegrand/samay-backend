-- ============================================================================
-- 234_safety_moderation / 03_report_rpc.sql
--
-- Server-side report intake, validation, snapshots, moderation actions and
-- appeals. Every client-facing RPC validates the caller's RELATIONSHIP to the
-- target and derives priority server-side (never trusts a client category or
-- priority beyond the enum value).
--
-- Rollback: restore report_message()/moderate_report() from 231/230 and drop
-- report_content/submit_appeal/decide_appeal/my_appeals/my_report_outcomes.
-- Forward-fix: extend the CASE arms; never remove an existing target arm
-- without a client migration.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Target snapshot + actor resolution (shared by intake, moderation and
-- appeals). Returns NULL when the target no longer exists.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.moderation_snapshot(
    p_target_type public.report_target_type,
    p_target_id uuid
) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_snapshot jsonb;
BEGIN
    CASE p_target_type
        WHEN 'message' THEN
            SELECT to_jsonb(m) INTO v_snapshot FROM public.messages m WHERE m.id = p_target_id;
        WHEN 'photo' THEN
            SELECT to_jsonb(p) INTO v_snapshot FROM public.event_photos p WHERE p.id = p_target_id;
        WHEN 'user', 'avatar' THEN
            SELECT to_jsonb(u) INTO v_snapshot FROM public.users u WHERE u.id = p_target_id;
        WHEN 'event', 'event_description' THEN
            SELECT to_jsonb(e) INTO v_snapshot FROM public.events e WHERE e.id = p_target_id;
        WHEN 'group_cover' THEN
            SELECT to_jsonb(g) INTO v_snapshot FROM public.groups g WHERE g.id = p_target_id;
        WHEN 'minigame_answer', 'minigame_image' THEN
            SELECT to_jsonb(a) INTO v_snapshot FROM public.minigame_answers a WHERE a.id = p_target_id;
        ELSE
            v_snapshot := NULL;
    END CASE;
    RETURN v_snapshot;
END;
$$;

CREATE OR REPLACE FUNCTION public.moderation_target_actor(
    p_target_type public.report_target_type,
    p_target_id uuid
) RETURNS uuid
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_actor uuid;
BEGIN
    CASE p_target_type
        WHEN 'message' THEN
            SELECT sender_id INTO v_actor FROM public.messages WHERE id = p_target_id;
        WHEN 'photo' THEN
            SELECT uploaded_by_user_id INTO v_actor FROM public.event_photos WHERE id = p_target_id;
        WHEN 'user', 'avatar' THEN
            v_actor := p_target_id;
        WHEN 'event', 'event_description' THEN
            SELECT created_by_user_id INTO v_actor FROM public.events WHERE id = p_target_id;
        WHEN 'group_cover' THEN
            SELECT created_by_user_id INTO v_actor FROM public.groups WHERE id = p_target_id;
        WHEN 'minigame_answer', 'minigame_image' THEN
            SELECT subject_id INTO v_actor FROM public.minigame_answers WHERE id = p_target_id;
        ELSE
            v_actor := NULL;
    END CASE;
    RETURN v_actor;
END;
$$;

REVOKE ALL ON FUNCTION public.moderation_snapshot(public.report_target_type, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_target_actor(public.report_target_type, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.moderation_snapshot(public.report_target_type, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.moderation_target_actor(public.report_target_type, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- report_content — the generic UGC report path for every surface that is not
-- the E2EE message path. Validates relationship to the target and captures the
-- evidence snapshot in the same transaction as the queue row.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_content(
    p_target_type text,
    p_target_id uuid,
    p_category text DEFAULT 'other',
    p_reason text DEFAULT NULL,
    p_snapshot jsonb DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_type public.report_target_type;
    v_category public.report_category;
    v_report_id uuid;
    v_actor uuid;
    v_snapshot jsonb;
    v_allowed boolean := false;
    v_reason text;
    v_priority smallint;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;
    IF p_target_id IS NULL THEN
        RETURN jsonb_build_object('status', 'target_not_found');
    END IF;

    BEGIN
        v_type := p_target_type::public.report_target_type;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('status', 'invalid_target_type');
    END;

    BEGIN
        v_category := lower(coalesce(p_category, 'other'))::public.report_category;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('status', 'invalid_category');
    END;

    v_reason := COALESCE(NULLIF(btrim(p_reason), ''), v_category::text);

    -- Relationship validation. A reporter can only report content they can
    -- already see/participate in (or their own settings surfaces).
    CASE v_type
        WHEN 'user', 'avatar' THEN
            v_allowed := p_target_id <> v_me AND EXISTS (
                SELECT 1 FROM public.users
                 WHERE id = p_target_id AND deleted_at IS NULL
            );
        WHEN 'event', 'event_description' THEN
            v_allowed := EXISTS (
                SELECT 1 FROM public.events e
                 WHERE e.id = p_target_id
                   AND (
                       EXISTS (SELECT 1 FROM public.event_hosts h
                                WHERE h.event_id = e.id AND h.user_id = v_me)
                       OR EXISTS (SELECT 1 FROM public.event_invites i
                                   WHERE i.event_id = e.id AND i.user_id = v_me
                                     AND i.status IN ('accepted', 'attended'))
                       OR (e.group_id IS NOT NULL AND EXISTS (
                              SELECT 1 FROM public.group_members gm
                               WHERE gm.group_id = e.group_id AND gm.user_id = v_me
                                 AND gm.status = 'active'))
                   )
            );
        WHEN 'photo' THEN
            v_allowed := EXISTS (
                SELECT 1 FROM public.event_photos p
                 WHERE p.id = p_target_id
                   AND (
                       p.uploaded_by_user_id = v_me
                       OR EXISTS (SELECT 1 FROM public.event_attendances a
                                   WHERE a.event_id = p.event_id AND a.user_id = v_me)
                       OR EXISTS (SELECT 1 FROM public.event_hosts h
                                   WHERE h.event_id = p.event_id AND h.user_id = v_me)
                   )
            );
        WHEN 'group_cover' THEN
            v_allowed := EXISTS (
                SELECT 1 FROM public.group_members gm
                 WHERE gm.group_id = p_target_id AND gm.user_id = v_me
                   AND gm.status = 'active'
            );
        WHEN 'minigame_answer', 'minigame_image' THEN
            v_allowed := EXISTS (
                SELECT 1
                  FROM public.minigame_answers a
                  JOIN public.minigame_sessions s ON s.id = a.session_id
                 WHERE a.id = p_target_id
                   AND (v_type <> 'minigame_image' OR a.image_storage_path IS NOT NULL)
                   AND (
                       (s.group_id IS NULL AND v_me = ANY (s.participants))
                       OR EXISTS (SELECT 1 FROM public.minigame_invites mi
                                   WHERE mi.session_id = s.id AND mi.invitee_id = v_me)
                       OR (s.group_id IS NOT NULL AND EXISTS (
                              SELECT 1 FROM public.group_members gm
                               WHERE gm.group_id = s.group_id AND gm.user_id = v_me
                                 AND gm.status = 'active'))
                   )
            );
        ELSE
            v_allowed := false;
    END CASE;

    IF NOT v_allowed THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    v_snapshot := COALESCE(
        p_snapshot,
        public.moderation_snapshot(v_type, p_target_id)
    );
    IF v_snapshot IS NULL THEN
        RETURN jsonb_build_object('status', 'target_not_found');
    END IF;

    INSERT INTO public.reports
        (reporter_id, target_type, target_id, reason, category, status)
    VALUES
        (v_me, v_type, p_target_id, v_reason, v_category, 'pending')
    RETURNING id, priority INTO v_report_id, v_priority;

    INSERT INTO public.moderation_evidence
        (report_id, target_type, target_id, snapshot, reporter_id, retention_until)
    VALUES
        (v_report_id, v_type, p_target_id, v_snapshot, v_me, now() + interval '2 years');

    RETURN jsonb_build_object(
        'status', 'ok',
        'report_id', v_report_id,
        'category', v_category,
        'priority', v_priority,
        'actor_id', public.moderation_target_actor(v_type, p_target_id)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.report_content(text, uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_content(text, uuid, text, text, jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- report_message — same 3-arg signature used by the shipped client, now with
-- category + report-time evidence. The plaintext is the E2EE reporting
-- exception (the reporter discloses exactly the reported row).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_message(
    p_message_id uuid,
    p_reason text,
    p_plaintext text DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_chat_id uuid;
    v_sender_id uuid;
    v_media_url text;
    v_reason text;
    v_category public.report_category;
    v_report_id uuid;
    v_snapshot jsonb;
    v_message jsonb;
    v_priority smallint;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    v_reason := COALESCE(NULLIF(btrim(p_reason), ''), 'other');
    v_category := public.report_category_from_text(v_reason);

    SELECT chat_id, sender_id, media_url, to_jsonb(m)
      INTO v_chat_id, v_sender_id, v_media_url, v_message
      FROM public.messages m
     WHERE id = p_message_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'message_not_found');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.chats
        WHERE id = v_chat_id AND (
            (type = 'direct' AND EXISTS (
                SELECT 1 FROM public.chat_participants
                WHERE chat_id = v_chat_id AND user_id = v_me
            ))
            OR (type = 'group' AND EXISTS (
                SELECT 1 FROM public.group_members
                WHERE group_id = chats.reference_id
                  AND user_id = v_me
                  AND status = 'active'
            ))
            OR (type = 'event' AND (
                EXISTS (
                    SELECT 1 FROM public.event_invites
                    WHERE event_id = chats.reference_id
                      AND user_id = v_me
                      AND status IN ('accepted', 'attended')
                )
                OR EXISTS (
                    SELECT 1 FROM public.event_hosts
                    WHERE event_id = chats.reference_id AND user_id = v_me
                )
            ))
        )
    ) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    INSERT INTO public.reports
        (reporter_id, target_type, target_id, reason, category, status)
    VALUES
        (v_me, 'message', p_message_id, v_reason, v_category, 'pending')
    RETURNING id, priority INTO v_report_id, v_priority;

    INSERT INTO public.message_reports (
        report_id, message_id, chat_id, sender_id, reporter_id, reason,
        plaintext, media_url
    ) VALUES (
        v_report_id, p_message_id, v_chat_id, v_sender_id, v_me, v_reason,
        p_plaintext, v_media_url
    );

    v_snapshot := COALESCE(v_message, '{}'::jsonb)
        || jsonb_build_object(
               'reportedPlaintext', p_plaintext,
               'mediaUrl', v_media_url
           );
    INSERT INTO public.moderation_evidence
        (report_id, target_type, target_id, snapshot, reporter_id, retention_until)
    VALUES
        (v_report_id, 'message', p_message_id, v_snapshot, v_me, now() + interval '2 years');

    UPDATE public.messages SET reported = true WHERE id = p_message_id;

    RETURN jsonb_build_object(
        'status', 'ok',
        'report_id', v_report_id,
        'category', v_category,
        'priority', v_priority
    );
END;
$$;

REVOKE ALL ON FUNCTION public.report_message(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_message(uuid, text, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- claim_report — explicit queue ownership (service/API only).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_report(
    p_report_id uuid,
    p_admin_user_id uuid
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_report public.reports%ROWTYPE;
BEGIN
    SELECT * INTO v_report FROM public.reports WHERE id = p_report_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'report_not_found' USING ERRCODE = 'P0001';
    END IF;
    IF v_report.status NOT IN ('pending', 'reviewed') THEN
        RETURN jsonb_build_object('status', 'already_resolved', 'report_status', v_report.status);
    END IF;

    UPDATE public.reports
       SET claimed_by = COALESCE(claimed_by, p_admin_user_id),
           claimed_at = COALESCE(claimed_at, now()),
           reviewed_at = COALESCE(reviewed_at, now()),
           reviewed_by = COALESCE(reviewed_by, p_admin_user_id),
           status = 'reviewed',
           updated_at = now()
     WHERE id = p_report_id;

    INSERT INTO public.admin_audit_log
        (admin_user_id, action, target_type, target_id, details)
    VALUES
        (p_admin_user_id, 'report_claim', v_report.target_type::text,
         v_report.target_id::text, jsonb_build_object('reportId', p_report_id));

    RETURN jsonb_build_object('status', 'ok', 'report_status', 'reviewed');
END;
$$;

REVOKE ALL ON FUNCTION public.claim_report(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_report(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- moderate_report — extended for the new targets and the reviewed/actioned
-- queue states. Evidence is captured at report time; legacy rows get a
-- best-effort snapshot here before removal.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.moderate_report(
    p_report_id uuid,
    p_action text,
    p_admin_user_id uuid
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_report public.reports%ROWTYPE;
    v_snapshot jsonb;
    v_status public.report_status;
    v_removed boolean := false;
    v_outcome text;
    v_note text;
    v_has_evidence boolean;
BEGIN
    IF p_action NOT IN ('review', 'remove', 'warn', 'dismiss') THEN
        RAISE EXCEPTION 'invalid_action' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_report
      FROM public.reports
     WHERE id = p_report_id
       FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'report_not_found' USING ERRCODE = 'P0001';
    END IF;
    IF v_report.status IN ('actioned', 'dismissed')
       AND p_action IN ('review', 'remove', 'warn', 'dismiss') THEN
        -- Idempotent re-action: keep the recorded outcome, return it.
        RETURN jsonb_build_object(
            'status', 'ok',
            'action', p_action,
            'reportStatus', v_report.status,
            'removed', false,
            'alreadyResolved', true
        );
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.moderation_evidence WHERE report_id = p_report_id
    ) INTO v_has_evidence;

    IF p_action IN ('remove', 'warn', 'dismiss') AND NOT v_has_evidence THEN
        v_snapshot := public.moderation_snapshot(v_report.target_type, v_report.target_id);
        IF v_snapshot IS NOT NULL THEN
            INSERT INTO public.moderation_evidence
                (report_id, target_type, target_id, snapshot, reporter_id, retention_until)
            VALUES
                (p_report_id, v_report.target_type, v_report.target_id, v_snapshot,
                 v_report.reporter_id, now() + interval '2 years');
        END IF;
    END IF;

    IF p_action = 'remove' THEN
        CASE v_report.target_type
            WHEN 'message' THEN
                IF EXISTS (SELECT 1 FROM public.messages WHERE id = v_report.target_id) THEN
                    DELETE FROM public.messages WHERE id = v_report.target_id;
                    v_removed := true;
                END IF;
            WHEN 'photo' THEN
                IF EXISTS (SELECT 1 FROM public.event_photos WHERE id = v_report.target_id) THEN
                    INSERT INTO public.pending_object_deletions (bucket, object_name)
                    SELECT 'events', storage_path
                      FROM public.event_photos
                     WHERE id = v_report.target_id AND storage_path IS NOT NULL;
                    DELETE FROM public.event_photos WHERE id = v_report.target_id;
                    v_removed := true;
                END IF;
            WHEN 'event', 'event_description' THEN
                IF EXISTS (SELECT 1 FROM public.events WHERE id = v_report.target_id) THEN
                    IF v_report.target_type = 'event_description' THEN
                        UPDATE public.events
                           SET description = '[removed]', updated_at = now()
                         WHERE id = v_report.target_id;
                    ELSE
                        UPDATE public.events
                           SET status = 'cancelled',
                               name = '[removed]',
                               description = NULL,
                               cover_url = NULL,
                               location_name = NULL,
                               location_lat = NULL,
                               location_lng = NULL,
                               updated_at = now()
                         WHERE id = v_report.target_id;
                    END IF;
                    v_removed := true;
                END IF;
            WHEN 'user', 'avatar' THEN
                IF EXISTS (SELECT 1 FROM public.users WHERE id = v_report.target_id) THEN
                    IF v_report.target_type = 'avatar' THEN
                        UPDATE public.users SET avatar_url = NULL, updated_at = now()
                         WHERE id = v_report.target_id;
                    ELSE
                        UPDATE public.users
                           SET banned_at = now(),
                               ban_reason = 'report:' || p_report_id::text,
                               avatar_url = NULL,
                               bio = NULL,
                               updated_at = now()
                         WHERE id = v_report.target_id;
                    END IF;
                    v_removed := true;
                END IF;
            WHEN 'group_cover' THEN
                IF EXISTS (SELECT 1 FROM public.groups WHERE id = v_report.target_id) THEN
                    UPDATE public.groups SET cover_url = NULL, updated_at = now()
                     WHERE id = v_report.target_id;
                    v_removed := true;
                END IF;
            WHEN 'minigame_image' THEN
                IF EXISTS (
                    SELECT 1 FROM public.minigame_answers
                     WHERE id = v_report.target_id AND image_storage_path IS NOT NULL
                ) THEN
                    INSERT INTO public.pending_object_deletions (bucket, object_name)
                    SELECT 'minigame_images', image_storage_path
                      FROM public.minigame_answers
                     WHERE id = v_report.target_id AND image_storage_path IS NOT NULL;
                    UPDATE public.minigame_answers
                       SET image_storage_path = NULL
                     WHERE id = v_report.target_id;
                    v_removed := true;
                END IF;
            WHEN 'minigame_answer' THEN
                IF EXISTS (SELECT 1 FROM public.minigame_answers WHERE id = v_report.target_id) THEN
                    INSERT INTO public.pending_object_deletions (bucket, object_name)
                    SELECT 'minigame_images', image_storage_path
                      FROM public.minigame_answers
                     WHERE id = v_report.target_id AND image_storage_path IS NOT NULL;
                    DELETE FROM public.minigame_answers WHERE id = v_report.target_id;
                    v_removed := true;
                END IF;
            ELSE
                v_removed := false;
        END CASE;
    END IF;

    v_status := CASE p_action
        WHEN 'review' THEN 'reviewed'::public.report_status
        WHEN 'dismiss' THEN 'dismissed'::public.report_status
        ELSE 'actioned'::public.report_status
    END;

    v_outcome := CASE p_action
        WHEN 'review' THEN 'reviewed'
        WHEN 'dismiss' THEN 'dismissed'
        WHEN 'warn' THEN 'warned'
        ELSE 'removed'
    END;
    v_note := CASE p_action
        WHEN 'review' THEN 'Report reviewed.'
        WHEN 'dismiss' THEN 'Report reviewed and dismissed.'
        WHEN 'warn' THEN 'Report reviewed; the author was warned.'
        ELSE 'Report reviewed; the content was removed.'
    END;

    UPDATE public.reports
       SET status = v_status,
           reviewed_at = COALESCE(reviewed_at, now()),
           reviewed_by = COALESCE(reviewed_by, p_admin_user_id),
           actioned_at = CASE WHEN p_action IN ('remove', 'warn', 'dismiss')
                              THEN COALESCE(actioned_at, now()) ELSE actioned_at END,
           actioned_by = CASE WHEN p_action IN ('remove', 'warn', 'dismiss')
                              THEN COALESCE(actioned_by, p_admin_user_id) ELSE actioned_by END,
           resolution_note = COALESCE(resolution_note, v_note),
           reporter_outcome = v_outcome,
           reporter_notified_at = CASE WHEN p_action = 'review' THEN reporter_notified_at
                                       ELSE now() END,
           updated_at = now()
     WHERE id = p_report_id;

    IF p_action <> 'review' AND v_report.reporter_id IS NOT NULL THEN
        PERFORM public.insert_notification(
            v_report.reporter_id,
            'report_outcome',
            CASE p_action WHEN 'dismiss' THEN 'Report reviewed' ELSE 'Report actioned' END,
            v_note,
            jsonb_build_object('reportId', p_report_id, 'action', p_action,
                               'category', v_report.category)
        );
    END IF;

    INSERT INTO public.admin_audit_log
        (admin_user_id, action, target_type, target_id, details)
    VALUES (
        p_admin_user_id,
        'report_' || p_action,
        v_report.target_type::text,
        v_report.target_id::text,
        jsonb_build_object(
            'reportId', p_report_id,
            'removed', v_removed,
            'category', v_report.category,
            'priority', v_report.priority
        )
    );

    RETURN jsonb_build_object(
        'status', 'ok',
        'action', p_action,
        'reportStatus', v_status,
        'removed', v_removed
    );
END;
$$;

REVOKE ALL ON FUNCTION public.moderate_report(uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.moderate_report(uuid, text, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Appeals.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_appeal(
    p_report_id uuid,
    p_message text
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_report public.reports%ROWTYPE;
    v_actor uuid;
    v_banned boolean := false;
    v_is_ban boolean := false;
    v_appeal_id uuid;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;
    IF p_message IS NULL OR char_length(btrim(p_message)) < 10
       OR char_length(p_message) > 4000 THEN
        RETURN jsonb_build_object('status', 'invalid_message');
    END IF;

    SELECT banned_at IS NOT NULL INTO v_banned FROM public.users WHERE id = v_me;

    IF p_report_id IS NOT NULL THEN
        SELECT * INTO v_report FROM public.reports WHERE id = p_report_id;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'report_not_found');
        END IF;
        v_actor := public.moderation_target_actor(v_report.target_type, v_report.target_id);
        IF v_me <> v_report.reporter_id AND v_me <> v_actor THEN
            RETURN jsonb_build_object('status', 'not_allowed');
        END IF;
        v_is_ban := v_banned AND v_me = v_actor;
    ELSE
        -- A ban appeal without a linked report is allowed while banned.
        IF NOT v_banned THEN
            RETURN jsonb_build_object('status', 'report_required');
        END IF;
        v_is_ban := true;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.appeals
         WHERE appellant_id = v_me
           AND status IN ('open', 'reviewing')
           AND (report_id IS NOT DISTINCT FROM p_report_id)
    ) THEN
        RETURN jsonb_build_object('status', 'already_open');
    END IF;

    INSERT INTO public.appeals (report_id, appellant_id, message, is_ban_appeal)
    VALUES (p_report_id, v_me, btrim(p_message), v_is_ban)
    RETURNING id INTO v_appeal_id;

    RETURN jsonb_build_object('status', 'ok', 'appeal_id', v_appeal_id);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_appeal(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_appeal(uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.my_appeals()
RETURNS TABLE(
    id uuid,
    report_id uuid,
    message text,
    status text,
    is_ban_appeal boolean,
    decision_note text,
    created_at timestamp with time zone,
    decided_at timestamp with time zone
)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT a.id, a.report_id, a.message, a.status, a.is_ban_appeal,
           a.decision_note, a.created_at, a.decided_at
      FROM public.appeals a
     WHERE a.appellant_id = auth.uid()
     ORDER BY a.created_at DESC
     LIMIT 50;
$$;

CREATE OR REPLACE FUNCTION public.my_report_outcomes()
RETURNS TABLE(
    report_id uuid,
    target_type public.report_target_type,
    category public.report_category,
    status public.report_status,
    reporter_outcome text,
    resolution_note text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT r.id, r.target_type, r.category, r.status, r.reporter_outcome,
           r.resolution_note, r.created_at, r.updated_at
      FROM public.reports r
     WHERE r.reporter_id = auth.uid()
       AND r.status IN ('reviewed', 'actioned', 'dismissed')
     ORDER BY r.updated_at DESC
     LIMIT 50;
$$;

REVOKE ALL ON FUNCTION public.my_appeals() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.my_report_outcomes() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_appeals() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.my_report_outcomes() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.decide_appeal(
    p_appeal_id uuid,
    p_decision text,
    p_note text,
    p_admin_user_id uuid
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_appeal public.appeals%ROWTYPE;
    v_report_id uuid;
    v_target_type public.report_target_type;
    v_target_id uuid;
    v_unbanned boolean := false;
BEGIN
    IF p_decision NOT IN ('upheld', 'overturned', 'closed') THEN
        RAISE EXCEPTION 'invalid_decision' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_appeal FROM public.appeals WHERE id = p_appeal_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'appeal_not_found' USING ERRCODE = 'P0001';
    END IF;
    IF v_appeal.status NOT IN ('open', 'reviewing') THEN
        RETURN jsonb_build_object('status', 'already_decided', 'decision', v_appeal.status);
    END IF;

    IF v_appeal.report_id IS NOT NULL THEN
        SELECT id, target_type, target_id
          INTO v_report_id, v_target_type, v_target_id
          FROM public.reports WHERE id = v_appeal.report_id;
    END IF;

    IF p_decision = 'overturned'
       AND v_appeal.is_ban_appeal
       AND v_appeal.appellant_id IS NOT NULL THEN
        -- An unlinked ban appeal (submitted from the banned screen) has no
        -- report row, but overturning it still lifts the suspension.
        UPDATE public.users
           SET banned_at = NULL,
               ban_reason = NULL,
               updated_at = now()
         WHERE id = v_appeal.appellant_id
           AND banned_at IS NOT NULL;
        v_unbanned := true;

        IF v_report_id IS NOT NULL
           AND v_target_type IN ('user', 'avatar')
           AND v_target_id = v_appeal.appellant_id THEN
            UPDATE public.reports
               SET status = 'dismissed',
                   reporter_outcome = 'appeal_overturned',
                   resolution_note = COALESCE(p_note, 'Ban overturned on appeal.'),
                   updated_at = now()
             WHERE id = v_report_id;
        END IF;
    END IF;

    UPDATE public.appeals
       SET status = p_decision,
           decision_note = p_note,
           decided_by = p_admin_user_id,
           decided_at = now(),
           updated_at = now()
     WHERE id = p_appeal_id;

    IF v_appeal.appellant_id IS NOT NULL THEN
        PERFORM public.insert_notification(
            v_appeal.appellant_id,
            'appeal_outcome',
            CASE p_decision
                WHEN 'overturned' THEN 'Apelación aceptada'
                WHEN 'upheld' THEN 'Apelación rechazada'
                ELSE 'Apelación cerrada'
            END,
            CASE p_decision
                WHEN 'overturned' THEN 'Tu apelación fue aceptada.'
                WHEN 'upheld' THEN 'Tu apelación fue revisada y rechazada.'
                ELSE 'Tu apelación fue cerrada.'
            END,
            jsonb_build_object('appealId', p_appeal_id, 'decision', p_decision)
        );
    END IF;

    INSERT INTO public.admin_audit_log
        (admin_user_id, action, target_type, target_id, details)
    VALUES (
        p_admin_user_id,
        'appeal_' || p_decision,
        'appeal',
        p_appeal_id::text,
        jsonb_build_object(
            'reportId', v_appeal.report_id,
            'appellantId', v_appeal.appellant_id,
            'unbanned', v_unbanned
        )
    );

    RETURN jsonb_build_object(
        'status', 'ok',
        'decision', p_decision,
        'unbanned', v_unbanned
    );
END;
$$;

REVOKE ALL ON FUNCTION public.decide_appeal(uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.decide_appeal(uuid, text, text, uuid) TO service_role;
