-- =============================================================================
-- 20260815000003 — fix chat-policy shadowed correlations (direct branches)
-- -----------------------------------------------------------------------------
-- The original policies (20260510000001:731-739) used an UNQUALIFIED `id` in
-- their direct-chat subqueries:
--
--   chats_read_participant:  WHERE chat_id = id AND user_id = auth.uid()
--   chats_insert_related:    WHERE (chat_id = id) AND (user_id = auth.uid())
--
-- Inside the subquery `id` resolves to `chat_participants.id` (the row's own
-- PK shadows the outer `chats.id`), so PostgreSQL evaluated
-- `chat_participants.chat_id = chat_participants.id` — true for NO row.
-- Consequences (reproduced live 2026-08-15, "No se pudo enviar el mensaje"):
--
--   1. Every direct chat was INVISIBLE to its own participants
--      (`chats` SELECT → [] even for members);
--   2. Every `messages` INSERT violated `messages_insert_participant`
--      (its `chats` subquery is filtered by the read policy) with
--      PostgrestException 42501 — the send failure;
--   3. The direct branch of `chats_insert_related` was dead (client-side
--      direct-chat inserts could never pass — latent; the create_direct_chat
--      RPC bypasses RLS and remains the only creation path).
--
-- `messages_read_participant` (:744) used the qualified `chat_id = chats.id`
-- and was unaffected; the group/event branches have no shadowing column.
--
-- Fix: qualify the outer reference as `chats.id` (audit-fix convention,
-- fully-qualified like 20260809000002).
-- =============================================================================

DROP POLICY IF EXISTS chats_read_participant ON public.chats;
CREATE POLICY chats_read_participant ON public.chats FOR SELECT USING (
    (type = 'direct' AND EXISTS (SELECT 1 FROM public.chat_participants WHERE chat_id = chats.id AND user_id = auth.uid()))
    OR (type = 'group' AND EXISTS (SELECT 1 FROM public.group_members WHERE group_id = chats.reference_id AND user_id = auth.uid()))
    OR (type = 'event' AND (
        EXISTS (SELECT 1 FROM public.event_invites WHERE event_id = chats.reference_id AND user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM public.event_promotores WHERE event_id = chats.reference_id AND user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM public.group_members gm JOIN public.events e ON e.group_id = gm.group_id WHERE e.id = chats.reference_id AND gm.user_id = auth.uid())
    ))
);

DROP POLICY IF EXISTS chats_insert_related ON public.chats;
CREATE POLICY chats_insert_related ON public.chats FOR INSERT WITH CHECK (
    (type = 'event' AND EXISTS (SELECT 1 FROM public.events WHERE id = chats.reference_id AND created_by_user_id = auth.uid()))
    OR (type = 'group' AND EXISTS (SELECT 1 FROM public.groups WHERE id = chats.reference_id AND created_by_user_id = auth.uid()))
    OR (type = 'direct' AND auth.uid() IN (
        SELECT chat_participants.user_id FROM public.chat_participants
        WHERE chat_id = chats.id AND user_id = auth.uid()
    ))
);
