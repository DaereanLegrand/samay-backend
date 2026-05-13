-- Fix: infinite recursion in events / event_promotores RLS policies
-- Two issues:
-- 1. events_update_promotor had a copy-paste bug: event_promotores.id
--    should be events.id, causing self-referencing evaluation.
-- 2. ep_read_access (event_promotores SELECT) referenced back to events,
--    which triggered events_read_access → event_promotores → events → cycle.

-- Fix events_update_promotor: correct the id reference
DROP POLICY IF EXISTS events_update_promotor ON events;
CREATE POLICY events_update_promotor ON events FOR UPDATE USING (
    EXISTS (
        SELECT 1 FROM event_promotores
        WHERE event_promotores.event_id = events.id
          AND event_promotores.user_id = auth.uid()
    )
);

-- Fix ep_read_access: replace with terminal user_id check to break
-- the events → event_promotores → events cycle
DROP POLICY IF EXISTS ep_read_access ON event_promotores;
CREATE POLICY ep_read_own ON event_promotores FOR SELECT USING (
    user_id = auth.uid()
);
