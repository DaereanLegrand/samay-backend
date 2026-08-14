-- Samay — Blocked users excluded from discovery/search views + groups
-- INSERT rank_bracket normalization (docs-to-code audit, 2026-08-13)
--
-- Two fixes from the S-03/audit findings:
--
--   1. PFND (20260809000004 §2 note) said "matches exclude blocked users
--      client-side". A crafted PostgREST caller bypassed that client filter:
--      blocked users stayed enumerable through user_search_view /
--      discovery_view (block evasion). Both views now exclude any user with
--      a blocked friendship in EITHER direction (status = 'blocked').
--      auth.uid() resolves per-request inside the security_barrier view body.
--
--   2. assert_safe_group_update's INSERT branch normalized group_shards /
--      size_tier / frozen_at but not rank_bracket — a crafted caller could
--      INSERT b90_100 and top the leaderboard until the nightly recalc.
--      INSERTs now always start at 'b0_20' (recalculate_ranks is the only
--      rank_bracket writer, service_role-only).
--
-- References: docs/implementation/phase-13-party-finder-video/PFND,
-- docs/implementation/phase-08-social-feed-photos/FEED, S-03 log
-- (2026-08-11), S-13/FINAL O8.
-- Companion Dart: lib/core/services/user_service.dart (searchUsers /
-- findMatches), lib/core/services/group_service.dart (createGroup).

-- ============================================================
-- 1. user_search_view — blocked users excluded
-- ============================================================
-- CREATE OR REPLACE VIEW preserves the existing grants (authenticated-only
-- SELECT after I-32 §13 — anon stays revoked); only the body changes.
CREATE OR REPLACE VIEW public.user_search_view
WITH (security_barrier)
AS
SELECT id, username, avatar_url
FROM public.users
WHERE deleted_at IS NULL
  AND NOT EXISTS (
      SELECT 1 FROM public.friendships
      WHERE status = 'blocked'
        AND (
            (requester_id = users.id AND addressee_id = auth.uid())
            OR (requester_id = auth.uid() AND addressee_id = users.id)
        )
  );

-- ============================================================
-- 2. discovery_view — blocked users excluded
-- ============================================================
CREATE OR REPLACE VIEW public.discovery_view
WITH (security_barrier)
AS
SELECT id, username, avatar_url, interest_tags
FROM public.users
WHERE deleted_at IS NULL
  AND discovery_opt_in = true
  AND interest_tags <> '{}'::text[]
  AND NOT EXISTS (
      SELECT 1 FROM public.friendships
      WHERE status = 'blocked'
        AND (
            (requester_id = users.id AND addressee_id = auth.uid())
            OR (requester_id = auth.uid() AND addressee_id = users.id)
        )
  );

-- ============================================================
-- 3. assert_safe_group_update — rank_bracket normalized on INSERT
-- ============================================================
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
        NEW.rank_bracket := 'b0_20'::public.rank_bracket;
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
