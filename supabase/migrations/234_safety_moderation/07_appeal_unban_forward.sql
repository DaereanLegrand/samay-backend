-- 234_safety_moderation / 07_appeal_unban_forward.sql
--
-- Forward fix: an unlinked ban appeal (banned screen) must unban on
-- overturn. 03 is already applied on existing stacks; this re-runs the
-- corrected function idempotently.
-- ====================================================================

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
