-- Samay — rotate_qr_token RPC: attendee QR token issuance + rotation
-- (docs-to-code audit, 2026-08-13)
--
-- The attendance-QR loop (MVP §6.4 / QEDG `qr-token-manager` Edge Function)
-- was dead: NOTHING ever INSERTed into `event_qr_tokens` (RLS forbids client
-- inserts — "Edge Function only" — and no Edge Function exists while EEDG
-- stays blocked), so the attendee screen sat in `serverPending` forever and
-- the scanner had nothing to validate. This SECURITY DEFINER RPC is the
-- deployable stand-in (same pattern as `validate_qr_token`, 20260809000005):
--
--   * Caller must be an invited (non-declined) attendee and the event must
--     be inside the activation window (upcoming/live, >= activation_minutes
--     before start — `qr.activation_minutes_before`, default 30).
--   * The still-valid current token is returned unchanged; only a missing or
--     expired token is rotated: the previous rows are invalidated
--     (`expires_at = now()`) and a fresh token issued with
--     `qr.token_valid_seconds` (default 15) lifetime.
--   * Concurrent rotates serialize on a per-(event, user) advisory lock.
--
-- Contract (client: lib/core/services/event_service.dart `rotateQrToken`,
-- lib/features/qr/providers/qr_providers.dart `MyQrTokenNotifier`):
--   {status:'not_in_window'}  event missing/not upcoming/live/outside window
--   {status:'not_invited'}    no (non-declined) event_invites row
--   {status:'ok', token, expiresAt}
--
-- References: docs/implementation/phase-06-qr-system/QEDG-qr-edge-functions.md
-- §Function 2, docs/implementation/phase-05-events/EEDG, QRAT §Token Fetch
-- Cycle, docs/planification/samay_mvp_spec.md §6.4.

CREATE OR REPLACE FUNCTION public.rotate_qr_token(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_me uuid := auth.uid();
    v_activation_minutes integer;
    v_token_valid_seconds integer;
    v_event RECORD;
    v_token RECORD;
    v_invite RECORD;
BEGIN
    IF v_me IS NULL THEN
        RAISE EXCEPTION 'Not authorized';
    END IF;

    SELECT COALESCE(
        (SELECT value::integer FROM public.app_config
         WHERE key = 'qr.activation_minutes_before'), 30
    ) INTO v_activation_minutes;
    SELECT COALESCE(
        (SELECT value::integer FROM public.app_config
         WHERE key = 'qr.token_valid_seconds'), 15
    ) INTO v_token_valid_seconds;

    -- Activation window (QRAT / MVP §6.4): the QR exists only from
    -- `starts_at - activation_minutes` until the event ends.
    SELECT * INTO v_event FROM public.events WHERE id = p_event_id;
    IF NOT FOUND OR v_event.status NOT IN ('upcoming', 'live')
       OR now() < v_event.starts_at - make_interval(mins => v_activation_minutes)
       OR (v_event.ends_at IS NOT NULL AND now() > v_event.ends_at) THEN
        RETURN jsonb_build_object('status', 'not_in_window');
    END IF;

    -- Attendee gate: the QR is the attendee's own ticket.
    SELECT * INTO v_invite FROM public.event_invites
    WHERE event_id = p_event_id AND user_id = v_me;
    IF NOT FOUND OR v_invite.status = 'declined' THEN
        RETURN jsonb_build_object('status', 'not_invited');
    END IF;

    -- Serialize concurrent rotates for the same (event, user).
    PERFORM pg_advisory_xact_lock(hashtext(p_event_id::text || v_me::text));

    -- Return the still-valid current token; otherwise rotate.
    SELECT * INTO v_token FROM public.event_qr_tokens
    WHERE event_id = p_event_id AND user_id = v_me
    ORDER BY created_at DESC LIMIT 1;

    IF v_token.id IS NOT NULL
       AND v_token.expires_at > now()
       AND NOT v_token.attendance_confirmed THEN
        RETURN jsonb_build_object(
            'status', 'ok',
            'token', v_token.token,
            'expiresAt', v_token.expires_at
        );
    END IF;

    -- Invalidate the previous token(s) so a captured old QR dies instantly
    -- (QEDG rotation semantics), then issue the fresh one.
    UPDATE public.event_qr_tokens
    SET expires_at = now()
    WHERE event_id = p_event_id AND user_id = v_me
      AND expires_at > now();

    INSERT INTO public.event_qr_tokens (event_id, user_id, expires_at)
    VALUES (p_event_id, v_me, now() + make_interval(secs => v_token_valid_seconds))
    RETURNING token, expires_at INTO v_token.token, v_token.expires_at;

    RETURN jsonb_build_object(
        'status', 'ok',
        'token', v_token.token,
        'expiresAt', v_token.expires_at
    );
END;
$$;

REVOKE ALL ON FUNCTION public.rotate_qr_token(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rotate_qr_token(uuid) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.rotate_qr_token(uuid) TO authenticated;
