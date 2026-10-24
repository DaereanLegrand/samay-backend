-- ============================================================================
-- 233_identity_privacy / 01_dob.sql — Q17 age assurance
--
-- Q17 (owner decision): date of birth is required on every account-creation
-- path, and the server enforces 18+ on creation and on any DOB change. No ID
-- document, face scan, or age-estimation vendor is used; reports are the only
-- path that reaches manual review.
--
-- Lock/backfill note:
--   * ACCESS EXCLUSIVE is held while the column is backfilled and while the
--     NOT NULL constraint is added. Run in a maintenance window on a large
--     users table.
--   * Legacy rows with NULL DOB (the pre-funnel accounts) are preserved by
--     writing the sentinel DATE '1900-01-01' and setting
--     users.date_of_birth_backfilled = true. The sentinel is NOT a claim about
--     the person: it keeps the account usable and is corrected once through
--     update_my_profile(), which clears the flag and re-checks 18+.
--     This is the documented validation path; no user is silently deleted.
--   * New rows cannot use the sentinel as a bypass: the 18+ trigger runs on
--     INSERT and UPDATE OF date_of_birth for every role, including
--     service_role and the admin CLI.
--
-- Rollback / forward-fix:
--   This migration is forward-fix only once the backfill has run in an
--   environment with real accounts. Dropping the NOT NULL/trigger and
--   restoring the 221 bodies would re-open Q17 and must not be done. A
--   correction to the sentinel policy is a new migration.
-- ============================================================================

BEGIN;

ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS date_of_birth_backfilled boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.users.date_of_birth_backfilled IS
    'Q17: true only for legacy accounts backfilled with the 1900-01-01 sentinel. update_my_profile() lets the owner set a real DOB once and clears this flag.';

-- Backfill before NOT NULL. The WHERE is intentionally narrow: only rows that
-- predate the age-gate funnel can be NULL.
UPDATE public.users
   SET date_of_birth = DATE '1900-01-01',
       date_of_birth_backfilled = true,
       updated_at = now()
 WHERE date_of_birth IS NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.users'::regclass
          AND conname = 'users_date_of_birth_range'
    ) THEN
        ALTER TABLE public.users
            ADD CONSTRAINT users_date_of_birth_range
            CHECK (date_of_birth >= DATE '1900-01-01') NOT VALID;
    END IF;
END
$$;
ALTER TABLE public.users VALIDATE CONSTRAINT users_date_of_birth_range;

-- One trigger for every writer. assert_safe_user_update() intentionally
-- bypasses privileged roles for economy columns; this trigger must NOT bypass
-- them, otherwise service_role/admin paths could create underage accounts.
CREATE OR REPLACE FUNCTION public.assert_adult_dob() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    IF NEW.date_of_birth IS NULL THEN
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

ALTER TABLE public.users ALTER COLUMN date_of_birth SET NOT NULL;

COMMENT ON COLUMN public.users.date_of_birth IS
    'Q17: required for every account. 18+ enforced by users_adult_dob_trigger on INSERT and UPDATE OF date_of_birth. Set-once through update_my_profile(), except the one-time correction of a backfilled legacy row.';

-- The RPC already validated DOB, but the backfilled-account path must be able
-- to replace the sentinel exactly once. Everything else keeps set-once.
CREATE OR REPLACE FUNCTION public.update_my_profile(p_bio text, p_date_of_birth date) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
    v_existing_dob date;
    v_backfilled boolean;
    v_bio text;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = 'P0001';
    END IF;

    -- username is IMMUTABLE after creation (product contract) — there is no
    -- parameter for it on purpose.
    IF p_bio IS NULL AND p_date_of_birth IS NULL THEN
        RETURN;
    END IF;

    IF p_bio IS NOT NULL THEN
        IF p_bio = '' THEN
            v_bio := NULL;
        ELSE
            v_bio := public.sanitize_free_text(p_bio, 160);
            IF v_bio = '' THEN
                v_bio := NULL;
            END IF;
        END IF;
    END IF;

    IF p_date_of_birth IS NOT NULL THEN
        SELECT date_of_birth, date_of_birth_backfilled
          INTO v_existing_dob, v_backfilled
          FROM public.users WHERE id = v_uid;
        IF v_existing_dob IS NOT NULL
           AND p_date_of_birth <> v_existing_dob
           AND NOT COALESCE(v_backfilled, false) THEN
            RAISE EXCEPTION 'La fecha de nacimiento no puede modificarse.' USING ERRCODE = 'P0001';
        END IF;
        PERFORM public.assert_date_of_birth(p_date_of_birth);
    END IF;

    UPDATE public.users SET
        bio = CASE WHEN p_bio IS NULL THEN bio ELSE v_bio END,
        date_of_birth = CASE
            WHEN p_date_of_birth IS NULL THEN date_of_birth
            ELSE p_date_of_birth
        END,
        date_of_birth_backfilled = CASE
            WHEN p_date_of_birth IS NULL THEN date_of_birth_backfilled
            ELSE false
        END
    WHERE id = v_uid;
END;
$$;

COMMIT;
