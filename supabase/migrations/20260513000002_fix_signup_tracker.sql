-- Replace SECURITY DEFINER handle_signup RPC with a signup_tracker table
-- that tracks signup progress in the public schema (no privileged access needed).

DROP FUNCTION IF EXISTS public.handle_signup;

CREATE TABLE public.signup_tracker (
  email text PRIMARY KEY,
  profile_created boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.signup_tracker ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can select signup_tracker"
  ON public.signup_tracker FOR SELECT
  USING (true);

CREATE POLICY "Anyone can insert signup_tracker"
  ON public.signup_tracker FOR INSERT
  WITH CHECK (true);

CREATE POLICY "Anyone can update signup_tracker"
  ON public.signup_tracker FOR UPDATE
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Anyone can delete signup_tracker"
  ON public.signup_tracker FOR DELETE
  USING (true);
