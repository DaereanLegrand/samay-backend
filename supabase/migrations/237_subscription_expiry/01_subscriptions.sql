-- ============================================================================
-- 237_subscription_expiry/01_subscriptions.sql — E2 subscriptions
--
-- 1. Paid access = tier <> 'free' AND a live expiry, with a 24-hour action
--    grace after a normal expiry. NULL expiry never grants paid access.
-- 2. Lifetime is removed: every grant/override is capped at 1 year from the
--    grant time; past expiries are rejected. Invalid non-free rows are
--    auto-downgraded with an audit row (content is never touched).
-- 3. PAUSED / BILLING_ISSUE extend paid actions to the later of the stored
--    expiry or event + 7 days (users.subscription_grace_until).
--    REFUND / chargeback downgrade immediately (the webhook passes tier=free).
-- 4. TRANSFER is handled by the webhook/retry worker resyncing both accounts.
-- 5. Admin overrides are time-limited, 1-year capped, require a reason, and
--    are audited on grant/revoke.
-- 6. One source of truth: `has_paid_access(uuid)` / `effective_tier(uuid)`.
--
-- Rollback: forward-fix only. Reinstating lifetime or removing the grace
-- columns would require a new owner decision.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Subscription provenance + grace columns.
-- ---------------------------------------------------------------------------
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS subscription_source text NOT NULL DEFAULT 'none';
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS subscription_grace_until timestamp with time zone;

COMMENT ON COLUMN public.users.subscription_source IS
    'E2: none | revenuecat | admin. Distinguishes a RevenueCat entitlement from a time-limited admin override.';
COMMENT ON COLUMN public.users.subscription_grace_until IS
    'E2: PAUSED/BILLING_ISSUE access floor (later of expiry or event + 7 days). Cleared by a grant or downgrade.';

