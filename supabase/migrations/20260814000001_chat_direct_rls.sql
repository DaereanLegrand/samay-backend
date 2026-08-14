-- Samay — Direct-chat creation RPC + chat_participants/messages RLS fixes
-- (docs-to-code audit, 2026-08-13 — cross-references CHAT row + S-07 #2)
--
-- Three fixes so the E2EE direct-chat path actually works under live RLS:
--
--   1. `cp_read_own` (SELECT own participant row only) made
--      `_resolvePeerUserId` (lib/core/services/chat_service.dart) always see
--      an empty peer list → E2EE send threw "No peer participant" on a real
--      stack. New policy `cp_read_participant`: a user may SELECT the
--      participants of any chat they belong to (the info needed to resolve
--      the 1:1 peer; the same set `messages_read_participant` already
--      exposes via message sender_id).
--
--   2. Direct chats could never be created client-side: `chats_insert_related`
--      requires the caller to already be a participant — a chicken-and-egg
--      dead end. New SECURITY DEFINER RPC `create_direct_chat(p_peer_id)`
--      creates the chat + BOTH participant rows atomically and reuses an
--      existing direct chat between the pair. Client INSERT on
--      `chat_participants` stays denied (the RPC is the only creator).
--
--   3. `messages_insert_own` only checked `sender_id = auth.uid()` → any
--      authenticated user could inject messages into ANY chat (and Realtime
--      would deliver them to its subscribers). Replaced with
--      `messages_insert_participant`: sender + membership in the chat
--      (mirroring `messages_read_participant`).
--
-- Deviation (documented): chat creation goes through a SQL RPC instead of
-- the spec's Edge Function — same deployable stand-in pattern as
-- `validate_qr_token` (20260809000005) while EEDG stays blocked.
--
-- References: docs/specs/steps/phase-07-chat/CHAT-chat-system-core.md,
-- docs/specs/steps/phase-07-chat/CHPT-chat-participation-access-rules.md,
-- docs/security/E2EE-ARCHITECTURE.md §12.2.
-- Companion Dart: lib/core/services/chat_service.dart `createDirectChat`.

-- ============================================================
-- 1. chat_participants — co-participants of chats I belong to
-- ============================================================
-- is_chat_participant: SECURITY DEFINER helper (canonical Supabase pattern
-- for chat-scoped access checks, mirroring is_group_member, migration
-- 20260809000002 §11.1). Runs as postgres (bypassrls) → no RLS recursion
-- when a policy on chat_participants itself reads chat_participants.
-- STABLE is required for use inside policies (volatile functions are
-- rejected there). Anon keeps EXECUTE — the policy must evaluate for
-- unauthenticated queries too (the function leaks nothing: it answers a
-- membership boolean for the caller's own auth.uid()).
CREATE OR REPLACE FUNCTION public.is_chat_participant(p_chat_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.chat_participants
        WHERE chat_id = p_chat_id AND user_id = p_user_id
    );
$$;

GRANT EXECUTE ON FUNCTION public.is_chat_participant(uuid, uuid) TO anon, authenticated;

DROP POLICY IF EXISTS cp_read_participant ON public.chat_participants;
CREATE POLICY cp_read_participant ON public.chat_participants
    FOR SELECT USING (
        public.is_chat_participant(chat_participants.chat_id, auth.uid())
    );

-- ============================================================
-- 2. create_direct_chat(p_peer_id) — SECURITY DEFINER RPC
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_direct_chat(p_peer_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_me uuid := auth.uid();
    v_chat_id uuid;
    v_reused boolean := true;
BEGIN
    IF v_me IS NULL THEN
        RAISE EXCEPTION 'Not authorized';
    END IF;
    IF p_peer_id = v_me THEN
        RAISE EXCEPTION 'Cannot chat with yourself';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.users
        WHERE id = p_peer_id AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Peer not found';
    END IF;

    -- Reuse an existing direct chat between the pair (1:1 chats are unique
    -- per pair — no duplicate threads).
    SELECT c.id INTO v_chat_id
    FROM public.chats c
    WHERE c.type = 'direct'
      AND EXISTS (
          SELECT 1 FROM public.chat_participants p1
          WHERE p1.chat_id = c.id AND p1.user_id = v_me
      )
      AND EXISTS (
          SELECT 1 FROM public.chat_participants p2
          WHERE p2.chat_id = c.id AND p2.user_id = p_peer_id
      )
    LIMIT 1;

    IF v_chat_id IS NULL THEN
        v_reused := false;
        INSERT INTO public.chats (type, reference_id)
        VALUES ('direct'::public.chat_type, NULL)
        RETURNING id INTO v_chat_id;

        INSERT INTO public.chat_participants (chat_id, user_id)
        VALUES (v_chat_id, v_me), (v_chat_id, p_peer_id);
    END IF;

    RETURN jsonb_build_object(
        'chatId', v_chat_id,
        'reused', v_reused
    );
END;
$$;

REVOKE ALL ON FUNCTION public.create_direct_chat(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.create_direct_chat(uuid) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_direct_chat(uuid) TO authenticated;

-- ============================================================
-- 3. messages INSERT — sender + participation guard
-- ============================================================
DROP POLICY IF EXISTS messages_insert_own ON public.messages;
DROP POLICY IF EXISTS messages_insert_participant ON public.messages;
CREATE POLICY messages_insert_participant ON public.messages
    FOR INSERT WITH CHECK (
        sender_id = auth.uid()
        AND EXISTS (
            SELECT 1 FROM public.chats
            WHERE id = messages.chat_id AND (
                (type = 'direct' AND EXISTS (
                    SELECT 1 FROM public.chat_participants
                    WHERE chat_id = chats.id AND user_id = auth.uid()
                ))
                OR (type = 'group' AND EXISTS (
                    SELECT 1 FROM public.group_members
                    WHERE group_id = chats.reference_id AND user_id = auth.uid()
                ))
                OR (type = 'event' AND (
                    EXISTS (
                        SELECT 1 FROM public.event_invites
                        WHERE event_id = chats.reference_id AND user_id = auth.uid()
                    )
                    OR EXISTS (
                        SELECT 1 FROM public.event_promotores
                        WHERE event_id = chats.reference_id AND user_id = auth.uid()
                    )
                ))
            )
        )
    );
