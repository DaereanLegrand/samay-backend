-- get_friend_profiles — resolve the caller's accepted-friend profiles in ONE
-- round trip (2026-08-30).
--
-- WHY: the on-device friends-cache warm-up (invite/buscar <5-char + empty
-- contract) needs each accepted friend's username/avatar. The previous path
-- hit `user_search_view` from the client, which is NOT queryable on every
-- deployment (PostgREST schema cache gaps return the OpenAPI doc → the client
-- crashed casting it). This RPC is a SECURITY DEFINER function — it ships in
-- the migration so it exists wherever the schema exists — and returns ONLY the
-- caller's accepted friends, scoped by auth.uid(), never arbitrary users.
--
-- Mirrors the search_users() pattern (130_search/01_search_rpc.sql):
-- auth.uid() gate + SECURITY DEFINER + search_path locked + caller scoping.
-- Lives in 130_search because it reads `user_search_view` (created by
-- 120_views_ranking), which must exist before this function is applied.

CREATE FUNCTION public.get_friend_profiles(p_user_ids uuid[])
    RETURNS TABLE(id uuid, username text, avatar_url text)
    LANGUAGE sql
    SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT usv.id,
           usv.username,
           usv.avatar_url
      FROM public.user_search_view AS usv
     WHERE usv.id = ANY(p_user_ids)
       AND EXISTS (
            SELECT 1
              FROM public.friendships AS f
             WHERE f.status = 'accepted'
               AND (
                    (f.requester_id = auth.uid() AND f.addressee_id = usv.id)
                    OR
                    (f.addressee_id = auth.uid() AND f.requester_id = usv.id)
               )
       );
$$;

--
-- Name: FUNCTION get_friend_profiles(uuid[]); Type: ACL; Schema: public
--

REVOKE ALL ON FUNCTION public.get_friend_profiles(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_friend_profiles(uuid[]) TO authenticated;
