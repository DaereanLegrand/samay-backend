-- =============================================================================
-- 20260817000002 — Group chat support (ISSUE 4, DB layer / D1)
-- -----------------------------------------------------------------------------
-- Group chats already exist as `chats` rows (type='group', reference_id =
-- groupId, created by GroupService.createGroup) but have NO `chat_participants`
-- rows, so they are invisible to the inbox RPC and the read/unread machinery.
-- This migration makes the participant set a first-class, trigger-maintained
-- mirror of the ACTIVE group membership:
--
--   D1a. Backfill: every existing group chat gains a participant row for every
--        member with status = 'active' (ON CONFLICT DO NOTHING — idempotent).
--
--   D1b. `sync_group_chat_participant` trigger on `group_members`
--        (AFTER INSERT OR UPDATE OR DELETE, SECURITY DEFINER): resolves the
--        group's chat row and inserts/deletes the participant row so the set
--        always equals the active members. SECURITY DEFINER is required — there
--        is deliberately NO INSERT policy on chat_participants
--        (create_direct_chat is the only other creator) and the trigger must
--        bypass RLS. If no chat row exists, no-op (createGroup inserts the
--        membership before the chat; D1c backfills in that order).
--
--   D1c. `sync_group_chat_participants_on_chats` trigger on `chats`
--        (AFTER INSERT, SECURITY DEFINER): a new group chat backfills ALL
--        active members — covers createGroup's insert order where the
--        membership insert may precede the chats insert.
--
--   D1d. `get_chat_inbox()` peer join branches on c.type: group chats display
--        the group name (LEFT JOIN public.groups), peer_id stays NULL;
--        direct/event chats keep the user_search_view peer (block exclusion
--        + deleted_at filter intact). Ordering unchanged.
--
--   D1e. RLS tightened to ACTIVE members only: the group branches of
--        messages_read_participant, messages_insert_participant and
--        chats_read_participant all gate on status = 'active' — an invited
--        (not-yet-accepted) user can no longer read or write the group chat.
--
--   D1f. group_members joins the `supabase_realtime` publication (idempotent
--        guard — 20260817000001 may add it; this guard skips cleanly either
--        way).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- D1a. Backfill: existing group chats → participant rows for active members
-- -----------------------------------------------------------------------------
INSERT INTO public.chat_participants (chat_id, user_id)
SELECT c.id, gm.user_id
FROM public.chats c
JOIN public.group_members gm
  ON gm.group_id = c.reference_id AND gm.status = 'active'
WHERE c.type = 'group'
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- D1b. group_members → chat_participants sync trigger
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_group_chat_participant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_chat_id uuid;
BEGIN
    -- plpgsql does NOT short-circuit AND/OR conditions, so each TG_OP gets its
    -- own branch with an explicit RETURN (pattern: OPT-009, migration
    -- 20260816000001). Only OLD is valid in the DELETE branch.
    IF TG_OP = 'DELETE' THEN
        SELECT id INTO v_chat_id
        FROM public.chats
        WHERE type = 'group' AND reference_id = OLD.group_id
        LIMIT 1;

        IF v_chat_id IS NOT NULL THEN
            DELETE FROM public.chat_participants
            WHERE chat_id = v_chat_id AND user_id = OLD.user_id;
        END IF;
        RETURN OLD;
    END IF;

    -- INSERT / UPDATE: resolve the group's chat row; no chat → no-op.
    SELECT id INTO v_chat_id
    FROM public.chats
    WHERE type = 'group' AND reference_id = NEW.group_id
    LIMIT 1;

    IF v_chat_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Active membership ⇒ participant row; invited/removed ⇒ none.
    IF NEW.status = 'active' THEN
        INSERT INTO public.chat_participants (chat_id, user_id)
        VALUES (v_chat_id, NEW.user_id)
        ON CONFLICT DO NOTHING;
    ELSE
        DELETE FROM public.chat_participants
        WHERE chat_id = v_chat_id AND user_id = NEW.user_id;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_group_chat_participant_trigger ON public.group_members;
