-- ============================================================================
-- 231_wave1_hardening / 02_membership_status.sql — SEC-018
--
-- Social access policies must require a CONFIRMED relationship:
--   * event chat/message/read-receipt: event_invites.status IN
--     ('accepted','attended') (pending/declined invitees are not members);
--   * group/group-chat/group-data: group_members.status = 'active' (invited
--     or removed rows are not members).
--
-- report_message() had the same ANY-status event branch and is replaced.
-- Policy names stay stable. Hosts/staff remain members of their event chat.
--
-- Rollback: restore the 2026-08 policy definitions from
-- 080_chat/01_tables.sql, 050_groups/01_tables.sql and
-- 226_chat_moderation/report_block.sql. Forward-fix: replace only the
-- policies below; never reintroduce an ANY-status branch.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Event chat read: pending invitees no longer read the event chat.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS chats_read_participant ON public.chats;
CREATE POLICY chats_read_participant ON public.chats
    FOR SELECT
    USING (
        (
            type = 'direct'::public.chat_type
            AND EXISTS (
                SELECT 1 FROM public.chat_participants
                 WHERE chat_participants.chat_id = chats.id
                   AND chat_participants.user_id = auth.uid()
            )
        )
        OR (
            type = 'group'::public.chat_type
            AND EXISTS (
                SELECT 1 FROM public.group_members gm
                 WHERE gm.group_id = chats.reference_id
                   AND gm.user_id = auth.uid()
                   AND gm.status = 'active'
            )
        )
        OR (
            type = 'event'::public.chat_type
            AND (
                EXISTS (
                    SELECT 1 FROM public.event_invites ei
                     WHERE ei.event_id = chats.reference_id
                       AND ei.user_id = auth.uid()
                       AND ei.status IN ('accepted', 'attended')
                )
                OR EXISTS (
                    SELECT 1 FROM public.event_hosts eh
                     WHERE eh.event_id = chats.reference_id
                       AND eh.user_id = auth.uid()
                )
                OR EXISTS (
                    SELECT 1
                      FROM public.group_members gm
                      JOIN public.events e ON e.group_id = gm.group_id
                     WHERE e.id = chats.reference_id
                       AND gm.user_id = auth.uid()
                       AND gm.status = 'active'
                )
            )
        )
    );

-- ---------------------------------------------------------------------------
-- Message write: event branch requires accepted/attended.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS messages_insert_participant ON public.messages;
CREATE POLICY messages_insert_participant ON public.messages
    FOR INSERT
    WITH CHECK (
        sender_id = auth.uid()
        AND EXISTS (
            SELECT 1 FROM public.chats c
             WHERE c.id = messages.chat_id
               AND (
                   (
                       c.type = 'direct'::public.chat_type
                       AND EXISTS (
                           SELECT 1 FROM public.chat_participants cp
                            WHERE cp.chat_id = c.id
                              AND cp.user_id = auth.uid()
                       )
                   )
                   OR (
                       c.type = 'group'::public.chat_type
                       AND EXISTS (
                           SELECT 1 FROM public.group_members gm
                            WHERE gm.group_id = c.reference_id
                              AND gm.user_id = auth.uid()
                              AND gm.status = 'active'
                       )
                   )
                   OR (
                       c.type = 'event'::public.chat_type
                       AND (
                           EXISTS (
                               SELECT 1 FROM public.event_invites ei
                                WHERE ei.event_id = c.reference_id
                                  AND ei.user_id = auth.uid()
                                  AND ei.status IN ('accepted', 'attended')
                           )
                           OR EXISTS (
                               SELECT 1 FROM public.event_hosts eh
                                WHERE eh.event_id = c.reference_id
                                  AND eh.user_id = auth.uid()
                           )
                       )
                   )
               )
        )
    );

