-- Samay — 228_moderation_hardening/hardening.sql
--
-- Closes two latent hardening gaps surfaced by the pgTAP suite (SECTION 47+48)
-- after the chat-moderation work, plus tightens the 226 moderation surface.
-- Both are idempotent and safe on a fresh reset.
--
-- 1) pending_object_deletions (221_account_erasure) was created with
--    `FORCE ROW LEVEL SECURITY` but never `ENABLE` — an inert-policy leak
--    (FORCE without ENABLE applies no policies at all). Enabling RLS restores
--    the intended deny-all posture (the table already revokes anon/authenticated
--    and grants only service_role).
--
-- 2) apply_subscription_state + reconcile_subscription_overrides (225,
--    RevenueCat/SOVR) are SECURITY DEFINER and were GRANTed only to
--    service_role, but the platform's default function privileges left
--    `anon` and `authenticated` with EXECUTE. That is a privilege escalation:
--    an unauthenticated caller could set any user's subscription tier. Revoke
--    both client roles; keep service_role.
--
-- 3) 226 moderation functions: keep the client surface minimal (report_message
--    and is_blocked_between are authenticated-only; the message trigger
--    function is not client-callable at all).
-- ======================================================================

-- 1) inert-policy leak -------------------------------------------------------
ALTER TABLE public.pending_object_deletions ENABLE ROW LEVEL SECURITY;

-- 2) subscription-state writers: client roles revoked -------------------------
-- PostgreSQL grants EXECUTE to PUBLIC by default; anon inherits from PUBLIC,
-- so PUBLIC must be revoked too (225 revoked neither).
REVOKE ALL ON FUNCTION public.apply_subscription_state(
    uuid, public.subscription_tier, timestamp with time zone, text
) FROM PUBLIC, anon, authenticated;
GRANT ALL ON FUNCTION public.apply_subscription_state(
    uuid, public.subscription_tier, timestamp with time zone, text
) TO service_role;

REVOKE ALL ON FUNCTION public.reconcile_subscription_overrides()
    FROM PUBLIC, anon, authenticated;
GRANT ALL ON FUNCTION public.reconcile_subscription_overrides()
    TO service_role;

-- 3) 226 moderation surface --------------------------------------------------
REVOKE ALL ON FUNCTION public.is_blocked_between(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.assert_message_not_blocked() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.report_message(uuid, text, text) FROM PUBLIC, anon;

