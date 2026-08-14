-- Samay — In-app notification producers (NTRG, docs-to-code audit 2026-08-13)
--
-- The in-app notification center had ZERO producers: nothing ever INSERTed
-- into `notifications` (no Edge Functions while EEDG stays blocked, no
-- triggers), so the screen was always empty on a real stack. These triggers
-- close the DB-driven NTRG dispatch points through the guarded
-- `insert_notification` helper (migration 20260814000003):
--
--   | # | Event                              | Recipient(s)                    |
--   |---|------------------------------------|---------------------------------|
--   | 1 | event_invites INSERT               | invitee                         |
--   | 2 | friendships INSERT (pending)       | addressee                       |
--   | 3 | events UPDATE → live              | all invitees                    |
--   | 4 | events UPDATE → cancelled         | all invitees                    |
--   | 5 | event_attendances INSERT          | attendee (confirmation)         |
--   | 6 | messages INSERT                   | chat participants (not sender)  |
--   | 7 | minigame_sessions INSERT          | each participant                |
--   | 8 | feature_requests UPDATE → approved/rejected | requester            |
--
-- Notes / deviations (documented):
--   * Triggers are SECURITY DEFINER (owner = migration role) so the
--     notification INSERT is not subject to the caller's RLS; EXECUTE is
--     revoked (trigger-invoked only, 20260811000001 §4 pattern). The
--     functions only ever write notifications — no data reads are exposed.
--   * The message trigger carries NO message content (E2EE §9.2: the server
--     never sees plaintext; the notification body is generic).
--   * QR-activation / push-notifier dispatch points (PUSH, EEDG, GRCK done)
--     remain Edge-Function territory; rank-bracket notifications ship with
--     recalculate_ranks (migration 20260814000003).
--
-- References: docs/specs/steps/phase-09-notifications-push/
-- NTRG-notification-triggers-routing.md (16 dispatch points, DB subset),
-- docs/specs/product/samay_mvp_spec.md#notifications.

