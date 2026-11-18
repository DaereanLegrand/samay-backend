-- ============================================================================
-- 300_slim/01_onboarding.sql — slim-production onboarding
--
-- Account model in slim-prod:
--   * anonymous guest is the DEFAULT — GoTrue's anonymous sign-in creates an
--     auth.users row, then the client calls bootstrap_profile() to materialize
--     the public.users profile as a guest (is_guest = true, no DOB).
--   * Apple/Google linking is optional and later upgrades the same row in
--     place; confirm_my_account() flips is_guest = false once the user has a
--     provider-linked identity.
--   * age_confirmed_at + terms_accepted_at + terms_version record the
--     age-gate and Terms acceptance (product requirement, not a shard grant).
--
-- The legacy funnel (create_my_profile: username + DOB required) stays intact
-- for the paid/linked path; bootstrap_profile() is the guest path and writes
-- NO shard grants and NO signup_tracker rows.
--
-- Guests need date_of_birth to be nullable: the 233 Q17 NOT NULL + the
-- adult-DOB trigger apply to real accounts, so both are relaxed here for
-- is_guest rows only (a guest that links a provider later confirms the
-- account and sets a DOB through update_my_profile()).
--
-- Rollback: forward-fix only (dropping the columns would break every client
-- that already bootstrapped a guest).
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Onboarding columns.
-- ---------------------------------------------------------------------------
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS is_guest boolean NOT NULL DEFAULT false;
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS age_confirmed_at timestamp with time zone;
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS terms_accepted_at timestamp with time zone;
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS terms_version text;

COMMENT ON COLUMN public.users.is_guest IS
    'TRUE for a device-local anonymous guest profile created by bootstrap_profile(); confirm_my_account() flips it to FALSE after provider linking.';
COMMENT ON COLUMN public.users.age_confirmed_at IS
    'When the caller confirmed the 18+ age gate (slim onboarding). NULL = not onboarded.';
COMMENT ON COLUMN public.users.terms_accepted_at IS
    'When the caller accepted the Terms of Service version in terms_version. NULL = not onboarded.';
COMMENT ON COLUMN public.users.terms_version IS
    'The Terms of Service version string accepted by the caller (client-supplied, recorded verbatim).';

-- ---------------------------------------------------------------------------
-- 2. Guests may lack a date of birth.
--    The Q17 adult-DOB trigger and the NOT NULL column apply to real
--    accounts; a guest row is exempt until it is confirmed/linked.
-- ---------------------------------------------------------------------------
ALTER TABLE public.users ALTER COLUMN date_of_birth DROP NOT NULL;

CREATE OR REPLACE FUNCTION public.assert_adult_dob() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    -- 300_slim: a guest profile carries no DOB (age gate lives on
    -- age_confirmed_at); every non-guest row keeps the 18+ contract.
    IF NEW.date_of_birth IS NULL THEN
        IF COALESCE(NEW.is_guest, false) THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'La fecha de nacimiento es obligatoria.' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.date_of_birth > CURRENT_DATE - INTERVAL '18 years' THEN
        RAISE EXCEPTION 'Debes tener 18 años para usar Samay.' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.date_of_birth < DATE '1900-01-01' THEN
        RAISE EXCEPTION 'La fecha de nacimiento no es válida.' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_adult_dob() FROM PUBLIC;

DROP TRIGGER IF EXISTS users_adult_dob_trigger ON public.users;
CREATE TRIGGER users_adult_dob_trigger
    BEFORE INSERT OR UPDATE OF date_of_birth ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.assert_adult_dob();

-- ---------------------------------------------------------------------------
-- 3. is_onboarded() — the caller has accepted the age gate + Terms.
--    STABLE so the client/RLS can call it repeatedly per transaction.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_onboarded() RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
    v_ok boolean;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RETURN false;
    END IF;

    SELECT (age_confirmed_at IS NOT NULL AND terms_accepted_at IS NOT NULL)
      INTO v_ok
      FROM public.users
     WHERE id = v_uid;

    RETURN COALESCE(v_ok, false);
