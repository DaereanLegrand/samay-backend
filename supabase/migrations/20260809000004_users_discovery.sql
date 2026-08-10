-- Samay — Party Finder discovery: interest tags + opt-in + discovery view (I-60)
--
-- Reference: docs/implementation/phase-13-party-finder-video/PFND-party-finder.md
-- (opt-in toggle default OFF; users with overlapping interest tags who opted
-- in are discoverable; matches exclude blocked users client-side).
--
-- Companion Dart: lib/features/profile/interests.dart (UserInterests value
-- object — I-36 foundation; storage contract `users.interest_tags text[]`),
-- lib/core/services/user_service.dart (findMatches / getDiscoveryOptIn /
-- setDiscoveryOptIn / getMyInterestTags), lib/features/party_finder/**.
--
-- ============================================================
-- 1. users — interest_tags + discovery_opt_in
-- ============================================================
-- Both columns are USER-OWNED profile data (same class as username /
-- avatar_url / bio, which were never guarded by I-32's G-03 hardening):
--   * NOT in the I-32 column-level REVOKE UPDATE list (20260809000002 §1.1)
--     → UPDATE stays allowed for authenticated via the users_update_own
--     policy (id = auth.uid()).
--   * NOT in the assert_safe_user_update() protected-column comparison
--     (20260809000002 §1.2 — the trigger only rejects changes to the
--     economy/subscription/ban/DOB/deleted_at columns) → updates to these
--     two columns pass through the trigger untouched.
--   => DECISION (documented): NO trigger allowlist change and NO new REVOKE.
--      The trigger's "allowlist" is the set of protected columns; these two
--      are deliberately absent so users can self-edit them via the privacy
--      toggle (party finder opt-in) and the profile tags editor. Re-audit
--      with S-03: interest_tags is presentation data; discovery_opt_in is a
--      privacy preference — neither is economy/subscription-affecting, so
--      keeping them self-editable does not reopen G-03.
-- INSERT normalization (signup) needs no change either: the DEFAULTs below
-- give every new user an empty tag set + discovery OFF (opt-in by default).
ALTER TABLE public.users
    ADD COLUMN interest_tags text[] NOT NULL DEFAULT '{}',
    ADD COLUMN discovery_opt_in boolean NOT NULL DEFAULT false;

-- ============================================================
-- 2. discovery_view — security-barrier view over opted-in users
-- ============================================================
-- Exposes ONLY (id, username, avatar_url, interest_tags) of non-deleted,
-- opted-in users with at least one tag — the Party Finder match source.
--
-- RLS note (see CREATE VIEW semantics, PostgreSQL 17): the view is owned by
-- the migration role (postgres, superuser + BYPASSRLS), and a non-
-- security_invoker view resolves its base-table access with the VIEW OWNER's
-- privileges — so base-table RLS is bypassed for the view body, exactly like
-- the pre-existing user_search_view (20260520000001 §5). The view itself is
-- therefore the column-level gate: the caller needs SELECT on the view
-- (granted to authenticated below) and can never reach users directly
-- (users_read_own = own row only). security_barrier forces the view's WHERE
-- (deleted_at / discovery_opt_in) to be evaluated before any caller-supplied
-- predicate, preventing pushdown-based row leaks (section 39.5).
--
-- Blocked users are NOT excluded here (mirrors user_search_view): the
-- service filters friendships client-side so a block lands immediately and
-- does not require re-deriving policy — flagged for S-03 (see the I-60
-- daily log).
CREATE OR REPLACE VIEW public.discovery_view
WITH (security_barrier)
AS
SELECT id, username, avatar_url, interest_tags
FROM public.users
WHERE deleted_at IS NULL
  AND discovery_opt_in = true
  AND interest_tags <> '{}'::text[];

-- Authenticated-only (matches user_search_view hardening, I-32 §13: no
-- pre-auth enumeration). No anon grant ever exists for new views; the
-- explicit REVOKE is defense-in-depth so a future default-grant change
-- cannot leak opted-in users to anonymous callers.
GRANT SELECT ON public.discovery_view TO authenticated;
REVOKE SELECT ON public.discovery_view FROM anon;
