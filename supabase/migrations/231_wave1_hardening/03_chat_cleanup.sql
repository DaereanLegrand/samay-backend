-- ============================================================================
-- 231_wave1_hardening / 03_chat_cleanup.sql — SEC-015
--
-- delete_undecryptable_messages() allowed ANY chat participant to delete ANY
-- message id in the chat. The cleanup path is now sender-scoped:
--   * the caller must still be a confirmed member of the chat;
--   * only rows whose sender_id = auth.uid() are deleted;
--   * a single call is capped at 50 ids (4xx on a larger batch);
--   * every deleted row keeps its immutable deleted_messages audit row.
--
-- deleted_messages direct client writes are revoked as defense in depth (RLS
-- already denied them; the table now has no client DML grant either).
--
-- Rollback: restore the 080_chat/03_messaging.sql function body and re-grant
-- ALL on deleted_messages/deleted_messages_id_seq to anon + authenticated.
-- Forward-fix: replace the function; never widen the sender predicate.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.delete_undecryptable_messages(
    p_chat_id uuid,
    p_message_ids uuid[]
) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_deleted integer := 0;
BEGIN
    IF v_me IS NULL THEN
        RAISE EXCEPTION 'Not authorized';
    END IF;

    IF p_chat_id IS NULL OR p_message_ids IS NULL THEN
        RETURN 0;
    END IF;
    IF COALESCE(array_length(p_message_ids, 1), 0) > 50 THEN
        RAISE EXCEPTION 'BATCH_TOO_LARGE' USING ERRCODE = 'P0001';
    END IF;

    -- Participant gate with confirmed membership (SEC-018 alignment).
    IF NOT EXISTS (
        SELECT 1 FROM public.chats
        WHERE id = p_chat_id AND (
            (type = 'direct' AND EXISTS (
                SELECT 1 FROM public.chat_participants
                WHERE chat_id = p_chat_id AND user_id = v_me
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
        RAISE EXCEPTION 'NOT_A_PARTICIPANT';
    END IF;

    WITH deleted AS (
        DELETE FROM public.messages
         WHERE chat_id = p_chat_id
           AND id = ANY (p_message_ids)
           AND sender_id = v_me
        RETURNING id, chat_id
    )
    INSERT INTO public.deleted_messages (message_id, chat_id, deleted_by, reason)
    SELECT id, chat_id, v_me, 'undecryptable_cleanup' FROM deleted;

    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_undecryptable_messages(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_undecryptable_messages(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_undecryptable_messages(uuid, uuid[]) TO service_role;

REVOKE ALL ON TABLE public.deleted_messages FROM anon;
REVOKE ALL ON TABLE public.deleted_messages FROM authenticated;
GRANT ALL ON TABLE public.deleted_messages TO service_role;

REVOKE ALL ON SEQUENCE public.deleted_messages_id_seq FROM anon;
REVOKE ALL ON SEQUENCE public.deleted_messages_id_seq FROM authenticated;
GRANT ALL ON SEQUENCE public.deleted_messages_id_seq TO service_role;
