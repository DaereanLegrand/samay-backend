-- =============================================================================
-- 20260815000004 — chat inbox: last_read_at + get_chat_inbox / mark_chat_read
-- -----------------------------------------------------------------------------
-- Unread-message support (user request 2026-08-15: chat button on the feed
-- with a badge signaling unread messages):
--
--   1. `chat_participants.last_read_at` — per-user read watermark per chat
--      (DEFAULT now() → existing participants start "read", not flooded).
--   2. `get_chat_inbox()` — the inbox for the caller: every chat they
--      participate in, with peer identity (via `user_search_view` — block
--      exclusion + deleted_at filter intact), the last message (content is
--      the E2EE envelope — the server never sees plaintext; the client
--      decrypts for the preview) and the unread count (messages from others
--      newer than the watermark). Access is inherently caller-scoped: the
--      chat_participants join only yields the caller's chats.
--   3. `mark_chat_read(p_chat_id)` — bumps the caller's own watermark
--      (no UPDATE policy exists on chat_participants; an RPC is the clean
--      self-only write path, create_direct_chat pattern).
--
-- No read-receipts semantics: this is a local watermark per participant.
-- Symmetric by construction — each side reads/writes its own row.
-- =============================================================================

ALTER TABLE public.chat_participants
    ADD COLUMN IF NOT EXISTS last_read_at timestamptz NOT NULL DEFAULT now();

-- ============================================================
-- 1. get_chat_inbox() — SECURITY DEFINER, caller-scoped
-- ============================================================
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
        usv.id,
        usv.username,
        usv.avatar_url,
        lm.id,
        lm.sender_id,
        lm.content,
        lm.created_at,
        (SELECT count(*) FROM public.messages m
          WHERE m.chat_id = c.id
            AND m.sender_id <> v_me
            AND m.created_at > cp.last_read_at)
    FROM public.chats c
    JOIN public.chat_participants cp
      ON cp.chat_id = c.id AND cp.user_id = v_me
    LEFT JOIN public.user_search_view usv
      ON usv.id = (
          SELECT cp2.user_id FROM public.chat_participants cp2
          WHERE cp2.chat_id = c.id AND cp2.user_id <> v_me
          LIMIT 1
      )
    LEFT JOIN LATERAL (
        SELECT messages.id, messages.sender_id, messages.content,
               messages.created_at
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

-- ============================================================
-- 2. mark_chat_read(p_chat_id) — SECURITY DEFINER, self-only
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_chat_read(p_chat_id uuid)
RETURNS void
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
    IF NOT EXISTS (
        SELECT 1 FROM public.chat_participants
        WHERE chat_id = p_chat_id AND user_id = v_me
    ) THEN
        RAISE EXCEPTION 'Not a participant';
    END IF;
    UPDATE public.chat_participants
    SET last_read_at = now()
    WHERE chat_id = p_chat_id AND user_id = v_me;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_chat_read(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_chat_read(uuid) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.mark_chat_read(uuid) TO authenticated;
