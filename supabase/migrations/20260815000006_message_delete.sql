-- =============================================================================
-- 20260815000006 — message deletion: delete_for_everyone (5-min window) +
-- undecryptable cleanup + deleted_messages audit
-- -----------------------------------------------------------------------------
-- Signal-style history semantics + server offload (user directive 2026-08-16):
--
--   1. `messages.sent_at` — server-authoritative send timestamp. `created_at`
--      is client-supplied (both devices use their own clocks), so it cannot
--      anchor a deletion window. `sent_at` defaults to `now()` at INSERT —
--      the SERVER's clock — and is what `delete_message_for_everyone`
--      verifies against. Existing rows are backfilled from `created_at` so
--      history predating this migration is never deleteable by the window.
--
--   2. `delete_message_for_everyone(p_message_id)` — SECURITY DEFINER,
--      sender-only, `now() - sent_at <= interval '5 minutes'` enforced with
--      the server clock at call time (the client can never extend the window
--      by lying about the send time). Errors are surfaced via exception
--      messages the client maps to l10n ('MESSAGE_TOO_OLD', 'NOT_THE_SENDER',
--      'MESSAGE_NOT_FOUND').
--
--   3. `delete_undecryptable_messages(p_chat_id, p_message_ids[])` —
--      SECURITY DEFINER, participant-gated (direct/group/event — the
--      messages_read_participant set). The CLIENT deletes rows it can never
--      decrypt (pre-reinstall history: new identity, no session, no private
--      keys — nobody can ever read them again). Offload: the server stops
--      storing bytes that are permanently unreadable. Trust surface
--      (documented): the server cannot verify "undecryptable" (no keys), so
--      any participant could abuse it to wipe chat history — mitigated by
--      participant-gating and the `deleted_messages` audit rows.
--
--   4. `deleted_messages` — audit trail for every deletion (who, what chat,
--      why, when). Purely informational; a prune cron can drop old rows.
--
-- Skip-gap/tampered rows (a session exists but decrypt fails) are NEVER
-- deleted by the client — only the no-session class goes through
-- delete_undecryptable_messages.
--
-- Realtime: `messages` is already in supabase_realtime with REPLICA IDENTITY
-- FULL (20260809000003) — hard-delete rows deliver PostgresChangeEvent.delete
-- so the peer's open thread removes them live.
-- =============================================================================

-- ============================================================
-- 1. messages.sent_at — server-authoritative send timestamp
-- ============================================================
ALTER TABLE public.messages
    ADD COLUMN IF NOT EXISTS sent_at timestamptz;

-- Backfill: pre-existing rows anchor the window to their created_at (never
-- open the 5-minute window on history).
UPDATE public.messages SET sent_at = created_at WHERE sent_at IS NULL;

ALTER TABLE public.messages
    ALTER COLUMN sent_at SET NOT NULL,
    ALTER COLUMN sent_at SET DEFAULT now();

-- ============================================================
-- 2. deleted_messages — audit trail
-- ============================================================
CREATE TABLE IF NOT EXISTS public.deleted_messages (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    message_id uuid NOT NULL,
    chat_id uuid NOT NULL,
    deleted_by uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    reason text NOT NULL CHECK (reason IN ('delete_for_everyone', 'undecryptable_cleanup')),
    deleted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS deleted_messages_message_id_idx
    ON public.deleted_messages (message_id);
CREATE INDEX IF NOT EXISTS deleted_messages_chat_id_idx
    ON public.deleted_messages (chat_id);

-- ============================================================
-- 3. delete_message_for_everyone(p_message_id) — SECURITY DEFINER
-- ============================================================
CREATE OR REPLACE FUNCTION public.delete_message_for_everyone(p_message_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_me uuid := auth.uid();
    v_sender_id uuid;
    v_chat_id uuid;
    v_sent_at timestamptz;
BEGIN
    IF v_me IS NULL THEN
        RAISE EXCEPTION 'Not authorized';
    END IF;

    SELECT sender_id, chat_id, sent_at
      INTO v_sender_id, v_chat_id, v_sent_at
      FROM public.messages
     WHERE id = p_message_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'MESSAGE_NOT_FOUND';
    END IF;
    IF v_sender_id <> v_me THEN
        RAISE EXCEPTION 'NOT_THE_SENDER';
    END IF;
    -- The 5-minute window is anchored on the SERVER clock via sent_at
    -- (never the client's claim).
    IF v_sent_at IS NULL OR now() - v_sent_at > interval '5 minutes' THEN
        RAISE EXCEPTION 'MESSAGE_TOO_OLD';
    END IF;

    DELETE FROM public.messages
     WHERE id = p_message_id
       AND sender_id = v_me
       AND (sent_at IS NULL OR now() - sent_at <= interval '5 minutes');

    IF FOUND THEN
        INSERT INTO public.deleted_messages (message_id, chat_id, deleted_by, reason)
        VALUES (p_message_id, v_chat_id, v_me, 'delete_for_everyone');
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_message_for_everyone(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.delete_message_for_everyone(uuid) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.delete_message_for_everyone(uuid) TO authenticated;

-- ============================================================
-- 4. delete_undecryptable_messages(p_chat_id, p_message_ids[]) —
--    SECURITY DEFINER, participant-gated cleanup
-- ============================================================
CREATE OR REPLACE FUNCTION public.delete_undecryptable_messages(
    p_chat_id uuid,
    p_message_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_me uuid := auth.uid();
    v_deleted integer := 0;
BEGIN
    IF v_me IS NULL THEN
        RAISE EXCEPTION 'Not authorized';
    END IF;

    -- Participant gate: the messages_read_participant set (direct → chat
    -- participants; group → group_members via chats.reference_id; event →
    -- event_invites OR event_promotores). Cross-chat ids are ignored by the
    -- chat_id predicate below.
    IF NOT EXISTS (
        SELECT 1 FROM public.chats
        WHERE id = p_chat_id AND (
            (type = 'direct' AND EXISTS (
                SELECT 1 FROM public.chat_participants
                WHERE chat_id = p_chat_id AND user_id = v_me
            ))
            OR (type = 'group' AND EXISTS (
                SELECT 1 FROM public.group_members
                WHERE group_id = chats.reference_id AND user_id = v_me
            ))
            OR (type = 'event' AND (
                EXISTS (
                    SELECT 1 FROM public.event_invites
                    WHERE event_id = chats.reference_id AND user_id = v_me
                )
                OR EXISTS (
                    SELECT 1 FROM public.event_promotores
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
        RETURNING id, chat_id
    )
    INSERT INTO public.deleted_messages (message_id, chat_id, deleted_by, reason)
    SELECT id, chat_id, v_me, 'undecryptable_cleanup' FROM deleted;

    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_undecryptable_messages(uuid, uuid[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.delete_undecryptable_messages(uuid, uuid[]) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.delete_undecryptable_messages(uuid, uuid[]) TO authenticated;
