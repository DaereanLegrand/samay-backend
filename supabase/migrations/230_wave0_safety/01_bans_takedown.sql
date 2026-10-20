-- ============================================================================
-- 230_wave0_safety — Wave 0 ban enforcement and report takedown.
--
-- SEC-008: banned/deleted users are denied at the table boundary (restrictive
--          RLS) and at the write boundary (BEFORE trigger). This covers direct
--          PostgREST writes and SECURITY DEFINER RPC writes because the trigger
--          reads the caller's auth.uid().
-- SEC-009: moderate_report() snapshots the target, removes it, queues storage
--          cleanup where possible, notifies the reporter, and audits the
--          moderator. The Go admin API calls it instead of only PATCHing the
--          report status.
--
-- Local/testing only. Staging remains frozen.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- SEC-008 — active-user predicate.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_active_user(p_user_id uuid)
RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT EXISTS (
        SELECT 1
          FROM public.users
         WHERE id = p_user_id
           AND banned_at IS NULL
           AND deleted_at IS NULL
    );
$$;

REVOKE ALL ON FUNCTION public.is_active_user(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_active_user(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_active_user(uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.is_active_user(uuid) FROM anon;

CREATE OR REPLACE FUNCTION public.assert_active_actor()
RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    IF auth.uid() IS NOT NULL AND NOT public.is_active_user(auth.uid()) THEN
        RAISE EXCEPTION 'account_inactive' USING ERRCODE = 'P0001';
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

REVOKE ALL ON FUNCTION public.assert_active_actor() FROM PUBLIC;

DO $$
DECLARE
    t text;
    tables text[] := ARRAY[
        'chats',
        'chat_participants',
        'messages',
        'message_reads',
        'event_attendances',
        'event_invites',
        'event_hosts',
        'events',
        'event_photos',
        'event_photo_likes',
        'friendships',
        'groups',
        'group_members',
        'group_shard_contributions',
        'user_cosmetics',
        'shard_ledger',
        'preshard_ledger',
        'notifications',
        'device_tokens',
        'reports',
        'minigame_sessions',
        'minigame_game_state',
        'minigame_invites',
        'minigame_answers',
        'minigame_reactions',
        'minigame_results',
        'minigame_aliases',
        'minigame_e2ee_bundles'
    ];
BEGIN
    FOREACH t IN ARRAY tables LOOP
        EXECUTE format('DROP POLICY IF EXISTS active_users_only ON public.%I', t);
        EXECUTE format(
            'CREATE POLICY active_users_only ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING (public.is_active_user(auth.uid())) WITH CHECK (public.is_active_user(auth.uid()))',
            t
        );

        EXECUTE format('DROP TRIGGER IF EXISTS active_actor_guard ON public.%I', t);
        EXECUTE format(
            'CREATE TRIGGER active_actor_guard BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.assert_active_actor()',
            t
        );
    END LOOP;
END
$$;

-- ----------------------------------------------------------------------------
-- SEC-009 — report evidence + target-specific removal.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.moderation_evidence (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    report_id uuid REFERENCES public.reports(id) ON DELETE SET NULL,
    target_type public.report_target_type NOT NULL,
    target_id uuid NOT NULL,
    snapshot jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.moderation_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.moderation_evidence FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.moderation_evidence FROM anon;
REVOKE ALL ON TABLE public.moderation_evidence FROM authenticated;
GRANT ALL ON TABLE public.moderation_evidence TO service_role;

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
BEGIN
    IF p_action NOT IN ('remove', 'warn', 'dismiss') THEN
        RAISE EXCEPTION 'invalid_action' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_report
      FROM public.reports
     WHERE id = p_report_id
       FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'report_not_found' USING ERRCODE = 'P0001';
    END IF;

    IF p_action = 'remove' THEN
        IF v_report.target_type = 'message' THEN
            SELECT to_jsonb(m) INTO v_snapshot
              FROM public.messages m
             WHERE m.id = v_report.target_id;
            IF v_snapshot IS NOT NULL THEN
                INSERT INTO public.moderation_evidence
                    (report_id, target_type, target_id, snapshot)
                VALUES (p_report_id, v_report.target_type, v_report.target_id, v_snapshot);
                DELETE FROM public.messages WHERE id = v_report.target_id;
                v_removed := true;
            END IF;
        ELSIF v_report.target_type = 'photo' THEN
            SELECT to_jsonb(p) INTO v_snapshot
              FROM public.event_photos p
             WHERE p.id = v_report.target_id;
            IF v_snapshot IS NOT NULL THEN
                INSERT INTO public.moderation_evidence
                    (report_id, target_type, target_id, snapshot)
                VALUES (p_report_id, v_report.target_type, v_report.target_id, v_snapshot);
                INSERT INTO public.pending_object_deletions (bucket, object_name)
                SELECT 'events', storage_path
                  FROM public.event_photos
                 WHERE id = v_report.target_id;
                DELETE FROM public.event_photos WHERE id = v_report.target_id;
                v_removed := true;
            END IF;
        ELSIF v_report.target_type = 'event' THEN
            SELECT to_jsonb(e) INTO v_snapshot
              FROM public.events e
             WHERE e.id = v_report.target_id;
            IF v_snapshot IS NOT NULL THEN
                INSERT INTO public.moderation_evidence
                    (report_id, target_type, target_id, snapshot)
                VALUES (p_report_id, v_report.target_type, v_report.target_id, v_snapshot);
                UPDATE public.events
                   SET status = 'cancelled',
                       name = '[removed]',
                       description = NULL,
                       cover_url = NULL,
                       location_name = NULL,
                       location_lat = NULL,
                       location_lng = NULL
                 WHERE id = v_report.target_id;
                v_removed := true;
            END IF;
        ELSIF v_report.target_type = 'user' THEN
            SELECT to_jsonb(u) INTO v_snapshot
              FROM public.users u
             WHERE u.id = v_report.target_id;
            IF v_snapshot IS NOT NULL THEN
                INSERT INTO public.moderation_evidence
                    (report_id, target_type, target_id, snapshot)
                VALUES (p_report_id, v_report.target_type, v_report.target_id, v_snapshot);
                UPDATE public.users
                   SET banned_at = now(),
                       ban_reason = 'report:' || p_report_id::text,
                       avatar_url = NULL,
                       bio = NULL
                 WHERE id = v_report.target_id;
                v_removed := true;
            END IF;
        END IF;
    END IF;

    v_status := CASE p_action
        WHEN 'dismiss' THEN 'dismissed'::public.report_status
        ELSE 'actioned'::public.report_status
    END;

    UPDATE public.reports
       SET status = v_status
     WHERE id = p_report_id;

    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
        v_report.reporter_id,
        'report_outcome',
        CASE p_action WHEN 'dismiss' THEN 'Report reviewed' ELSE 'Report actioned' END,
        CASE p_action
            WHEN 'dismiss' THEN 'Your report was reviewed and dismissed.'
            ELSE 'Your report was reviewed and the content was removed.'
        END,
        jsonb_build_object('reportId', p_report_id, 'action', p_action)
    );

    INSERT INTO public.admin_audit_log
        (admin_user_id, action, target_type, target_id, details)
    VALUES (
        p_admin_user_id,
        'report_' || p_action,
        v_report.target_type::text,
        v_report.target_id::text,
        jsonb_build_object('reportId', p_report_id, 'removed', v_removed)
    );

    RETURN jsonb_build_object(
        'status', 'ok',
        'action', p_action,
        'reportStatus', v_status,
        'removed', v_removed
    );
END;
$$;

REVOKE ALL ON FUNCTION public.moderate_report(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.moderate_report(uuid, text, uuid) TO service_role;