-- ---------------------------------------------------------------------------
-- Message read: event branch requires accepted/attended.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS messages_read_participant ON public.messages;
CREATE POLICY messages_read_participant ON public.messages
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.chats c
             WHERE c.id = messages.chat_id
               AND (
                   (
                       c.type = 'direct'::public.chat_type
                       AND EXISTS (
                           SELECT 1 FROM public.chat_participants cp
                            WHERE cp.chat_id = c.id
                              AND cp.user_id = auth.uid()
                       )
                   )
                   OR (
                       c.type = 'group'::public.chat_type
                       AND EXISTS (
                           SELECT 1 FROM public.group_members gm
                            WHERE gm.group_id = c.reference_id
                              AND gm.user_id = auth.uid()
                              AND gm.status = 'active'
                       )
                   )
                   OR (
                       c.type = 'event'::public.chat_type
                       AND (
                           EXISTS (
                               SELECT 1 FROM public.event_invites ei
                                WHERE ei.event_id = c.reference_id
                                  AND ei.user_id = auth.uid()
                                  AND ei.status IN ('accepted', 'attended')
                           )
                           OR EXISTS (
                               SELECT 1 FROM public.event_hosts eh
                                WHERE eh.event_id = c.reference_id
                                  AND eh.user_id = auth.uid()
                           )
                       )
                   )
               )
        )
    );

-- ---------------------------------------------------------------------------
-- Read receipts (insert + select): same membership predicates.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS message_reads_insert_own ON public.message_reads;
CREATE POLICY message_reads_insert_own ON public.message_reads
    FOR INSERT
    WITH CHECK (
        user_id = auth.uid()
        AND EXISTS (
            SELECT 1
              FROM public.messages m
              JOIN public.chats c ON c.id = m.chat_id
             WHERE m.id = message_reads.message_id
               AND m.sender_id <> auth.uid()
               AND (
                   (
                       c.type = 'direct'::public.chat_type
                       AND EXISTS (
                           SELECT 1 FROM public.chat_participants cp
                            WHERE cp.chat_id = c.id
                              AND cp.user_id = auth.uid()
                       )
                   )
                   OR (
                       c.type = 'group'::public.chat_type
                       AND EXISTS (
                           SELECT 1 FROM public.group_members gm
                            WHERE gm.group_id = c.reference_id
                              AND gm.user_id = auth.uid()
                              AND gm.status = 'active'
                       )
                   )
                   OR (
                       c.type = 'event'::public.chat_type
                       AND (
                           EXISTS (
                               SELECT 1 FROM public.event_invites ei
                                WHERE ei.event_id = c.reference_id
                                  AND ei.user_id = auth.uid()
                                  AND ei.status IN ('accepted', 'attended')
                           )
                           OR EXISTS (
                               SELECT 1 FROM public.event_hosts eh
                                WHERE eh.event_id = c.reference_id
                                  AND eh.user_id = auth.uid()
                           )
                       )
                   )
               )
        )
    );

DROP POLICY IF EXISTS message_reads_select_participant ON public.message_reads;
CREATE POLICY message_reads_select_participant ON public.message_reads
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
              FROM public.messages m
              JOIN public.chats c ON c.id = m.chat_id
             WHERE m.id = message_reads.message_id
               AND (
                   (
                       c.type = 'direct'::public.chat_type
                       AND EXISTS (
                           SELECT 1 FROM public.chat_participants cp
                            WHERE cp.chat_id = c.id
                              AND cp.user_id = auth.uid()
                       )
                   )
                   OR (
                       c.type = 'group'::public.chat_type
                       AND EXISTS (
                           SELECT 1 FROM public.group_members gm
                            WHERE gm.group_id = c.reference_id
                              AND gm.user_id = auth.uid()
                              AND gm.status = 'active'
                       )
                   )
                   OR (
                       c.type = 'event'::public.chat_type
                       AND (
                           EXISTS (
                               SELECT 1 FROM public.event_invites ei
                                WHERE ei.event_id = c.reference_id
                                  AND ei.user_id = auth.uid()
                                  AND ei.status IN ('accepted', 'attended')
                           )
                           OR EXISTS (
                               SELECT 1 FROM public.event_hosts eh
                                WHERE eh.event_id = c.reference_id
                                  AND eh.user_id = auth.uid()
                           )
                       )
                   )
               )
        )
    );

-- ---------------------------------------------------------------------------
-- Group read/update/contribution + membership management require active rows.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS groups_read_member ON public.groups;
CREATE POLICY groups_read_member ON public.groups
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.group_members gm
             WHERE gm.group_id = groups.id
               AND gm.user_id = auth.uid()
               AND gm.status = 'active'
        )
    );

