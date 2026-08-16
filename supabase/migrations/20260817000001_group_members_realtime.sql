-- =============================================================================
-- 20260817000001 — group_members joins the realtime publication
-- -----------------------------------------------------------------------------
-- The client's GroupMembershipsRealtimeListener (2026-08-17) subscribes to
-- `group_members` changes so group invitations appear without an app restart.
-- The table must be in the `supabase_realtime` publication — mirroring how
-- `messages` (20260809000003) and `friendships` (20260815000002) were added.
-- REPLICA IDENTITY FULL makes DELETE events carry the full row (the listener
-- needs `user_id` from delete payloads).
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        CREATE PUBLICATION supabase_realtime WITH (publish = 'insert, update, delete');
    END IF;
END
$$;

ALTER TABLE public.group_members REPLICA IDENTITY FULL;

ALTER PUBLICATION supabase_realtime ADD TABLE public.group_members;
