-- =============================================================================
-- 20260817000006 — group read receipts: per-member message_reads
-- -----------------------------------------------------------------------------
-- ISSUE (2026-08-17 user report): in a GROUP chat the sender sees BLUE double
-- checks although not all members have read the message — the 1:1 read_at
-- column (20260815000005) cannot express per-member reads: ANY member reading
-- the chat stamps read_at on every message from every other sender, so the
-- first reader makes every sender's message look read-by-everyone.
--
-- Fix — WhatsApp-style per-member read tracking for group chats:
--
--   1. `message_reads` — (message_id, user_id) rows, one per (message,
--      reader): the read receipt. A message is "read by N" = COUNT(*) over
--      its message_reads rows (readers are other members only — the RPC below
--      never marks own messages). FK ON DELETE CASCADE keeps the table in
--      sync with delete-for-everyone / the message-cap rolling window.
--      RLS: own-row INSERT gated on the message's chat participation
--      (defense in depth — the RPC is the primary write path); SELECT for
--      every participant of the message's chat (WhatsApp shows who read
--      what). FORCE RLS per the I-31 posture. No UPDATE/DELETE policies —
--      a receipt is immutable once written.
--
--   2. `mark_group_messages_read(p_chat_id)` — SECURITY DEFINER, the group
--      analogue of mark_messages_read (20260815000005): inserts a
--      message_reads row for the caller on every message in the chat that is
--      NOT theirs and NOT a sender-key distribution row (recipient_id IS
--      NULL — control rows are never "read"). Idempotent (ON CONFLICT DO
--      NOTHING). The 1:1 path keeps mark_messages_read/messages.read_at
--      byte-identical; the client calls the right RPC per chat type.
--
-- E2EE invariant: read tracking is metadata (message_id, user_id, read_at) —
-- it never touches messages.content or any envelope bytes.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.message_reads (
    message_id uuid NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
    user_id    uuid NOT NULL,
    read_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (message_id, user_id)
);

ALTER TABLE public.message_reads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_reads FORCE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- message_reads_insert_own — own-row inserts only, gated on the message's
-- chat participation (same shape as messages_insert_participant: direct
-- participant, ACTIVE group member, or event invitee/promotor). The
-- `m.sender_id <> auth.uid()` term (verifier fix, 2026-08-17) additionally
-- forbids a member from SELF-STAMPING a receipt on their OWN message — a
-- forged receipt would inflate the sender's "read by N of M" count and fake
-- the all-read blue check; the RPC already excludes own messages, this
-- closes the direct-insert path.
-- ---------------------------------------------------------------------------
CREATE POLICY message_reads_insert_own ON public.message_reads
    FOR INSERT WITH CHECK (
        user_id = auth.uid()
        AND EXISTS (
            SELECT 1
            FROM public.messages m
            JOIN public.chats c ON c.id = m.chat_id
            WHERE m.id = message_reads.message_id
              AND m.sender_id <> auth.uid()
              AND (
                (c.type = 'direct' AND EXISTS (
                    SELECT 1 FROM public.chat_participants
                    WHERE chat_id = c.id AND user_id = auth.uid()
                ))
                OR (c.type = 'group' AND EXISTS (
                    SELECT 1 FROM public.group_members
                    WHERE group_id = c.reference_id AND user_id = auth.uid()
                      AND status = 'active'
                ))
                OR (c.type = 'event' AND (
                    EXISTS (
                        SELECT 1 FROM public.event_invites
                        WHERE event_id = c.reference_id AND user_id = auth.uid()
                    )
                    OR EXISTS (
                        SELECT 1 FROM public.event_promotores
                        WHERE event_id = c.reference_id AND user_id = auth.uid()
                    )
                ))
            )
        )
    );

-- ---------------------------------------------------------------------------
-- message_reads_select_participant — every participant of the message's chat
-- may read the receipts (the read count + reader names render on all
-- devices; realtime delivery of INSERT events is gated on this policy).
-- ---------------------------------------------------------------------------
CREATE POLICY message_reads_select_participant ON public.message_reads
    FOR SELECT USING (
        EXISTS (
            SELECT 1
            FROM public.messages m
            JOIN public.chats c ON c.id = m.chat_id
            WHERE m.id = message_reads.message_id AND (
                (c.type = 'direct' AND EXISTS (
                    SELECT 1 FROM public.chat_participants
                    WHERE chat_id = c.id AND user_id = auth.uid()
                ))
                OR (c.type = 'group' AND EXISTS (
                    SELECT 1 FROM public.group_members
                    WHERE group_id = c.reference_id AND user_id = auth.uid()
                      AND status = 'active'
                ))
                OR (c.type = 'event' AND (
                    EXISTS (
                        SELECT 1 FROM public.event_invites
                        WHERE event_id = c.reference_id AND user_id = auth.uid()
                    )
                    OR EXISTS (
                        SELECT 1 FROM public.event_promotores
                        WHERE event_id = c.reference_id AND user_id = auth.uid()
                    )
                ))
            )
        )
    );

-- ---------------------------------------------------------------------------
-- mark_group_messages_read — SECURITY DEFINER, active-member-gated, inserts
-- the caller's receipt on every message that is not theirs and not a
-- distribution row. Idempotent. Realtime INSERT events on message_reads
-- (gated by the SELECT policy) flip the senders' threads live.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_group_messages_read(p_chat_id uuid)
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
        SELECT 1 FROM public.chats c
        JOIN public.group_members gm
          ON gm.group_id = c.reference_id
        WHERE c.id = p_chat_id
          AND c.type = 'group'
          AND gm.user_id = v_me
          AND gm.status = 'active'
    ) THEN
        RAISE EXCEPTION 'Not a group participant';
    END IF;
    INSERT INTO public.message_reads (message_id, user_id, read_at)
    SELECT m.id, v_me, now()
    FROM public.messages m
    WHERE m.chat_id = p_chat_id
      AND m.sender_id <> v_me
      AND m.recipient_id IS NULL
    ON CONFLICT (message_id, user_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_group_messages_read(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_group_messages_read(uuid) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.mark_group_messages_read(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Realtime delivery of the read receipts (verifier fix, 2026-08-17): the
-- `message-reads:<chatId>` INSERT channel only fires for tables in the
-- `supabase_realtime` publication — without this ALTER the sender's live
-- blue-flip never arrives and the ticks only update on reload. Idempotent
-- DO-block guard (20260817000001/20260817000002 pattern). RLS
-- (message_reads_select_participant) still gates delivery per subscriber.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public' AND tablename = 'message_reads'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.message_reads;
    END IF;
END;
$$;
