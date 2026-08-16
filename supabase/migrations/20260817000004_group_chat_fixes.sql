-- =============================================================================
-- 20260817000004 — Group chat fix round (ISSUE 4 / F5, F6, F7)
-- -----------------------------------------------------------------------------
-- Verification-round gaps closed against the D1/D3 group-chat DB layer:
--
--   F5. get_chat_inbox() now carries `last_message_recipient_id` (the last
--       message's recipient_id): the inbox preview path (ChatService
--       decryptInboxRow) can then skip sender-key DISTRIBUTION rows addressed
--       to another member WITHOUT attempting decryption. Before this fix the
--       preview row carried no recipient_id, so every member tried to decrypt
--       the bundle envelope (non-targets: AEAD failure, hidden; the target
--       processed the bundle a second time when the thread loaded).
--
--   F6. accept_friend_request(p_friendship_id) — SECURITY DEFINER RPC: the
--       ADDressee of a pending request accepts it. The previous direct UPDATE
--       was client-guarded only: friendships_update_own covers requester OR
--       addressee, so the REQUESTER could flip an outbound pending row to
--       'accepted' without the addressee's consent.
--
--   F7. enforce_message_cap() rolling-window DELETE now skips rows with
--       recipient_id IS NOT NULL — sender-key distribution rows are control
--       rows, not chat content; a burst of distribution rows must not evict
--       real chat history. All other trigger behavior is preserved exactly.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- F5. get_chat_inbox: last_message_recipient_id rides along
-- -----------------------------------------------------------------------------
-- The RETURNS TABLE gains a column — Postgres forbids changing OUT parameters
-- via CREATE OR REPLACE, so the function is dropped first (grants are
-- re-issued below; nothing depends on the old signature).
DROP FUNCTION IF EXISTS public.get_chat_inbox();
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
        ORDER BY messages.created_at DESC
        LIMIT 1
    ) lm ON TRUE
    ORDER BY lm.created_at DESC NULLS LAST, c.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_chat_inbox() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_chat_inbox() FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_chat_inbox() TO authenticated;

-- -----------------------------------------------------------------------------
-- F7. enforce_message_cap: distribution rows are exempt from the rolling
-- window (recipient_id IS NOT NULL → control row, never pruned). The count,
-- the app_config fallback and every other behavior are unchanged.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_message_cap()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    chat_limit integer;
    msg_count integer;
BEGIN
    SELECT COALESCE(
        (SELECT value::integer FROM public.app_config WHERE key = 'chat.message_cap'),
        1000
    ) INTO chat_limit;

    SELECT COUNT(*) INTO msg_count FROM public.messages WHERE chat_id = NEW.chat_id;

    IF msg_count > chat_limit THEN
        DELETE FROM public.messages WHERE id IN (
            SELECT id FROM public.messages
            WHERE chat_id = NEW.chat_id
              AND recipient_id IS NULL
            ORDER BY created_at ASC
            LIMIT (msg_count - chat_limit)
        );
    END IF;

    RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- F6. accept_friend_request: addressee-only, pending-only acceptance
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.accept_friend_request(p_friendship_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_me uuid := auth.uid();
    v_status text;
BEGIN
    IF v_me IS NULL THEN
        RAISE EXCEPTION 'Not authorized';
    END IF;

    SELECT status INTO v_status
      FROM public.friendships
     WHERE id = p_friendship_id
       AND addressee_id = v_me;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NOT_THE_ADDRESSEE';
    END IF;
    IF v_status <> 'pending' THEN
        RAISE EXCEPTION 'NOT_PENDING';
    END IF;

    UPDATE public.friendships
       SET status = 'accepted'
     WHERE id = p_friendship_id
       AND addressee_id = v_me
       AND status = 'pending';
END;
$$;

REVOKE ALL ON FUNCTION public.accept_friend_request(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.accept_friend_request(uuid) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.accept_friend_request(uuid) TO authenticated;
