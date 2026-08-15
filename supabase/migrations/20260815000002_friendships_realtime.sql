-- =============================================================================
-- 20260815000002 — friendships joins the realtime publication
-- -----------------------------------------------------------------------------
-- The client's FriendshipsRealtimeListener (2026-08-14) subscribes to
-- `friendships` changes to keep the friends list / requests fresh on the
-- remote side. The table must be in the `supabase_realtime` publication —
-- mirroring how `messages` was added (20260809000003).
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        CREATE PUBLICATION supabase_realtime WITH (publish = 'insert, update, delete');
    END IF;
END
$$;

ALTER PUBLICATION supabase_realtime ADD TABLE public.friendships;
