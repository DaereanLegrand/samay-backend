-- =============================================================================
-- 20260818000001 — Fix inbox unread_count + preview for control rows (A-inbox)
-- -----------------------------------------------------------------------------
-- get_chat_inbox() counted EVERY row from others newer than the read watermark
-- toward `unread_count` — including group-chat SENDER-KEY DISTRIBUTION rows and
-- KEY-REQUEST rows (recipient_id IS NOT NULL). The E2EE client inserts these
-- control rows with NO user-visible message (key distribution, roster-change
-- rekey, key-request retries), so they inflated the home-screen badge. These
-- rows are the same class F7 exempts from the message-cap rolling window
-- (20260817000004 enforce_message_cap skips recipient_id IS NOT NULL); the
-- inbox count was NOT given the same exemption — that was the bug.
--
--   • unread_count: adds `AND m.recipient_id IS NULL` — only real content
--     rows from others newer than the watermark count toward the badge.
--   • last-message preview: the LEFT JOIN LATERAL now filters
--     `messages.recipient_id IS NULL`, so the inbox preview is the last REAL
--     content message, not a distribution envelope (a control envelope as
--     preview was meaningless/undecryptable for non-targets).
--
-- Signature / RETURNS TABLE unchanged → CREATE OR REPLACE suffices (no DROP;
-- OUT params are identical to 20260817000004's). Grants re-issued below.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_chat_inbox()
RETURNS TABLE (
    chat_id uuid,
    type public.chat_type,
    reference_id uuid,
    peer_id uuid,
    peer_username text,
    peer_avatar_url text,
    last_message_id uuid,
    last_message_sender_id uuid,
    last_message_recipient_id uuid,
    last_message_content text,
    last_message_created_at timestamptz,
    unread_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_me uuid := auth.uid();
BEGIN
    IF v_me IS NULL THEN
        RAISE EXCEPTION 'Not authorized';
    END IF;

    RETURN QUERY
    SELECT
        c.id,
        c.type,
        c.reference_id,
        CASE WHEN c.type = 'group' THEN NULL ELSE usv.id END,
        CASE WHEN c.type = 'group' THEN g.name ELSE usv.username END,
        CASE WHEN c.type = 'group' THEN g.cover_url ELSE usv.avatar_url END,
        lm.id,
        lm.sender_id,
        lm.recipient_id,
        lm.content,
        lm.created_at,
        (SELECT count(*) FROM public.messages m
          WHERE m.chat_id = c.id
            AND m.sender_id <> v_me
            AND m.recipient_id IS NULL
            AND m.created_at > cp.last_read_at)
    FROM public.chats c
    JOIN public.chat_participants cp
      ON cp.chat_id = c.id AND cp.user_id = v_me
    LEFT JOIN public.groups g
      ON c.type = 'group' AND g.id = c.reference_id
    LEFT JOIN public.user_search_view usv
      ON usv.id = (
          SELECT cp2.user_id FROM public.chat_participants cp2
          WHERE cp2.chat_id = c.id AND cp2.user_id <> v_me
          LIMIT 1
      )
    LEFT JOIN LATERAL (
        SELECT messages.id, messages.sender_id, messages.recipient_id,
               messages.content, messages.created_at
        FROM public.messages
        WHERE messages.chat_id = c.id
          AND messages.recipient_id IS NULL
        ORDER BY messages.created_at DESC
        LIMIT 1
    ) lm ON TRUE
    ORDER BY lm.created_at DESC NULLS LAST, c.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_chat_inbox() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_chat_inbox() FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_chat_inbox() TO authenticated;