DROP POLICY IF EXISTS groups_update_host ON public.groups;
CREATE POLICY groups_update_host ON public.groups
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM public.group_members gm
             WHERE gm.group_id = groups.id
               AND gm.user_id = auth.uid()
               AND gm.status = 'active'
               AND gm.role IN ('host'::public.group_role, 'staff'::public.group_role)
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.group_members gm
             WHERE gm.group_id = groups.id
               AND gm.user_id = auth.uid()
               AND gm.status = 'active'
               AND gm.role IN ('host'::public.group_role, 'staff'::public.group_role)
        )
    );

DROP POLICY IF EXISTS gsc_read_member ON public.group_shard_contributions;
CREATE POLICY gsc_read_member ON public.group_shard_contributions
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.group_members gm
             WHERE gm.group_id = group_shard_contributions.group_id
               AND gm.user_id = auth.uid()
               AND gm.status = 'active'
        )
    );

DROP POLICY IF EXISTS group_members_insert_host ON public.group_members;
CREATE POLICY group_members_insert_host ON public.group_members
    FOR INSERT
    WITH CHECK (
        (
            role = 'member'::public.group_role
            AND status IN ('active', 'invited')
            AND EXISTS (
                SELECT 1 FROM public.group_members gm2
                 WHERE gm2.group_id = group_members.group_id
                   AND gm2.user_id = auth.uid()
                   AND gm2.status = 'active'
                   AND gm2.role IN ('host'::public.group_role, 'staff'::public.group_role)
            )
        )
        OR (
            user_id = auth.uid()
            AND EXISTS (
                SELECT 1 FROM public.groups g
                 WHERE g.id = group_members.group_id
                   AND g.created_by_user_id = auth.uid()
            )
        )
    );

DROP POLICY IF EXISTS group_members_delete_host ON public.group_members;
CREATE POLICY group_members_delete_host ON public.group_members
    FOR DELETE
    USING (
        EXISTS (
            SELECT 1 FROM public.group_members gm2
             WHERE gm2.group_id = group_members.group_id
               AND gm2.user_id = auth.uid()
               AND gm2.status = 'active'
               AND (
                   gm2.role = 'host'::public.group_role
                   OR (
                       gm2.role = 'staff'::public.group_role
                       AND group_members.role <> 'host'::public.group_role
                   )
               )
        )
    );

DROP POLICY IF EXISTS group_members_update_host ON public.group_members;
CREATE POLICY group_members_update_host ON public.group_members
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM public.group_members gm2
             WHERE gm2.group_id = group_members.group_id
               AND gm2.user_id = auth.uid()
               AND gm2.status = 'active'
               AND gm2.role IN ('host'::public.group_role, 'staff'::public.group_role)
               AND (
                   gm2.role = 'host'::public.group_role
                   OR group_members.role <> 'host'::public.group_role
               )
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.group_members gm2
             WHERE gm2.group_id = group_members.group_id
               AND gm2.user_id = auth.uid()
               AND gm2.status = 'active'
               AND (
                   gm2.role = 'host'::public.group_role
                   OR (
                       gm2.role = 'staff'::public.group_role
                       AND group_members.role IN ('member'::public.group_role, 'staff'::public.group_role)
                   )
               )
        )
    );

-- ---------------------------------------------------------------------------
-- report_message(): event branch requires accepted/attended.
-- Body otherwise identical to 226_chat_moderation/report_block.sql.
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
    v_report_id uuid;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    v_reason := COALESCE(NULLIF(btrim(p_reason), ''), 'other');

    SELECT chat_id, sender_id, media_url
      INTO v_chat_id, v_sender_id, v_media_url
      FROM public.messages
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

    INSERT INTO public.reports (reporter_id, target_type, target_id, reason, status)
    VALUES (v_me, 'message', p_message_id, v_reason, 'pending')
    RETURNING id INTO v_report_id;

    INSERT INTO public.message_reports (
        report_id, message_id, chat_id, sender_id, reporter_id, reason,
        plaintext, media_url
    ) VALUES (
        v_report_id, p_message_id, v_chat_id, v_sender_id, v_me, v_reason,
        p_plaintext, v_media_url
    );

    UPDATE public.messages SET reported = true WHERE id = p_message_id;

    RETURN jsonb_build_object('status', 'ok', 'report_id', v_report_id);
END;
$$;

REVOKE ALL ON FUNCTION public.report_message(uuid, text, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.report_message(uuid, text, text) TO authenticated;
GRANT ALL ON FUNCTION public.report_message(uuid, text, text) TO service_role;