-- ============================================================
-- 1. Event invite sent
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_event_invite()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_event_name text;
BEGIN
    SELECT name INTO v_event_name FROM public.events WHERE id = NEW.event_id;
    PERFORM public.insert_notification(
        NEW.user_id,
        'event_invite',
        'Invitación a evento',
        COALESCE(v_event_name, 'Tienes una invitación a un evento'),
        jsonb_build_object('eventId', NEW.event_id)
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_event_invite_trigger ON public.event_invites;
CREATE TRIGGER notify_event_invite_trigger
    AFTER INSERT ON public.event_invites
    FOR EACH ROW EXECUTE FUNCTION public.notify_event_invite();

-- ============================================================
-- 2. Friend request sent
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_friend_request()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NEW.status = 'pending' THEN
        PERFORM public.insert_notification(
            NEW.addressee_id,
            'friend_request',
            'Solicitud de amistad',
            'Alguien quiere ser tu amigo',
            jsonb_build_object('userId', NEW.requester_id)
        );
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_friend_request_trigger ON public.friendships;
CREATE TRIGGER notify_friend_request_trigger
    AFTER INSERT ON public.friendships
    FOR EACH ROW EXECUTE FUNCTION public.notify_friend_request();

-- ============================================================
-- 3. Event status → live
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_event_live()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_recipient uuid;
BEGIN
    IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
        RETURN NEW;
    END IF;
    FOR v_recipient IN
        SELECT user_id FROM public.event_invites
        WHERE event_id = NEW.id AND status <> 'declined'
    LOOP
        PERFORM public.insert_notification(
            v_recipient,
            'event_live',
            'El evento está en vivo',
            NEW.name,
            jsonb_build_object('eventId', NEW.id)
        );
    END LOOP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_event_live_trigger ON public.events;
CREATE TRIGGER notify_event_live_trigger
    AFTER UPDATE OF status ON public.events
    FOR EACH ROW
    WHEN (NEW.status = 'live')
    EXECUTE FUNCTION public.notify_event_live();

-- ============================================================
-- 4. Event cancelled
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_event_cancelled()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_recipient uuid;
BEGIN
    IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
        RETURN NEW;
    END IF;
    FOR v_recipient IN
        SELECT user_id FROM public.event_invites
        WHERE event_id = NEW.id AND status <> 'declined'
    LOOP
        PERFORM public.insert_notification(
            v_recipient,
            'event_cancelled',
            'Evento cancelado',
            NEW.name,
            jsonb_build_object('eventId', NEW.id)
        );
    END LOOP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_event_cancelled_trigger ON public.events;
CREATE TRIGGER notify_event_cancelled_trigger
    AFTER UPDATE OF status ON public.events
    FOR EACH ROW
    WHEN (NEW.status = 'cancelled')
    EXECUTE FUNCTION public.notify_event_cancelled();

-- ============================================================
-- 5. Attendance confirmed (scan success)
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_attendance_confirmed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_event_name text;
BEGIN
    SELECT name INTO v_event_name FROM public.events WHERE id = NEW.event_id;
    PERFORM public.insert_notification(
        NEW.user_id,
        'attendance_confirmed',
        'Asistencia confirmada',
        COALESCE(v_event_name, 'Tu asistencia fue confirmada'),
        jsonb_build_object('eventId', NEW.event_id)
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_attendance_confirmed_trigger ON public.event_attendances;
CREATE TRIGGER notify_attendance_confirmed_trigger
    AFTER INSERT ON public.event_attendances
    FOR EACH ROW EXECUTE FUNCTION public.notify_attendance_confirmed();

-- ============================================================
-- 6. New message — participants except the sender (E2EE: no content)
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_new_message()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_recipient uuid;
    v_chat_type public.chat_type;
    v_reference_id uuid;
BEGIN
    SELECT type, reference_id INTO v_chat_type, v_reference_id
    FROM public.chats WHERE id = NEW.chat_id;
    IF NOT FOUND THEN RETURN NEW; END IF;

    IF v_chat_type = 'direct' THEN
        FOR v_recipient IN
            SELECT user_id FROM public.chat_participants WHERE chat_id = NEW.chat_id
        LOOP
            IF v_recipient <> NEW.sender_id THEN
                PERFORM public.insert_notification(
                    v_recipient, 'new_message', 'Nuevo mensaje',
                    'Tienes un nuevo mensaje en el chat',
                    jsonb_build_object('chatId', NEW.chat_id));
            END IF;
        END LOOP;
    ELSIF v_chat_type = 'group' THEN
        FOR v_recipient IN
            SELECT user_id FROM public.group_members
            WHERE group_id = v_reference_id AND status = 'active'
        LOOP
            IF v_recipient <> NEW.sender_id THEN
                PERFORM public.insert_notification(
                    v_recipient, 'new_message', 'Nuevo mensaje',
                    'Tienes un nuevo mensaje en el chat',
                    jsonb_build_object('chatId', NEW.chat_id));
            END IF;
        END LOOP;
    ELSIF v_chat_type = 'event' THEN
        FOR v_recipient IN
            SELECT user_id FROM public.event_invites
            WHERE event_id = v_reference_id AND status <> 'declined'
            UNION
            SELECT user_id FROM public.event_promotores
            WHERE event_id = v_reference_id
        LOOP
            IF v_recipient <> NEW.sender_id THEN
                PERFORM public.insert_notification(
                    v_recipient, 'new_message', 'Nuevo mensaje',
                    'Tienes un nuevo mensaje en el chat',
                    jsonb_build_object('chatId', NEW.chat_id));
            END IF;
        END LOOP;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_new_message_trigger ON public.messages;
CREATE TRIGGER notify_new_message_trigger
    AFTER INSERT ON public.messages
    FOR EACH ROW EXECUTE FUNCTION public.notify_new_message();

-- ============================================================
-- 7. Mini-game invite (new session)
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_minigame_invite()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_recipient uuid;
BEGIN
    FOREACH v_recipient IN ARRAY NEW.participants
    LOOP
        PERFORM public.insert_notification(
            v_recipient,
            'minigame_invite',
            'Invitación a minijuego',
            'Te invitaron a un minijuego de grupo',
            jsonb_build_object('groupId', NEW.group_id, 'sessionId', NEW.id)
        );
    END LOOP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_minigame_invite_trigger ON public.minigame_sessions;
CREATE TRIGGER notify_minigame_invite_trigger
    AFTER INSERT ON public.minigame_sessions
    FOR EACH ROW EXECUTE FUNCTION public.notify_minigame_invite();

-- ============================================================
-- 8. Feature request approved / rejected
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_feature_request()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_event_name text;
    v_verdict text := CASE WHEN NEW.status = 'approved' THEN 'aprobada'
                           ELSE 'rechazada' END;
BEGIN
    IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
        RETURN NEW;
    END IF;
    SELECT name INTO v_event_name FROM public.events WHERE id = NEW.event_id;
    PERFORM public.insert_notification(
        NEW.requested_by_user_id,
        'feature_request',
        'Solicitud de evento ' || v_verdict,
        COALESCE(v_event_name, 'Tu solicitud de evento fue ' || v_verdict),
        jsonb_build_object('eventId', NEW.event_id, 'status', NEW.status)
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_feature_request_trigger ON public.feature_requests;
CREATE TRIGGER notify_feature_request_trigger
    AFTER UPDATE OF status ON public.feature_requests
    FOR EACH ROW
    WHEN (NEW.status IN ('approved', 'rejected'))
    EXECUTE FUNCTION public.notify_feature_request();

-- Trigger functions are invoked by the system — no client role needs
-- EXECUTE (hygiene, 20260811000001 §4 pattern).
REVOKE EXECUTE ON FUNCTION public.notify_event_invite() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_friend_request() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_event_live() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_event_cancelled() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_attendance_confirmed() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_new_message() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_minigame_invite() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_feature_request() FROM PUBLIC, anon, authenticated;
