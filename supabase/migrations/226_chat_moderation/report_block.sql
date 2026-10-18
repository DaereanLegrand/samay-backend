-- Samay — 226_chat_moderation/report_block.sql
--
-- Google Play User Generated Content + Apple 1.2 compliance for the E2EE chat:
--   1. BLOCK ENFORCEMENT — a blocked pair cannot open a new direct chat and
--      cannot exchange direct messages. Blocking already set
--      `friendships.status = 'blocked'` and hid the user from search, but the
--      block was display-only: `create_direct_chat` and the message INSERT
--      policy never consulted it (a blocked user could still DM the blocker).
--   2. IN-CHAT MESSAGE REPORT — because the chat is end-to-end encrypted the
--      server cannot read a reported message on its own. The reporter's client
--      decrypts the SPECIFIC reported row and sends that plaintext (plus any
--      media URL) to `report_message`, which records a moderator-readable
--      snapshot in `message_reports` and a queue row in `reports`. Moderators
--      act on it via `samay-admin reports` (ban / dismiss). This is the
--      documented end-to-end-encryption reporting exception: only the row the
--      user chose to report is disclosed (Google UGC policy; Apple 1.2).
--
-- pgTAP coverage: supabase/tests/schema_test.sql. Live coverage:
-- test/opt-040-chat-report-block.sh.
-- ======================================================================

-- ----------------------------------------------------------------------
-- is_blocked_between(a, b) — true when ANY block row exists between the two
-- users in EITHER direction. SECURITY DEFINER so it can be used inside RLS
-- policies and triggers regardless of the caller's view of `friendships`.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_blocked_between(p_a uuid, p_b uuid)
RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT EXISTS (
        SELECT 1
          FROM public.friendships f
         WHERE f.status = 'blocked'
           AND ((f.requester_id = p_a AND f.addressee_id = p_b)
             OR (f.requester_id = p_b AND f.addressee_id = p_a))
    );
$$;

REVOKE ALL ON FUNCTION public.is_blocked_between(uuid, uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_blocked_between(uuid, uuid) TO authenticated;
GRANT ALL ON FUNCTION public.is_blocked_between(uuid, uuid) TO service_role;

-- ----------------------------------------------------------------------
-- create_direct_chat — unchanged except the block gate: a blocked pair never
-- gets a direct thread. Returns {"status":"blocked"} (the client maps it to a
-- localized message) instead of throwing.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_direct_chat(p_peer_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
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

    -- Block gate: no direct thread in either direction.
    IF public.is_blocked_between(v_me, p_peer_id) THEN
        RETURN jsonb_build_object('status', 'blocked');
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

-- ----------------------------------------------------------------------
-- assert_message_not_blocked() — BEFORE INSERT guard on direct messages. The
-- RLS INSERT policy cannot read `friendships`, so this trigger (SECURITY
-- DEFINER) raises BLOCKED when the sender and the other participant of a
-- DIRECT chat have a block row in either direction. Group/event chats are not
-- affected (blocking is a 1:1 control).
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_message_not_blocked() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_type public.chat_type;
    v_other uuid;
BEGIN
    SELECT type INTO v_type FROM public.chats WHERE id = NEW.chat_id;
    IF v_type = 'direct' THEN
        SELECT user_id INTO v_other
          FROM public.chat_participants
         WHERE chat_id = NEW.chat_id
           AND user_id <> NEW.sender_id
         LIMIT 1;
        IF v_other IS NOT NULL
           AND public.is_blocked_between(NEW.sender_id, v_other) THEN
            RAISE EXCEPTION 'BLOCKED';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER assert_message_not_blocked_trigger
    BEFORE INSERT ON public.messages
    FOR EACH ROW EXECUTE FUNCTION public.assert_message_not_blocked();

REVOKE ALL ON FUNCTION public.assert_message_not_blocked() FROM PUBLIC;
GRANT ALL ON FUNCTION public.assert_message_not_blocked() TO service_role;

-- ----------------------------------------------------------------------
-- message_reports — the moderator-readable snapshot of a reported message.
-- Client access is fully denied (FORCE RLS + false policy); moderators read it
-- through the admin CLI's service_role.
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.message_reports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id uuid NOT NULL,
    message_id uuid NOT NULL,
    chat_id uuid NOT NULL,
    sender_id uuid NOT NULL,
    reporter_id uuid NOT NULL,
    reason text NOT NULL,
    plaintext text,
    media_url text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE ONLY public.message_reports
    ADD CONSTRAINT message_reports_report_id_fkey
    FOREIGN KEY (report_id) REFERENCES public.reports(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_message_reports_report
    ON public.message_reports USING btree (report_id);
CREATE INDEX IF NOT EXISTS idx_message_reports_message
    ON public.message_reports USING btree (message_id);

ALTER TABLE public.message_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_reports FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS message_reports_no_access ON public.message_reports;
CREATE POLICY message_reports_no_access
    ON public.message_reports USING (false) WITH CHECK (false);

REVOKE ALL ON TABLE public.message_reports FROM anon;
REVOKE ALL ON TABLE public.message_reports FROM authenticated;
GRANT ALL ON TABLE public.message_reports TO service_role;

-- ----------------------------------------------------------------------
-- report_message(message_id, reason, plaintext) — participant-gated report of
-- one specific message. The caller's client supplies the DECRYPTED plaintext
-- of that row (end-to-end-encryption reporting exception, see the file header)
-- and any media URL already attached to the row. Writes the `reports` queue
-- row (target_type='message') + the `message_reports` snapshot and flags
-- messages.reported.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_message(
    p_message_id uuid,
    p_reason text,
    p_plaintext text DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_chat_id uuid;
    v_sender_id uuid;
    v_media_url text;
    v_reason text;
    v_report_id uuid;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    v_reason := COALESCE(NULLIF(btrim(p_reason), ''), 'other');

    SELECT chat_id, sender_id, media_url
      INTO v_chat_id, v_sender_id, v_media_url
      FROM public.messages
     WHERE id = p_message_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'message_not_found');
    END IF;

    -- Participant gate (mirrors messages_read_participant).
    IF NOT EXISTS (
        SELECT 1 FROM public.chats
        WHERE id = v_chat_id AND (
            (type = 'direct' AND EXISTS (
                SELECT 1 FROM public.chat_participants
                WHERE chat_id = v_chat_id AND user_id = v_me
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
                    WHERE event_id = chats.reference_id AND user_id = v_me
                )
                OR EXISTS (
                    SELECT 1 FROM public.event_hosts
                    WHERE event_id = chats.reference_id AND user_id = v_me
                )
            ))
        )
    ) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    INSERT INTO public.reports (reporter_id, target_type, target_id, reason, status)
    VALUES (v_me, 'message', p_message_id, v_reason, 'pending')
    RETURNING id INTO v_report_id;

    INSERT INTO public.message_reports (
        report_id, message_id, chat_id, sender_id, reporter_id, reason,
        plaintext, media_url
    ) VALUES (
        v_report_id, p_message_id, v_chat_id, v_sender_id, v_me, v_reason,
        p_plaintext, v_media_url
    );

    UPDATE public.messages SET reported = true WHERE id = p_message_id;

    RETURN jsonb_build_object('status', 'ok', 'report_id', v_report_id);
END;
$$;

REVOKE ALL ON FUNCTION public.report_message(uuid, text, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.report_message(uuid, text, text) TO authenticated;
GRANT ALL ON FUNCTION public.report_message(uuid, text, text) TO service_role;
