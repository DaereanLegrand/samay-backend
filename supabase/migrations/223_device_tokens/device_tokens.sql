-- Samay — 223_device_tokens/device_tokens.sql (2026-10-09)
--
-- Track-2 PUSH, step 1: device-token registration surface + push bookkeeping.
--
--   * public.device_tokens — one FCM registration token per row, owned by a
--     user. A token is device-scoped, so it can move between users (logout →
--     login); register upserts on the token and re-homes it.
--   * public.notifications.push_sent_at — set by the Go push worker once a
--     notification has been dispatched, so the worker only ever scans unsent
--     rows (partial index).
--
-- Client writes go through the SECURITY DEFINER RPCs only; the table has no
-- INSERT/UPDATE/DELETE policy. The worker uses service_role.
--
-- Push transport: FCM HTTP v1 for both Android and iOS (APNs is delivered by
-- FCM; the APNs key lives in the Firebase project, not here).

-- ── 1. push bookkeeping on notifications ───────────────────────────────────
ALTER TABLE ONLY public.notifications
    ADD COLUMN IF NOT EXISTS push_sent_at timestamp with time zone;

CREATE INDEX IF NOT EXISTS idx_notifications_push_unsent
    ON public.notifications USING btree (created_at)
    WHERE (push_sent_at IS NULL);

-- ── 2. device tokens ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.device_tokens (
    id           uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id      uuid NOT NULL,
    token        text NOT NULL,
    platform     text NOT NULL,
    created_at   timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT device_tokens_pkey PRIMARY KEY (id),
    CONSTRAINT device_tokens_token_key UNIQUE (token),
    CONSTRAINT device_tokens_platform_check CHECK (platform IN ('android', 'ios')),
    CONSTRAINT device_tokens_user_id_fkey FOREIGN KEY (user_id)
        REFERENCES public.users(id) ON DELETE CASCADE
);

ALTER TABLE ONLY public.device_tokens FORCE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_device_tokens_user
    ON public.device_tokens USING btree (user_id);

CREATE INDEX IF NOT EXISTS idx_device_tokens_last_seen
    ON public.device_tokens USING btree (last_seen_at);

-- ── 3. RLS: read own rows; writes only via the RPCs below ───────────────────
ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS device_tokens_select_own ON public.device_tokens;
CREATE POLICY device_tokens_select_own ON public.device_tokens
    FOR SELECT USING ((user_id = auth.uid()));

-- ── 4. client RPCs ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.register_device_token(
    p_token text,
    p_platform text
) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = 'P0001';
    END IF;
    IF p_token IS NULL OR btrim(p_token) = '' THEN
        RAISE EXCEPTION 'Token requerido.' USING ERRCODE = 'P0001';
    END IF;
    IF p_platform IS NULL OR p_platform NOT IN ('android', 'ios') THEN
        RAISE EXCEPTION 'Plataforma inválida.' USING ERRCODE = 'P0001';
    END IF;

    -- A device token is unique per install: re-homing it to the current user
    -- handles logout/login and reinstall on another account on the same device.
    INSERT INTO public.device_tokens (user_id, token, platform, last_seen_at)
    VALUES (v_uid, p_token, p_platform, now())
    ON CONFLICT (token) DO UPDATE
        SET user_id = excluded.user_id,
            platform = excluded.platform,
            last_seen_at = now();
END;
$$;

CREATE OR REPLACE FUNCTION public.unregister_device_token(p_token text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = 'P0001';
    END IF;
    IF p_token IS NULL OR btrim(p_token) = '' THEN
        RETURN;
    END IF;

    DELETE FROM public.device_tokens
    WHERE token = p_token AND user_id = v_uid;
END;
$$;

REVOKE ALL ON FUNCTION public.register_device_token(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.unregister_device_token(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_device_token(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unregister_device_token(text) TO authenticated;

-- ── 5. table ACL: clients read own rows; worker (service_role) full access ──
REVOKE ALL ON TABLE public.device_tokens FROM anon;
REVOKE ALL ON TABLE public.device_tokens FROM authenticated;
GRANT SELECT ON TABLE public.device_tokens TO authenticated;
GRANT ALL ON TABLE public.device_tokens TO service_role;
