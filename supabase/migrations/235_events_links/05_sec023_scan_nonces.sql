-- ============================================================================
-- 235_events_links / 05_sec023_scan_nonces.sql — SEC-023 QR replay hardening.
--
-- `validate_code` already confirms an attendee exactly once (the unique
-- event_attendances row is the terminal marker). This migration adds the
-- auditable one-time nonce + time-window log the replay investigation needs:
-- every confirmed scan writes an unguessable nonce tied to the event, the
-- attendee and the 30s code window. The UNIQUE(event_id, user_id) constraint
-- makes a duplicated confirmation impossible even if a future code path
-- forgets the attendance check, and the nonce gives operators a value they
-- can correlate with a device screenshot without storing the code itself.
--
-- Rollback:
--   DROP TRIGGER scan_nonce_on_attendance ON public.event_attendances;
--   DROP FUNCTION public.record_event_scan_nonce();
--   DROP TABLE public.event_scan_nonces;
-- Forward-fix: extend the log columns only; never make it client-writable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.event_scan_nonces (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_id uuid NOT NULL,
    user_id uuid NOT NULL,
    nonce text NOT NULL,
    window_counter bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT event_scan_nonces_pkey PRIMARY KEY (id),
    CONSTRAINT event_scan_nonces_nonce_key UNIQUE (nonce),
    CONSTRAINT event_scan_nonces_event_user_key UNIQUE (event_id, user_id),
    CONSTRAINT event_scan_nonces_event_id_fkey
        FOREIGN KEY (event_id) REFERENCES public.events(id) ON DELETE CASCADE,
    CONSTRAINT event_scan_nonces_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_event_scan_nonces_event
    ON public.event_scan_nonces USING btree (event_id);
CREATE INDEX IF NOT EXISTS idx_event_scan_nonces_created
    ON public.event_scan_nonces USING btree (created_at);

ALTER TABLE public.event_scan_nonces ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_scan_nonces FORCE ROW LEVEL SECURITY;
-- No policies: operational/audit data only.

REVOKE ALL ON TABLE public.event_scan_nonces FROM anon;
REVOKE ALL ON TABLE public.event_scan_nonces FROM authenticated;
REVOKE ALL ON TABLE public.event_scan_nonces FROM service_role;

CREATE OR REPLACE FUNCTION public.record_event_scan_nonce()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_window integer;
BEGIN
    SELECT COALESCE(
        (SELECT value::integer FROM public.app_config
          WHERE key = 'code.window_seconds'), 30
    ) INTO v_window;
    IF v_window < 5 THEN
        v_window := 30;
    END IF;

    INSERT INTO public.event_scan_nonces (
        event_id, user_id, nonce, window_counter
    ) VALUES (
        NEW.event_id,
        NEW.user_id,
        encode(extensions.gen_random_bytes(16), 'hex'),
        floor(extract(epoch FROM now()) / v_window)::bigint
    )
    ON CONFLICT (event_id, user_id) DO NOTHING;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS scan_nonce_on_attendance ON public.event_attendances;
CREATE TRIGGER scan_nonce_on_attendance
    AFTER INSERT ON public.event_attendances
    FOR EACH ROW EXECUTE FUNCTION public.record_event_scan_nonce();

REVOKE ALL ON FUNCTION public.record_event_scan_nonce() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_event_scan_nonce() FROM authenticated;
REVOKE ALL ON FUNCTION public.record_event_scan_nonce() FROM service_role;
