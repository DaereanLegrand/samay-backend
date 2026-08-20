-- =============================================================================
-- 20260818000002 — global user ranking: profile_public + get_user_ranking
-- -----------------------------------------------------------------------------
-- Product (2026-08-18, Social tab): a GLOBAL user leaderboard ranked by
-- `personal_shards` DESC. It ranks ANY non-deleted user, but names are
-- censored client-side unless the profile is public:
--
--   1. `users.profile_public` — user-owned privacy flag (same class as
--      discovery_opt_in / read_receipts_enabled: USER-OWNED profile data,
--      self-editable via users_update_own; NOT in the G-03 protected-column
--      list, so UPDATE stays allowed for authenticated on their own row).
--      DEFAULT false → every account starts private.
--   2. `get_user_ranking(p_limit)` — SECURITY DEFINER RPC that reads
--      `personal_shards` for everyone. The column is REVOKEd from clients
--      (G-03 column-level REVOKE UPDATE — 20260809000002 §1.1), so a plain
--      PostgREST select can never reach it; the function runs with the
--      owner's privileges (mirror `get_chat_inbox` / `mark_group_messages_read`).
--      The CLIENT decides whether to render a username: only when
--      `profile_public = true` OR the `ranking.anonymize_names` app_config
--      is OFF; otherwise the localized "Usuario" placeholder.
--
-- No RLS change: the function body is not subject to base-table RLS while
-- running as SECURITY DEFINER (owner bypasses RLS), and the view/grant
-- surface is the function grant alone — authenticated EXECUTE only.
-- =============================================================================

ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS profile_public boolean NOT NULL DEFAULT false;

-- ============================================================
-- 1. get_user_ranking(p_limit) — SECURITY DEFINER, global leaderboard
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_user_ranking(p_limit integer DEFAULT 100)
RETURNS TABLE (
    user_id uuid,
    username text,
    avatar_url text,
    personal_shards bigint,
    profile_public boolean
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT
        u.id,
        u.username,
        u.avatar_url,
        u.personal_shards::bigint,
        u.profile_public
    FROM public.users u
    WHERE u.deleted_at IS NULL
    ORDER BY u.personal_shards DESC, u.username ASC
    LIMIT p_limit;
$$;

REVOKE ALL ON FUNCTION public.get_user_ranking(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_user_ranking(integer) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_user_ranking(integer) TO authenticated;