-- Protect the new server-managed columns from client writes.
CREATE OR REPLACE FUNCTION public.assert_safe_user_update() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    v_privileged boolean;
BEGIN
    SELECT rolbypassrls OR rolsuper INTO v_privileged
    FROM pg_catalog.pg_roles
    WHERE rolname = current_user;

    IF COALESCE(v_privileged, false) THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        NEW.personal_shards := COALESCE(
            (SELECT value::integer FROM public.app_config WHERE key = 'economy.user_signup_shards'),
            0
        );
        NEW.preshards := 0;
        NEW.subscription_tier := 'free'::public.subscription_tier;
        NEW.subscription_expires_at := NULL;
        NEW.subscription_source := 'none';
        NEW.subscription_grace_until := NULL;
        NEW.banned_at := NULL;
        NEW.ban_reason := NULL;
        NEW.deleted_at := NULL;
        RETURN NEW;
    END IF;

    IF NEW.personal_shards = OLD.personal_shards
        AND NEW.preshards = OLD.preshards
        AND NEW.subscription_tier = OLD.subscription_tier
        AND NEW.subscription_expires_at IS NOT DISTINCT FROM OLD.subscription_expires_at
        AND NEW.subscription_source = OLD.subscription_source
        AND NEW.subscription_grace_until IS NOT DISTINCT FROM OLD.subscription_grace_until
        AND NEW.banned_at IS NOT DISTINCT FROM OLD.banned_at
        AND NEW.ban_reason IS NOT DISTINCT FROM OLD.ban_reason
        AND NEW.date_of_birth IS NOT DISTINCT FROM OLD.date_of_birth
        AND (
            NEW.deleted_at IS NOT DISTINCT FROM OLD.deleted_at
            OR (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
        )
    THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'users protected columns (personal_shards, preshards, subscription_tier, subscription_expires_at, subscription_source, subscription_grace_until, banned_at, ban_reason, deleted_at, date_of_birth) may only be changed by a privileged role';
END;
$$;

-- Retry scheduler columns for the billing worker (E2/Q28).
ALTER TABLE public.webhook_failures
    ADD COLUMN IF NOT EXISTS next_attempt_at timestamp with time zone DEFAULT now();
ALTER TABLE public.webhook_failures
    ADD COLUMN IF NOT EXISTS resolved_at timestamp with time zone;
CREATE INDEX IF NOT EXISTS idx_webhook_failures_due
    ON public.webhook_failures (next_attempt_at)
    WHERE resolved = false;

-- ---------------------------------------------------------------------------
-- 2. The single paid-access helpers.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.has_paid_access(p_user uuid)
RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT EXISTS (
        SELECT 1
          FROM public.users u
         WHERE u.id = p_user
           AND u.subscription_tier <> 'free'
           AND u.subscription_expires_at IS NOT NULL
           AND (
                u.subscription_expires_at + interval '24 hours' > now()
                OR (u.subscription_grace_until IS NOT NULL
                    AND u.subscription_grace_until > now())
           )
    );
$$;

CREATE OR REPLACE FUNCTION public.effective_tier(p_user uuid)
RETURNS public.subscription_tier
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT CASE
        WHEN public.has_paid_access(p_user) THEN u.subscription_tier
        ELSE 'free'::public.subscription_tier
    END
      FROM public.users u
     WHERE u.id = p_user;
$$;

REVOKE ALL ON FUNCTION public.has_paid_access(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.effective_tier(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.has_paid_access(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.effective_tier(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Privileged writes: RevenueCat state, grace, downgrade.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.apply_subscription_state(uuid, public.subscription_tier, timestamp with time zone, text);

CREATE OR REPLACE FUNCTION public.apply_subscription_state(
    p_user uuid,
    p_tier public.subscription_tier,
    p_expires timestamp with time zone,
    p_event_type text,
    p_event_at timestamp with time zone DEFAULT now(),
    p_source text DEFAULT 'revenuecat'
) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_system_admin uuid := '00000000-0000-0000-0000-000000000000';
    v_before jsonb;
    v_capped timestamp with time zone;
    v_source text := CASE WHEN p_source = 'admin' THEN 'admin' ELSE 'revenuecat' END;
BEGIN
    SELECT jsonb_build_object(
               'tier', subscription_tier,
               'expires_at', subscription_expires_at,
               'source', subscription_source,
               'grace_until', subscription_grace_until)
      INTO v_before
      FROM public.users WHERE id = p_user;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown_user' USING ERRCODE = 'P0001';
    END IF;

    IF p_tier = 'free' THEN
        -- REFUND/chargeback and EXPIRATION land here: immediate, no grace.
        UPDATE public.users
           SET subscription_tier = 'free',
               subscription_expires_at = NULL,
               subscription_source = 'none',
               subscription_grace_until = NULL,
               updated_at = now()
         WHERE id = p_user;
    ELSE
        IF p_expires IS NULL THEN
            RAISE EXCEPTION 'invalid_expiry' USING ERRCODE = 'P0001';
        END IF;
        IF p_expires <= now() THEN
            RAISE EXCEPTION 'invalid_expiry' USING ERRCODE = 'P0001';
        END IF;
        -- New grant: 1 year from now. Renewal extends (a later expiry still
        -- passes through, capped only if it exceeds one year).
        v_capped := LEAST(p_expires, now() + interval '1 year');
        UPDATE public.users
           SET subscription_tier = p_tier,
               subscription_expires_at = v_capped,
               subscription_source = v_source,
               subscription_grace_until = NULL,
               updated_at = now()
         WHERE id = p_user;
    END IF;

    INSERT INTO public.admin_audit_log
        (admin_user_id, action, target_type, target_id, details)
    VALUES (
        v_system_admin,
        'subscription_' || lower(COALESCE(NULLIF(p_event_type, ''), 'sync')),
        'subscription',
        p_user::text,
        jsonb_build_object(
            'source', v_source,
            'event_type', p_event_type,
            'event_at', p_event_at,
            'before', v_before,
            'after', jsonb_build_object(
                'tier', p_tier,
                'expires_at', CASE WHEN p_tier = 'free' THEN NULL ELSE v_capped END,
                'source', CASE WHEN p_tier = 'free' THEN 'none' ELSE v_source END,
                'grace_until', NULL)));
END;
$$;

REVOKE ALL ON FUNCTION public.apply_subscription_state(uuid, public.subscription_tier, timestamp with time zone, text, timestamp with time zone, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_subscription_state(uuid, public.subscription_tier, timestamp with time zone, text, timestamp with time zone, text)
    TO service_role;

CREATE OR REPLACE FUNCTION public.apply_subscription_grace(
    p_user uuid,
    p_event_type text,
    p_event_at timestamp with time zone DEFAULT now()
) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_system_admin uuid := '00000000-0000-0000-0000-000000000000';
    v_tier public.subscription_tier;
    v_expires timestamp with time zone;
    v_grace timestamp with time zone;
    v_floor timestamp with time zone;
BEGIN
    SELECT subscription_tier, subscription_expires_at, subscription_grace_until
      INTO v_tier, v_expires, v_grace
      FROM public.users WHERE id = p_user;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown_user' USING ERRCODE = 'P0001';
    END IF;
    IF v_tier = 'free' THEN
        RETURN;
    END IF;

    -- Later of the stored expiry or 7 days after the billing event.
    v_floor := GREATEST(
        COALESCE(v_expires, now()),
        COALESCE(v_grace, now()),
        COALESCE(p_event_at, now()) + interval '7 days');

    UPDATE public.users
       SET subscription_grace_until = v_floor,
           updated_at = now()
     WHERE id = p_user;

    INSERT INTO public.admin_audit_log
        (admin_user_id, action, target_type, target_id, details)
    VALUES (
        v_system_admin,
        'subscription_' || lower(COALESCE(NULLIF(p_event_type, ''), 'grace')),
        'subscription',
        p_user::text,
        jsonb_build_object(
            'source', 'revenuecat',
            'event_type', p_event_type,
            'event_at', p_event_at,
            'before', jsonb_build_object('expires_at', v_expires, 'grace_until', v_grace),
            'after', jsonb_build_object('grace_until', v_floor)));
END;
$$;

REVOKE ALL ON FUNCTION public.apply_subscription_grace(uuid, text, timestamp with time zone)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_subscription_grace(uuid, text, timestamp with time zone)
    TO service_role;

CREATE OR REPLACE FUNCTION public.downgrade_invalid_subscriptions()
RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_system_admin uuid := '00000000-0000-0000-0000-000000000000';
    r RECORD;
    n integer := 0;
BEGIN
    FOR r IN
        SELECT id, subscription_tier, subscription_expires_at,
               subscription_source, subscription_grace_until
          FROM public.users
         WHERE subscription_tier <> 'free'
           AND NOT public.has_paid_access(id)
    LOOP
        UPDATE public.users
           SET subscription_tier = 'free',
               subscription_expires_at = NULL,
               subscription_source = 'none',
               subscription_grace_until = NULL,
               updated_at = now()
         WHERE id = r.id;

        INSERT INTO public.admin_audit_log
            (admin_user_id, action, target_type, target_id, details)
        VALUES (
            v_system_admin,
            'subscription_auto_downgrade',
            'subscription',
            r.id::text,
            jsonb_build_object(
                'source', 'system',
                'reason', CASE
                    WHEN r.subscription_expires_at IS NULL THEN 'null_expiry'
                    ELSE 'expired_grace'
                END,
                'before', jsonb_build_object(
                    'tier', r.subscription_tier,
                    'expires_at', r.subscription_expires_at,
                    'source', r.subscription_source,
                    'grace_until', r.subscription_grace_until),
                'after', jsonb_build_object(
                    'tier', 'free', 'expires_at', NULL,
                    'source', 'none', 'grace_until', NULL)));
        n := n + 1;
    END LOOP;
    RETURN n;
END;
$$;

REVOKE ALL ON FUNCTION public.downgrade_invalid_subscriptions()
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.downgrade_invalid_subscriptions() TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Admin overrides (time-limited only, audited).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_grant_subscription(
    p_user uuid,
    p_tier public.subscription_tier,
    p_expires timestamp with time zone,
    p_reason text,
    p_admin_user_id uuid DEFAULT '00000000-0000-0000-0000-000000000000'
) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_capped timestamp with time zone;
BEGIN
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'reason_required' USING ERRCODE = 'P0001';
    END IF;
    IF p_tier = 'free' THEN
        RAISE EXCEPTION 'free_is_not_a_grant' USING ERRCODE = 'P0001';
    END IF;
    IF p_expires IS NULL OR p_expires <= now() THEN
        RAISE EXCEPTION 'invalid_expiry' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.admin_users WHERE id = p_admin_user_id) THEN
        RAISE EXCEPTION 'unknown_admin' USING ERRCODE = 'P0001';
    END IF;

    v_capped := LEAST(p_expires, now() + interval '1 year');

    INSERT INTO public.subscription_overrides
        (user_id, admin_user_id, tier, expires_at, reason)
    VALUES (p_user, p_admin_user_id, p_tier, v_capped, btrim(p_reason));

    PERFORM public.apply_subscription_state(
        p_user, p_tier, v_capped, 'admin_grant',
        now(),
        'admin');

    INSERT INTO public.admin_audit_log
        (admin_user_id, action, target_type, target_id, details)
    VALUES (
        p_admin_user_id,
        'subscription_override_grant',
        'subscription',
        p_user::text,
        jsonb_build_object(
            'reason', btrim(p_reason),
            'tier', p_tier,
            'expires_at', v_capped,
            'source', 'admin'));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_grant_subscription(uuid, public.subscription_tier, timestamp with time zone, text, uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_grant_subscription(uuid, public.subscription_tier, timestamp with time zone, text, uuid)
    TO service_role;

CREATE OR REPLACE FUNCTION public.admin_revoke_subscription(
    p_user uuid,
    p_reason text,
    p_admin_user_id uuid DEFAULT '00000000-0000-0000-0000-000000000000'
) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_source text;
BEGIN
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'reason_required' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.admin_users WHERE id = p_admin_user_id) THEN
        RAISE EXCEPTION 'unknown_admin' USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.subscription_overrides
       SET revoked = true
     WHERE user_id = p_user AND revoked = false;

    SELECT subscription_source INTO v_source
      FROM public.users WHERE id = p_user;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown_user' USING ERRCODE = 'P0001';
    END IF;

    IF v_source = 'admin' THEN
        PERFORM public.apply_subscription_state(
            p_user, 'free', NULL, 'admin_revoke', now(), 'admin');
    END IF;

    INSERT INTO public.admin_audit_log
        (admin_user_id, action, target_type, target_id, details)
    VALUES (
        p_admin_user_id,
        'subscription_override_revoke',
        'subscription',
        p_user::text,
        jsonb_build_object('reason', btrim(p_reason), 'source', v_source));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_revoke_subscription(uuid, text, uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_revoke_subscription(uuid, text, uuid)
    TO service_role;

-- ---------------------------------------------------------------------------
-- 5. SOVR reconciler: RevenueCat always wins; auto-downgrade invalid rows.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reconcile_subscription_overrides()
RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    r RECORD;
    n integer := 0;
BEGIN
    -- 1. Active overrides with no live RevenueCat entitlement -> apply.
    FOR r IN
        SELECT o.user_id, o.tier, o.expires_at
          FROM public.subscription_overrides o
          JOIN public.users u ON u.id = o.user_id
         WHERE o.revoked = false
           AND o.expires_at > now()
           AND NOT (u.subscription_source = 'revenuecat'
                    AND u.subscription_expires_at > now())
           AND (u.subscription_tier IS DISTINCT FROM o.tier
                OR u.subscription_expires_at IS DISTINCT FROM o.expires_at
                OR u.subscription_source IS DISTINCT FROM 'admin')
    LOOP
        PERFORM public.apply_subscription_state(
            r.user_id, r.tier,
            LEAST(r.expires_at, now() + interval '1 year'),
            'override_reconcile', now(), 'admin');
        n := n + 1;
    END LOOP;

    -- 2. Admin-sourced rows with no active override -> free.
    FOR r IN
        SELECT u.id
          FROM public.users u
         WHERE u.subscription_source = 'admin'
           AND NOT public.has_paid_access(u.id)
           AND NOT EXISTS (
               SELECT 1 FROM public.subscription_overrides a
                WHERE a.user_id = u.id AND a.revoked = false AND a.expires_at > now())
    LOOP
        PERFORM public.apply_subscription_state(
            r.id, 'free', NULL, 'override_expired', now(), 'admin');
        n := n + 1;
    END LOOP;

    -- 3. Any other non-free row past its access window.
    n := n + public.downgrade_invalid_subscriptions();
    RETURN n;
END;
$$;

REVOKE ALL ON FUNCTION public.reconcile_subscription_overrides()
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reconcile_subscription_overrides() TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Schedules.
-- ---------------------------------------------------------------------------
DO $job$ BEGIN
    PERFORM cron.schedule('subscriptions-reconcile-overrides', '*/15 * * * *',
        $cmd$SELECT public.reconcile_subscription_overrides();$cmd$);
END $job$;

DO $job$ BEGIN
    PERFORM cron.schedule('subscriptions-downgrade-invalid', '*/10 * * * *',
        $cmd$SELECT public.downgrade_invalid_subscriptions();$cmd$);
END $job$;

COMMIT;
