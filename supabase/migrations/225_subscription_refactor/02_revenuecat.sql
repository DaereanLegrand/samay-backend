-- Samay — 225_subscription_refactor/02_revenuecat.sql
--
-- RevenueCat subscription state (RCBH + SOVR server side):
--   * webhook_failures — retry queue for transient webhook processing errors.
--   * apply_subscription_state() — the single privileged write path from the
--     `revenuecat-webhook` Edge Function (sets tier + expiry, audits).
--   * reconcile_subscription_overrides() — SOVR reconciler ("RevenueCat wins"):
--     applies admin overrides only when the user has no active subscription,
--     and resets expired/revoked overrides back to free. Scheduled every 15 min.
--
-- RC itself has no production/sandbox "environment": the active-subscription
-- test is `users.subscription_expires_at > now()`, kept current by the webhook.

-- ── retry queue ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.webhook_failures (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id text NOT NULL,
    event_type text,
    payload jsonb,
    last_error text,
    attempts integer DEFAULT 0 NOT NULL,
    resolved boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE ONLY public.webhook_failures FORCE ROW LEVEL SECURITY;
ALTER TABLE public.webhook_failures ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS webhook_failures_no_access ON public.webhook_failures;
CREATE POLICY webhook_failures_no_access ON public.webhook_failures USING (false);
CREATE INDEX IF NOT EXISTS idx_webhook_failures_event ON public.webhook_failures USING btree (event_id);

-- ── privileged write path (called by the Edge Function with service_role) ────
CREATE OR REPLACE FUNCTION public.apply_subscription_state(
    p_user uuid,
    p_tier public.subscription_tier,
    p_expires timestamp with time zone,
    p_event_type text
) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_system_admin uuid := '00000000-0000-0000-0000-000000000000';
BEGIN
    UPDATE public.users
       SET subscription_tier = p_tier,
           subscription_expires_at = p_expires,
           updated_at = now()
     WHERE id = p_user;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown_user' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO public.admin_audit_log (admin_user_id, action, target_type, target_id, details)
    VALUES (
        v_system_admin,
        'revenuecat_' || lower(COALESCE(NULLIF(p_event_type, ''), 'sync')),
        'subscription',
        p_user::text,
        jsonb_build_object('tier', p_tier, 'expires_at', p_expires)
    );
END;
$$;

-- ── SOVR reconciler ("RevenueCat always wins") ───────────────────────────────
CREATE OR REPLACE FUNCTION public.reconcile_subscription_overrides() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    r record;
    n integer := 0;
BEGIN
    -- 1. Active overrides with NO active RevenueCat subscription -> apply.
    FOR r IN
        SELECT o.user_id, o.tier, o.expires_at
        FROM public.subscription_overrides o
        JOIN public.users u ON u.id = o.user_id
        WHERE o.revoked = false
          AND o.expires_at > now()
          AND (u.subscription_expires_at IS NULL OR u.subscription_expires_at <= now())
          AND (u.subscription_tier IS DISTINCT FROM o.tier
               OR u.subscription_expires_at IS DISTINCT FROM o.expires_at)
    LOOP
        UPDATE public.users
           SET subscription_tier = r.tier,
               subscription_expires_at = r.expires_at,
               updated_at = now()
         WHERE id = r.user_id;
        n := n + 1;
    END LOOP;

    -- 2. Expired/revoked overrides (no active RC sub, no other active override)
    --    whose tier is still elevated -> reset to free.
    FOR r IN
        SELECT DISTINCT u.id AS user_id
        FROM public.users u
        WHERE u.subscription_tier <> 'free'
          AND (u.subscription_expires_at IS NULL OR u.subscription_expires_at <= now())
          AND EXISTS (
              SELECT 1 FROM public.subscription_overrides o
              WHERE o.user_id = u.id AND (o.revoked = true OR o.expires_at <= now()))
          AND NOT EXISTS (
              SELECT 1 FROM public.subscription_overrides a
              WHERE a.user_id = u.id AND a.revoked = false AND a.expires_at > now())
    LOOP
        UPDATE public.users
           SET subscription_tier = 'free',
               subscription_expires_at = NULL,
               updated_at = now()
         WHERE id = r.user_id;
        n := n + 1;
    END LOOP;

    RETURN n;
END;
$$;

-- ── cron: every 15 minutes ───────────────────────────────────────────────────
DO $job$ BEGIN
  PERFORM cron.schedule('subscriptions-reconcile-overrides', '*/15 * * * *',
    $cmd$SELECT public.reconcile_subscription_overrides();$cmd$);
END $job$;

-- ── grants ───────────────────────────────────────────────────────────────────
GRANT ALL ON TABLE public.webhook_failures TO service_role;
GRANT ALL ON FUNCTION public.apply_subscription_state(uuid, public.subscription_tier, timestamp with time zone, text) TO service_role;
GRANT ALL ON FUNCTION public.reconcile_subscription_overrides() TO service_role;
