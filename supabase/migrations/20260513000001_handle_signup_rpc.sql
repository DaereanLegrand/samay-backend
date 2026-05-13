-- Handle signup with cleanup for incomplete registrations.
-- If email exists in auth.users but has no users table row (half-registered),
-- delete the old auth user so a fresh signup can proceed.

CREATE OR REPLACE FUNCTION public.handle_signup(p_email text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_has_profile boolean;
BEGIN
  SELECT id INTO v_user_id FROM auth.users WHERE email = p_email;

  IF v_user_id IS NULL THEN
    RETURN json_build_object('action', 'signup');
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.users WHERE id = v_user_id) INTO v_has_profile;

  IF v_has_profile THEN
    RETURN json_build_object('action', 'exists');
  END IF;

  DELETE FROM auth.users WHERE id = v_user_id;
  RETURN json_build_object('action', 'signup');
END;
$$;