END;
$$;

REVOKE ALL ON FUNCTION public.is_onboarded() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_onboarded() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. bootstrap_profile(p_terms_version) — materialize the caller's profile.
--    Idempotent: a second call on an already-onboarded row is a no-op that
--    still reports 'ok'. A brand-new caller becomes a guest with a random
--    'invitado-NNNN' handle (retried on the username UNIQUE collision).
--    Writes NO shard ledger rows and NO signup_tracker rows.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bootstrap_profile(p_terms_version text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
    v_version text;
    v_has_row boolean;
    v_terms_done boolean;
    v_attempt integer := 1;
    v_username text;
BEGIN
    -- 1. Authentication gate (anon-role GoTrue sessions are authenticated).
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Terms version is mandatory — it is recorded verbatim.
    v_version := NULLIF(btrim(p_terms_version), '');
    IF v_version IS NULL THEN
        RETURN jsonb_build_object('status', 'invalid_terms_version');
    END IF;

    -- 3. Existing profile.
    SELECT TRUE, (terms_accepted_at IS NOT NULL AND age_confirmed_at IS NOT NULL)
      INTO v_has_row, v_terms_done
      FROM public.users
     WHERE id = v_uid;

    IF COALESCE(v_has_row, false) THEN
        -- 3a. Already onboarded: idempotent success, nothing to write.
        IF COALESCE(v_terms_done, false) THEN
            RETURN jsonb_build_object(
                'status', 'ok', 'profile_id', v_uid, 'created', false);
        END IF;

        -- 3b. Legacy/partial row: record acceptance in place.
        UPDATE public.users
           SET age_confirmed_at = COALESCE(age_confirmed_at, now()),
               terms_accepted_at = COALESCE(terms_accepted_at, now()),
               terms_version = v_version
         WHERE id = v_uid;

        RETURN jsonb_build_object(
            'status', 'ok', 'profile_id', v_uid, 'created', false);
    END IF;

    -- 4. New caller: insert the guest row. The random handle is retried on a
    --    UNIQUE(username) collision, up to 25 attempts.
    LOOP
        v_username := 'invitado-' || lpad((floor(random() * 10000))::integer::text, 4, '0');
        IF char_length(v_username) < 5 THEN
            CONTINUE; -- defensive: never violate assert_username_shape
        END IF;

        BEGIN
            INSERT INTO public.users (
                id, username, avatar_url, date_of_birth, bio,
                banned_at, ban_reason, deleted_at,
                personal_shards, preshards, subscription_tier,
                subscription_expires_at,
                interest_tags, discovery_opt_in, read_receipts_enabled,
                profile_public,
                is_guest, age_confirmed_at, terms_accepted_at, terms_version,
                created_at, updated_at
            ) VALUES (
                v_uid, v_username, NULL, NULL, NULL,
                NULL, NULL, NULL,
                0, 0, 'free',
                NULL,
                '{}', false, true,
                false,
                true, now(), now(), v_version,
                now(), now()
            );

            RETURN jsonb_build_object(
                'status', 'created', 'profile_id', v_uid, 'created', true);
        EXCEPTION WHEN unique_violation THEN
            v_attempt := v_attempt + 1;
            IF v_attempt > 25 THEN
                RAISE EXCEPTION 'No se pudo generar un nombre de usuario.'
                    USING ERRCODE = 'P0001';
            END IF;
        END;
    END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.bootstrap_profile(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bootstrap_profile(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. confirm_my_account() — the caller's guest row becomes a real account.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirm_my_account() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- A profile row is required before an account can be confirmed.
    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_uid) THEN
        RETURN jsonb_build_object('status', 'profile_required');
    END IF;

    UPDATE public.users
       SET is_guest = false
     WHERE id = v_uid;

    RETURN jsonb_build_object('status', 'ok');
END;
$$;

REVOKE ALL ON FUNCTION public.confirm_my_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_my_account() TO authenticated, service_role;

COMMIT;
