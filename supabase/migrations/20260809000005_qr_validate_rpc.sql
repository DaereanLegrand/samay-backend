-- Samay — validate_qr_token RPC (agent I-57, QRSC foundation)
-- Migration 22 of 22.
--
-- Server-side contract for the promotor scanner
-- (docs/specs/steps/phase-06-qr-system/QRSC-qr-scanner-promotor.md
-- §Edge Function Integration): the `validate-attendance` Edge Function is
-- blocked by EEDG (supabase/functions/ does not exist), so this SECURITY
-- DEFINER RPC is the deployable stand-in — the same validation + atomic
-- transaction semantics (MVP spec §6.4, QEDG §Function 2), callable from the
-- app through PostgREST (`EventService.validateQrToken`).
--
-- Contract (client side: lib/features/qr/qr_providers.dart
-- `qrScanResultFromMap`):
--   * Business outcomes are RETURNED as jsonb (never RAISE'd) so the client
--     maps them to the QRSC error copy without parsing exception messages:
--       {status:'not_promotor'}    scanner not promotor/co_promotor on event
--       {status:'not_in_window'}   event missing/not upcoming/live/outside window
--       {status:'invalid_token'}   no event_qr_tokens row for event+token
--       {status:'expired'}         token expires_at passed
--       {status:'already_scanned'} scanned_at/attendance_confirmed set
--       {status:'not_invited'}     no (non-declined) event_invites row
--       {status:'confirmed', attendeeUserId, attendeeName, confirmedAt}
--   * All three writes (token update + event_attendances insert +
--     event_invites status) happen in ONE transaction, serialized by
--     SELECT FOR UPDATE on the token row — concurrent double-scans cannot
--     double-confirm (MVP spec §6.4 "Concurrent scan protection").
--
-- Hardening (I-31 pattern): SECURITY DEFINER + SET search_path = '' +
-- fully-qualified object references; EXECUTE revoked from PUBLIC and
-- granted to authenticated only.

CREATE OR REPLACE FUNCTION public.validate_qr_token(p_event_id uuid, p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_activation_minutes integer;
    v_event RECORD;
    v_token_row RECORD;
    v_invite RECORD;
BEGIN
    -- 1. Scanner-role check (QRSC: promotor/co_promotor only). auth.uid()
    --    resolves in the auth schema by explicit qualification; anon callers
    --    (auth.uid() = NULL) fail this gate.
    IF NOT EXISTS (
        SELECT 1 FROM public.event_promotores
        WHERE event_id = p_event_id
          AND user_id = auth.uid()
          AND role IN ('promotor', 'co_promotor')
    ) THEN
        RETURN jsonb_build_object('status', 'not_promotor');
    END IF;

    -- 2. Event window (QEDG §Function 2 step 2): status IN ('upcoming','live')
    --    AND now() >= starts_at - qr.activation_minutes_before (default 30).
    SELECT COALESCE(
        (SELECT value::integer FROM public.app_config
         WHERE key = 'qr.activation_minutes_before'),
        30
    ) INTO v_activation_minutes;

    SELECT * INTO v_event FROM public.events WHERE id = p_event_id;
    IF NOT FOUND OR v_event.status NOT IN ('upcoming', 'live')
       OR now() < v_event.starts_at - make_interval(mins => v_activation_minutes)
       OR (v_event.ends_at IS NOT NULL AND now() > v_event.ends_at) THEN
        RETURN jsonb_build_object('status', 'not_in_window');
    END IF;

    -- 3. Token lock + validation (QEDG steps 3-5). FOR UPDATE holds the row
    --    lock until the transaction commits — concurrent scans serialize, so
    --    a token can never be confirmed twice (MVP §6.4).
    SELECT * INTO v_token_row
    FROM public.event_qr_tokens
    WHERE event_id = p_event_id AND token = p_token
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'invalid_token');
    END IF;
    IF v_token_row.expires_at <= now() THEN
        RETURN jsonb_build_object('status', 'expired');
    END IF;
    IF v_token_row.scanned_at IS NOT NULL OR v_token_row.attendance_confirmed THEN
        RETURN jsonb_build_object('status', 'already_scanned');
    END IF;

    -- 4. Invite gate (QRSC error handling: "El usuario no está invitado a
    --    este evento."). Declined invites are rejected; the invite status is
    --    flipped to 'attended' in the atomic write below.
    SELECT * INTO v_invite FROM public.event_invites
    WHERE event_id = p_event_id AND user_id = v_token_row.user_id;
    IF NOT FOUND OR v_invite.status = 'declined' THEN
        RETURN jsonb_build_object('status', 'not_invited');
    END IF;

    -- 5. Atomic writes (QEDG step 6) — one transaction.
    UPDATE public.event_qr_tokens
    SET scanned_at = now(), attendance_confirmed = true
    WHERE id = v_token_row.id;

    INSERT INTO public.event_attendances (event_id, user_id)
    VALUES (p_event_id, v_token_row.user_id)
    ON CONFLICT (event_id, user_id) DO NOTHING;

    UPDATE public.event_invites
    SET status = 'attended',
        responded_at = COALESCE(responded_at, now())
    WHERE event_id = p_event_id AND user_id = v_token_row.user_id;

    RETURN jsonb_build_object(
        'status', 'confirmed',
        'attendeeUserId', v_token_row.user_id,
        'attendeeName', (SELECT username FROM public.users WHERE id = v_token_row.user_id),
        'confirmedAt', now()
    );
END;
$$;

REVOKE ALL ON FUNCTION public.validate_qr_token(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.validate_qr_token(uuid, text) TO authenticated;
