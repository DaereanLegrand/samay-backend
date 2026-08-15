-- =============================================================================
-- 20260815000001 — user_search_view gains the public bio column
-- -----------------------------------------------------------------------------
-- Root-cause fix (docs↔code audit follow-up, 2026-08-14): the client's
-- cross-user profile reads (friends list, friend requests, public profile,
-- group members, chat) resolve through `user_search_view` — the security
-- barrier — because the `users` table is own-row-only since
-- 20260520000001 dropped `users_search`. Without `bio`, the public-profile
-- screen (and the resolved `UserProfile` model consumers) would silently
-- lose the bio text.
--
-- Security posture (unchanged): the barrier still exposes ONLY the public
-- identity columns (id, username, avatar_url + this bio) — never the
-- sensitive ones (personal_shards, preshards, subscription_tier,
-- deleted_at, email). `bio` is user-generated public profile copy rendered
-- app-wide; exposing it through the barrier matches the search/identity
-- intent of the view. The 20260814000002 block-exclusion and the
-- deleted_at filter are preserved verbatim.
-- =============================================================================

CREATE OR REPLACE VIEW public.user_search_view
WITH (security_barrier)
AS
SELECT id,
       username,
       avatar_url,
       bio
FROM users
WHERE deleted_at IS NULL
  AND NOT (
    EXISTS (
      SELECT 1
      FROM friendships
      WHERE friendships.status = 'blocked'::friendship_status
        AND (
          friendships.requester_id = users.id AND friendships.addressee_id = auth.uid()
          OR friendships.requester_id = auth.uid() AND friendships.addressee_id = users.id
        )
    )
  );

GRANT SELECT ON public.user_search_view TO authenticated;

-- Keep the I-32 hardening: anon has NO SELECT on the view (authenticated
-- search only — see 20260809000002's revoke).
REVOKE SELECT ON public.user_search_view FROM anon;

-- Parity: the migrations of both stacks are byte-identical (opt-007 gate).
