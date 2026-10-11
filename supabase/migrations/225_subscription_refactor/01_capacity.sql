-- Samay — 225_subscription_refactor/01_capacity.sql
--
-- Event attendee capacity now follows the SUBSCRIPTION tier (free/pro/vip),
-- not the retired `entitlement_tier` dimension:
--   * app_config: events.{free,pro,vip}_max_attendees (free default 7).
--   * assert_event_capacity() reads users.subscription_tier.
--   * users.entitlement_tier + the entitlement_tier enum are dropped; every
--     function that referenced it is rewritten here FIRST.

-- 1. Retire the legacy t-axis capacity keys (seed-config.sql is the source of
--    truth for a fresh DB; this clears any pre-existing rows).
DELETE FROM public.app_config WHERE key IN
    ('events.t2_max_attendees', 'events.t1_max_attendees', 'events.t0_max_attendees');

-- 2. Subscription-tier capacity keys (idempotent).
INSERT INTO public.app_config (key, value, description, default_value) VALUES
    ('events.free_max_attendees', '7',    'Max total people per event when the creator is on the free plan', '7'),
    ('events.pro_max_attendees',  '56',   'Max total people per event when the creator is on PRO', '56'),
    ('events.vip_max_attendees',  '1120', 'Max total people per event when the creator is on VIP', '1120')
ON CONFLICT (key) DO NOTHING;

-- 3. Capacity trigger -> subscription_tier.
CREATE OR REPLACE FUNCTION public.assert_event_capacity() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_allowed integer;
    v_used integer;
BEGIN
    -- The tier cap comes from app_config, keyed on the CREATOR's current
    -- subscription_tier (default: free = 7). Runs for every insert path
    -- (RPC, service_role seeds, admin), so capacity can never exceed tier.
    SELECT COALESCE(value::integer, 7) INTO v_allowed
    FROM public.app_config
    WHERE key = (
        SELECT CASE (
            SELECT subscription_tier FROM public.users WHERE id = NEW.created_by_user_id
        )
            WHEN 'pro'::public.subscription_tier THEN 'events.pro_max_attendees'
            WHEN 'vip'::public.subscription_tier THEN 'events.vip_max_attendees'
            ELSE 'events.free_max_attendees'
        END
    );

    IF v_allowed IS NULL THEN
        v_allowed := 7;
    END IF;

    IF NEW.capacity IS NULL THEN
        NEW.capacity := v_allowed;
    ELSIF NEW.capacity < 1 OR NEW.capacity > v_allowed THEN
        RAISE EXCEPTION 'capacity_exceeds_tier' USING ERRCODE = 'P0001';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        v_used := public.event_seats_used(NEW.id);
        IF NEW.capacity < v_used THEN
            RAISE EXCEPTION 'capacity_below_used' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- 4. Protected-columns trigger: entitlement_tier removed from the guard.
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
        NEW.banned_at := NULL;
        NEW.ban_reason := NULL;
        NEW.deleted_at := NULL;
        RETURN NEW;
    END IF;

    IF NEW.personal_shards = OLD.personal_shards
        AND NEW.preshards = OLD.preshards
        AND NEW.subscription_tier = OLD.subscription_tier
        AND NEW.subscription_expires_at IS NOT DISTINCT FROM OLD.subscription_expires_at
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

    RAISE EXCEPTION 'users protected columns (personal_shards, preshards, subscription_tier, subscription_expires_at, banned_at, ban_reason, deleted_at, date_of_birth) may only be changed by a privileged role';
END;
$$;

-- 5. create_my_profile: insert without entitlement_tier.
CREATE OR REPLACE FUNCTION public.create_my_profile(p_username text, p_date_of_birth date) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
    v_username text;
    v_shards integer;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = 'P0001';
    END IF;

    v_username := public.sanitize_username(p_username);
    PERFORM public.assert_username_shape(v_username);
    PERFORM public.assert_date_of_birth(p_date_of_birth);

    IF EXISTS (SELECT 1 FROM public.users WHERE id = v_uid) THEN
        RAISE EXCEPTION 'Tu perfil ya existe.' USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(value::integer, 0) INTO v_shards
    FROM public.app_config WHERE key = 'economy.user_signup_shards';

    INSERT INTO public.users (
        id, username, avatar_url, date_of_birth, bio,
        banned_at, ban_reason, deleted_at,
        personal_shards, preshards, subscription_tier, subscription_expires_at,
        interest_tags, discovery_opt_in, read_receipts_enabled, profile_public,
        created_at, updated_at
    ) VALUES (
        v_uid, v_username, NULL, p_date_of_birth, NULL,
        NULL, NULL, NULL,
        COALESCE(v_shards, 0), 0, 'free', NULL,
        '{}', false, true, false,
        now(), now()
    );

    INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id, created_at)
    VALUES (v_uid, COALESCE(v_shards, 0), 'admin_grant', NULL, now());
END;
$$;

-- 6. Drop the column + enum (all referencing functions rewritten above).
ALTER TABLE public.users DROP COLUMN IF EXISTS entitlement_tier;
DROP TYPE IF EXISTS public.entitlement_tier;
