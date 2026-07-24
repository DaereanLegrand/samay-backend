-- Lock down signup_tracker RLS:
--   1. SECURITY DEFINER RPC (SET search_path = '') for pre-auth email check
--   2. Drop wide-open policies, add email-scoped policies
--   3. FORCE ROW LEVEL SECURITY
--   4. Explicit REVOKE/GRANT on the RPC
--
-- Reference: docs/to-fix/TODO.md C-01, docs/implementation/phase-00-foundation/SECU-rls-policies.md
-- Pattern: Juega's SECURITY DEFINER RPCs (SET search_path = '') + user-owned RLS

-- ============================================================
-- 1. SECURITY DEFINER RPC for pre-auth email lookup
--    Needed because checkSignupEmail runs before user is authenticated
--    (see lib/features/auth/signup_contact_screen.dart:50)
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_signup_email(p_email text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_profile_created boolean;
BEGIN
  SELECT profile_created INTO v_profile_created
  FROM public.signup_tracker
  WHERE email = p_email;

  IF NOT FOUND THEN
    RETURN 'signup';
  END IF;

  IF v_profile_created THEN
    RETURN 'exists';
  END IF;

  DELETE FROM public.signup_tracker
  WHERE email = p_email AND NOT profile_created;

  RETURN 'signup';
END;
$$;

REVOKE ALL ON FUNCTION public.check_signup_email(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_signup_email(text) TO anon, authenticated;

-- ============================================================
-- 2. Drop wide-open policies
-- ============================================================
DROP POLICY IF EXISTS "Anyone can select signup_tracker" ON public.signup_tracker;
DROP POLICY IF EXISTS "Anyone can insert signup_tracker" ON public.signup_tracker;
DROP POLICY IF EXISTS "Anyone can update signup_tracker" ON public.signup_tracker;
DROP POLICY IF EXISTS "Anyone can delete signup_tracker" ON public.signup_tracker;

-- ============================================================
-- 3. Email-scoped RLS policies (own email only)
-- ============================================================
CREATE POLICY "signup_tracker_select_own" ON public.signup_tracker
  FOR SELECT USING (email = auth.jwt() ->> 'email');

CREATE POLICY "signup_tracker_insert_own" ON public.signup_tracker
  FOR INSERT WITH CHECK (email = auth.jwt() ->> 'email');

CREATE POLICY "signup_tracker_update_own" ON public.signup_tracker
  FOR UPDATE USING (email = auth.jwt() ->> 'email')
  WITH CHECK (email = auth.jwt() ->> 'email');

CREATE POLICY "signup_tracker_delete_own" ON public.signup_tracker
  FOR DELETE USING (email = auth.jwt() ->> 'email');

-- ============================================================
-- 4. FORCE RLS — table owner (service_role) must also obey
-- ============================================================
ALTER TABLE public.signup_tracker FORCE ROW LEVEL SECURITY;