CREATE TRIGGER sync_group_chat_participant_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.group_members
    FOR EACH ROW EXECUTE FUNCTION public.sync_group_chat_participant();

-- -----------------------------------------------------------------------------
-- D1c. chats → chat_participants backfill on group-chat creation
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_group_chat_participants_on_chats()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.type = 'group' THEN
        INSERT INTO public.chat_participants (chat_id, user_id)
        SELECT NEW.id, gm.user_id
        FROM public.group_members gm
        WHERE gm.group_id = NEW.reference_id AND gm.status = 'active'
        ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_group_chat_participants_on_chats_trigger ON public.chats;
CREATE TRIGGER sync_group_chat_participants_on_chats_trigger
    AFTER INSERT ON public.chats
    FOR EACH ROW EXECUTE FUNCTION public.sync_group_chat_participants_on_chats();

-- Trigger-invoked helpers need no EXECUTE privilege; explicit REVOKE so the
-- anon-executable SD-function posture (Section 48) stays clean.
REVOKE EXECUTE ON FUNCTION public.sync_group_chat_participant() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.sync_group_chat_participants_on_chats() FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- D1d. get_chat_inbox — group chats display groups.name / peer_id NULL
-- -----------------------------------------------------------------------------
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
        CASE WHEN c.type = 'group' THEN NULL ELSE usv.id END,
        CASE WHEN c.type = 'group' THEN g.name ELSE usv.username END,
        CASE WHEN c.type = 'group' THEN g.cover_url ELSE usv.avatar_url END,
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
    LEFT JOIN public.groups g
      ON c.type = 'group' AND g.id = c.reference_id
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

-- -----------------------------------------------------------------------------
-- D1e. Active-only RLS on the group branches
-- -----------------------------------------------------------------------------

-- messages SELECT: group branch gates on status = 'active' (invited users are
-- excluded from the chat until they accept). Direct/event branches unchanged.
DROP POLICY IF EXISTS messages_read_participant ON public.messages;
CREATE POLICY messages_read_participant ON public.messages FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.chats WHERE id = messages.chat_id AND (
        (type = 'direct' AND EXISTS (
            SELECT 1 FROM public.chat_participants
            WHERE chat_id = chats.id AND user_id = auth.uid()
        ))
        OR (type = 'group' AND EXISTS (
            SELECT 1 FROM public.group_members
            WHERE group_id = chats.reference_id AND user_id = auth.uid()
              AND status = 'active'
        ))
        OR (type = 'event' AND (
            EXISTS (SELECT 1 FROM public.event_invites WHERE event_id = chats.reference_id AND user_id = auth.uid())
            OR EXISTS (SELECT 1 FROM public.event_promotores WHERE event_id = chats.reference_id AND user_id = auth.uid())
        ))
    ))
);

-- messages INSERT: same active gate on the group branch; sender + direct/event
-- branches unchanged.
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
                      AND status = 'active'
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

-- chats SELECT: group branch gates on status = 'active'; direct/event branches
-- unchanged (the 20260815000003 qualified-correlation fix is preserved).
DROP POLICY IF EXISTS chats_read_participant ON public.chats;
CREATE POLICY chats_read_participant ON public.chats FOR SELECT USING (
    (type = 'direct' AND EXISTS (SELECT 1 FROM public.chat_participants WHERE chat_id = chats.id AND user_id = auth.uid()))
    OR (type = 'group' AND EXISTS (SELECT 1 FROM public.group_members WHERE group_id = chats.reference_id AND user_id = auth.uid() AND status = 'active'))
    OR (type = 'event' AND (
        EXISTS (SELECT 1 FROM public.event_invites WHERE event_id = chats.reference_id AND user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM public.event_promotores WHERE event_id = chats.reference_id AND user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM public.group_members gm JOIN public.events e ON e.group_id = gm.group_id WHERE e.id = chats.reference_id AND gm.user_id = auth.uid())
    ))
);

-- -----------------------------------------------------------------------------
-- D1f. group_members joins the realtime publication (idempotent — skips if
-- 20260817000001 already added it)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public' AND tablename = 'group_members'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.group_members;
    END IF;
END;
$$;
