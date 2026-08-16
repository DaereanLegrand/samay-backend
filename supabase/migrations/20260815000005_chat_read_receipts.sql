-- =============================================================================
-- 20260815000005 — chat read receipts: messages.read_at + mark_messages_read
-- -----------------------------------------------------------------------------
-- WhatsApp-style message statuses (user request 2026-08-15: 'sent', 'received'
-- and 'read' indicators in the thread):
--
--   1. `messages.read_at` — nullable per-message read timestamp. NULL = not
--      read yet (the sender shows a grey double check), set = the recipient's
--      device has rendered it (blue double check). The sender's device never
--      writes this column; only the RECIPIENT marks messages read — the
--      `mark_messages_read` RPC below is self-scoped to `sender_id <> me`.
--
--   2. `mark_messages_read(p_chat_id)` — SECURITY DEFINER, self-only write
--      path (same pattern as `mark_chat_read`, migration 20260815000004):
--      stamps `read_at = now()` on every unread message FROM THE CALLER'S
--      PEER in the chat. Realtime UPDATEs (messages is in supabase_realtime,
--      20260809000003) deliver the flip to the sender's open thread, so blue
--      checks appear live.
--
--   3. `users.read_receipts_enabled` — per-account privacy switch (WhatsApp's
--      "read receipts" setting). The client reads its OWN row before calling
--      mark_messages_read; when OFF, no read_at is ever stamped and the peer
--      never sees blue checks. Written via the existing `users_update_own`
--      RLS policy (same seam as `discovery_opt_in`, 20260809000004) — no new
--      update surface.
--
-- E2EE invariant: the INSERT/decrypt paths are untouched. `read_at` defaults
-- NULL and is never part of the envelope; `mark_messages_read` updates only
-- the `read_at` column of rows the caller did not send (content / envelope
-- bytes are never rewritten).
-- =============================================================================

ALTER TABLE public.messages
    ADD COLUMN IF NOT EXISTS read_at timestamptz;

ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS read_receipts_enabled boolean NOT NULL DEFAULT true;

-- ============================================================
-- 1. mark_messages_read(p_chat_id) — SECURITY DEFINER, self-only
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_messages_read(p_chat_id uuid)
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
    UPDATE public.messages
    SET read_at = now()
    WHERE chat_id = p_chat_id
      AND sender_id <> v_me
      AND read_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_messages_read(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_messages_read(uuid) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.mark_messages_read(uuid) TO authenticated;
