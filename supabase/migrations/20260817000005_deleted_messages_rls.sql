-- =============================================================================
-- 20260817000005 — deleted_messages RLS hardening (K1 re-audit, SEV HIGH)
-- -----------------------------------------------------------------------------
-- The deletion audit trail (migration 20260815000006) was created WITHOUT
-- `ENABLE ROW LEVEL SECURITY`, WITHOUT `FORCE ROW LEVEL SECURITY`, and with
-- NO policies — under the image's default privileges any anon/authenticated
-- client could SELECT/INSERT/DELETE the deletion audit trail. That violates
-- the E2EE §9.3 invariant ("all new tables ENABLE + FORCE RLS") and weakens
-- the §7.5a non-repudiation trail (an attacker could scrub their own
-- deletion records).
--
-- Fix (mirrors the admin_audit_log no-access pattern, full_schema.sql:
-- `CREATE POLICY admin_audit_log_no_access ... FOR ALL USING (false)`):
--
--   1. ENABLE ROW LEVEL SECURITY
--   2. FORCE ROW LEVEL SECURITY (even the table owner must obey the
--      policies — I-31 posture)
--   3. `deleted_messages_no_access` FOR ALL USING (false) WITH CHECK (false)
--      — no anon/authenticated client can read, insert, update or delete
--      the trail; only service_role (BYPASSRLS) can.
--
-- SECURITY DEFINER RPCs (verified unchanged): `delete_message_for_everyone`
-- and `delete_undecryptable_messages` run as the function definer (the
-- `postgres` superuser, who bypasses RLS entirely — FORCE RLS does not
-- apply to superusers), so their `INSERT INTO public.deleted_messages`
-- statements keep working byte-for-byte. No code change needed; verified
-- on the live DB after applying (see the K1-audit-close daily log).
-- =============================================================================

ALTER TABLE public.deleted_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deleted_messages FORCE ROW LEVEL SECURITY;

CREATE POLICY deleted_messages_no_access ON public.deleted_messages
    FOR ALL USING (false) WITH CHECK (false);
