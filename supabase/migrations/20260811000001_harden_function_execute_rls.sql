-- Harden function EXECUTE grants against the supabase image's default privileges.
--
-- WHY (2026-08-11, found during the Step-0 verification gate):
-- the supabase/postgres image's initdb installs ALTER DEFAULT PRIVILEGES rows
-- granting `anon=X` EXECUTE on every function created by `postgres` /
-- `supabase_admin` in `public`. Every prior per-function
-- `REVOKE ALL ON FUNCTION ... FROM PUBLIC` only removed the *PUBLIC* entry —
-- the default-ACL anon grant survived, leaving ALL 17 SECURITY DEFINER
-- functions anon-callable (shard minting via grant_shards, the PII
-- hard-delete cron, E2EE prekey-bundle exfiltration, shard draining via
-- donate_shards_to_group, ...). Verified live: has_function_privilege('anon',
-- ...) = t on all 17.
--
-- Fix: (1) strip anon from the DEFAULT privileges so future functions are
-- safe, (2) explicit per-function REVOKE/GRANT to the intended roles
-- (belt-and-braces against the defaults), (3) NULL-safe auth guard in
-- donate_shards_to_group (auth.uid() IS NULL for unauthenticated sessions —
-- `auth.uid() != p_user_id` evaluates NULL and the guard silently passed).

-- 1. Default privileges — future functions created by the migration roles
--    must NOT be anon-executable by default.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon;
-- The image's bootstrap superuser is supabase_admin; migrate.sh runs as
-- `postgres` (non-superuser) so the supabase_admin defaults can only be
-- changed when applied as the superuser. All migration-created functions are
-- postgres-owned, so the FOR ROLE postgres change above covers them; the
-- supabase_admin change is defense-in-depth for anything the superuser
-- creates later. Apply as supabase_admin for full hardening.
DO $$
BEGIN
    BEGIN
        EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon';
        RAISE NOTICE 'supabase_admin default privileges hardened';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'SKIP: cannot alter supabase_admin default privileges (running as non-superuser) — postgres-created functions are covered by the FOR ROLE postgres change above';
    END;
END $$;

