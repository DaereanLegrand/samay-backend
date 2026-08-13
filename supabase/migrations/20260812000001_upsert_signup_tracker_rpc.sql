-- Pre-auth signup_tracker write RPC (fixes the OTP-funnel 42501).
--
-- Context: migration 20260724000001 locked signup_tracker down with
-- email-scoped RLS policies (`email = auth.jwt()->>'email'`) and converted
-- the pre-auth READ to the SECURITY DEFINER RPC check_signup_email.
-- The client's pre-OTP WRITE (AuthService.upsertSignupTracker(email,false),
-- called from AuthNotifier.sendOtp BEFORE the OTP is verified) was missed:
-- an anonymous JWT carries NO email claim, so `auth.jwt()->>'email'` is
-- NULL and no policy can ever match → direct upserts fail 42501
-- ("No tienes permiso para realizar esta acción." surfaced on the OTP
-- screen). Same posture as check_signup_email: SECURITY DEFINER +
-- SET search_path = '' + EXECUTE granted to anon + authenticated only.
-- The p_profile_created=true branch (which makes check_signup_email return
-- 'exists') is additionally gated on the JWT email matching p_email, so an
-- anonymous caller cannot squat an 'exists' row for someone else's email.

CREATE OR REPLACE FUNCTION public.upsert_signup_tracker(p_email text, p_profile_created boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_profile_created
     AND auth.jwt() ->> 'email' IS DISTINCT FROM p_email THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO public.signup_tracker (email, profile_created, created_at, updated_at)
  VALUES (p_email, p_profile_created, now(), now())
  ON CONFLICT (email) DO UPDATE
    SET profile_created = EXCLUDED.profile_created,
        updated_at = now();
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_signup_tracker(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_signup_tracker(text, boolean) TO anon, authenticated;
