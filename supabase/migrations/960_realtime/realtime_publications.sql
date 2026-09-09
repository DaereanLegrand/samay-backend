-- Samay baseline — 010_infra/realtime_publications.sql
-- Realtime memberships in the platform-owned supabase_realtime publication.
-- Guarded: the publication itself is created by the stack init (image
-- realtime.sql); membership adds are skipped when already present, so this
-- never fights `make supabase-init` / `make supabase-testing-init`.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='friendships') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.friendships;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='group_members') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.group_members;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='messages') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='message_reads') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.message_reads;
  END IF;
  -- event_invites (060_events/08_realtime.sql, 2026-09-09): the event detail's
  -- host/staff guest roster live-updates when an invitee accepts/declines on
  -- their own device. RLS still gates delivery (host/staff: full roster rows,
  -- invitees: their own row only).
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='event_invites') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.event_invites;
  END IF;
  -- event_hosts (060_events/09_attendee_roster.sql, 2026-09-09): the organizer
  -- roster (host + staff) streams live to event members when the host
  -- designates/removes staff. RLS still gates delivery (hosts/staff full rows;
  -- event invitees the roster of events they belong to).
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='event_hosts') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.event_hosts;
  END IF;
END
$$;
