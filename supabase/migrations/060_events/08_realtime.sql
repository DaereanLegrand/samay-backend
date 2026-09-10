-- Samay baseline — 060_events/08_realtime.sql
--
-- Events roster realtime (2026-09-09, extended 2026-09-10): the event detail's
-- host/staff guest roster (eventGuestsProvider) was a stale client cache with no
-- push seam — an invitee accepting/declining on their OWN device never reached
-- the host's open screen (only a manual re-fetch could). Fix, matching the
-- friendships / group_members / minigame_sessions pattern:
--
--   * event_invites gets REPLICA IDENTITY FULL so UPDATE/DELETE realtime
--     payloads carry the FULL row (the client filters the channel on
--     `event_id = <uuid>`, which needs event_id present in the record).
--   * event_attendances gets REPLICA IDENTITY FULL (2026-09-10, Task C) so the
--     scanner's confirmation reaches an already-open detail/QR screen: only
--     `event_attendances` records a host/staff member's confirmation (they have
--     no invite row) and it is the authoritative assist signal the client
--     re-reads for the terminal "Ya te registraste" state.
--   * the publication membership adds live in 960_realtime (the central
--     supabase_realtime registry), guarded and idempotent.
--
-- Delivery is RLS-gated like every realtime table: a subscriber only receives
-- rows it may SELECT. `event_invites`: the event's hosts/staff (policy
-- ei_read_event_access, 05_manual_invites) for the whole roster, an invitee
-- only their own row (ei_read_own). `event_attendances` (ea_read_access,
-- 01_tables): a caller always receives their own row, plus all the event's
-- rows when they are host/staff or a group member. The client invalidates
-- eventGuestsProvider / myAttendanceProvider on every row event for the event,
-- so the roster and the terminal state stay authoritative without a refresh.

ALTER TABLE ONLY public.event_invites REPLICA IDENTITY FULL;
ALTER TABLE ONLY public.event_attendances REPLICA IDENTITY FULL;