-- 2. Admin RPCs — service_role only (CLI / future API server).
REVOKE EXECUTE ON FUNCTION public.grant_shards(uuid, integer, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.grant_shards(uuid, integer, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.grant_preshards(uuid, integer, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.grant_preshards(uuid, integer, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.distribute_shards(uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.distribute_shards(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.recalculate_ranks(text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recalculate_ranks(text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.hard_delete_expired_users() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.hard_delete_expired_users() TO service_role;

-- 3. Client auth RPCs — authenticated only (never anon, never service_role:
--    a service_role caller has auth.uid() = NULL and would bypass the same
--    guards the RPCs enforce for users).
REVOKE EXECUTE ON FUNCTION public.donate_shards_to_group(uuid, uuid, integer, timestamptz) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.donate_shards_to_group(uuid, uuid, integer, timestamptz) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.fetch_prekey_bundle(uuid) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.fetch_prekey_bundle(uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.validate_qr_token(uuid, text) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.validate_qr_token(uuid, text) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.create_minigame_session(uuid, text, integer) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_minigame_session(uuid, text, integer) TO authenticated;

-- 4. Trigger-only functions (RETURNS trigger — not directly callable; hygiene
--    only: no client role needs EXECUTE, including via the inherited PUBLIC
--    grant — has_function_privilege('anon', ...) resolves TRUE through it).
--    is_group_member is deliberately EXCLUDED — it is invoked from RLS
--    policies and anon must keep EXECUTE.
REVOKE EXECUTE ON FUNCTION public.set_dynamic_qr_enabled() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.update_group_size_tier() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.enforce_message_cap() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.increment_group_shards() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.update_photo_likes_count() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.dispatch_shard_distribution() FROM PUBLIC, anon, authenticated;

-- 5. NULL-safe auth guard in donate_shards_to_group (SECURITY DEFINER —
--    without the guard an anon caller could drain any user's shards:
--    auth.uid() IS NULL -> `NULL != p_user_id` -> IF not raised).
--    Also adds SET search_path = '' (I-31 hardening pattern).
CREATE OR REPLACE FUNCTION public.donate_shards_to_group(
    p_group_id uuid,
    p_user_id uuid,
    p_amount integer,
    p_expires_at timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
        RAISE EXCEPTION 'Not authorized';
    END IF;

    UPDATE public.users SET personal_shards = personal_shards - p_amount
    WHERE id = p_user_id AND personal_shards >= p_amount;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Insufficient shards';
    END IF;

    INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
    VALUES (p_user_id, -p_amount, 'group_donation', p_group_id);

    INSERT INTO public.group_shard_contributions (group_id, user_id, shards_contributed, expires_at)
    VALUES (p_group_id, p_user_id, p_amount, p_expires_at);
END;
$$;

-- Public execute was already revoked in 20260724000002; re-assert the final
-- posture so this migration is self-contained.
REVOKE EXECUTE ON FUNCTION public.donate_shards_to_group(uuid, uuid, integer, timestamptz) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.donate_shards_to_group(uuid, uuid, integer, timestamptz) TO authenticated;

-- 6. groups/events server-managed columns: the image's default privileges
--    grant TABLE-level UPDATE to authenticated/anon, which makes the
--    G-03-style column-level REVOKEs (20260809000002 §5/§6) ineffective —
--    has_column_privilege() resolves UPDATE via the table grant, so a
--    promotor could SET groups.group_shards / rank_bracket / frozen_at /
--    size_tier and events.preshards_distributed / featured / featured_until
--    through PostgREST. Mirror the users pattern (assert_safe_user_update,
--    SECURITY INVOKER): allow writes that leave the server-managed columns
--    unchanged, reject the rest for non-privileged roles.
CREATE OR REPLACE FUNCTION public.assert_safe_group_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
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
        NEW.group_shards := 0;
        NEW.size_tier := 'micro'::public.size_tier;
        NEW.frozen_at := NULL;
        RETURN NEW;
    END IF;

    IF NEW.group_shards = OLD.group_shards
        AND NEW.size_tier = OLD.size_tier
        AND NEW.frozen_at IS NOT DISTINCT FROM OLD.frozen_at
        AND NEW.rank_bracket = OLD.rank_bracket
    THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'groups server-managed columns (group_shards, size_tier, frozen_at, rank_bracket) may only be changed by a privileged role';
END;
$$;

DROP TRIGGER IF EXISTS assert_safe_group_update_trigger ON public.groups;
CREATE TRIGGER assert_safe_group_update_trigger
    BEFORE UPDATE ON public.groups
    FOR EACH ROW EXECUTE FUNCTION public.assert_safe_group_update();

CREATE OR REPLACE FUNCTION public.assert_safe_event_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
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
        NEW.preshards_distributed := false;
        NEW.featured := false;
        NEW.featured_until := NULL;
        RETURN NEW;
    END IF;

    IF NEW.preshards_distributed = OLD.preshards_distributed
        AND NEW.featured = OLD.featured
        AND NEW.featured_until IS NOT DISTINCT FROM OLD.featured_until
    THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'events server-managed columns (preshards_distributed, featured, featured_until) may only be changed by a privileged role';
END;
$$;

DROP TRIGGER IF EXISTS assert_safe_event_update_trigger ON public.events;
CREATE TRIGGER assert_safe_event_update_trigger
    BEFORE UPDATE ON public.events
    FOR EACH ROW EXECUTE FUNCTION public.assert_safe_event_update();

-- 7. groups RLS policy correlation bug (pre-existing, since 20260510000001):
--    `EXISTS (SELECT 1 FROM group_members WHERE group_id = id ...)` — the
--    unqualified `id` resolves to the INNER group_members.id, so
--    `group_members.group_id = group_members.id` never matched → BOTH
--    groups_read_member and groups_update_promotor were dead: members could
--    not read their groups and promotors could not update them (verified
--    live: promotor PATCH matched 0 rows). Recreated with an explicit
--    groups.id correlation.
DROP POLICY IF EXISTS groups_read_member ON public.groups;
CREATE POLICY groups_read_member ON public.groups FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.group_members
            WHERE group_id = groups.id AND user_id = auth.uid())
);
DROP POLICY IF EXISTS groups_update_promotor ON public.groups;
CREATE POLICY groups_update_promotor ON public.groups FOR UPDATE USING (
    EXISTS (SELECT 1 FROM public.group_members
            WHERE group_id = groups.id AND user_id = auth.uid()
              AND role IN ('promotor', 'co_promotor'))
);
