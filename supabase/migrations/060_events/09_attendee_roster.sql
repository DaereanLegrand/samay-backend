-- Samay baseline — 060_events/09_attendee_roster.sql
--
-- Attendee-side event roster (2026-09-09): everyone who BELONGS to an event
-- (an invitee — pending/accepted/attended — or a host/staff member) can see
-- who is in it:
--
--   * the organizer roster (`event_hosts` = host + staff) reads for members,
--     and
--   * the event's CONFIRMED guest rows (`event_invites` where status is
--     accepted/attended) reads for members — other people's PENDING invites
--     stay host/staff-visible and own-row-only (privacy: "confirmed people
--     only", directive 2026-09-09).
--
-- Both lists stream live via supabase_realtime (guests already joined in
-- 08_realtime.sql; event_hosts joins here) so an accepted attendee's detail
-- screen updates when someone else accepts or the host designates staff.
--
-- RLS recursion: `event_hosts` policies may NOT read `event_invites` directly
-- (event_invites' own ei_read_event_access policy reads event_hosts — a cycle
-- Postgres rejects at query time). The membership check therefore lives in a
-- security-barrier VIEW owned by postgres (same trick as
-- event_host_access_view): `event_roster_membership_view` projects only the
-- caller's own invite rows (`user_id = auth.uid()`), so a policy subquery
-- against it never recurses and no client can see any membership but its own
-- through the view.
--
-- event_hosts also gains REPLICA IDENTITY FULL (its realtime membership add
-- lives in 960_realtime/realtime_publications.sql): full-row UPDATE/DELETE
-- payloads so the filtered `event_hosts` channel always knows which event
-- changed.

-- ======================================================================
-- event_roster_membership_view — security-barrier projection: the events the
-- CALLER belongs to as an invitee (any status). Owner-run base read (postgres
-- bypasses event_invites RLS) + caller filter, so policies referencing it are
-- recursion-free and leak nothing.
-- ======================================================================
CREATE VIEW public.event_roster_membership_view WITH (security_barrier='true') AS
SELECT event_id
FROM public.event_invites
WHERE user_id = auth.uid();

REVOKE ALL ON public.event_roster_membership_view FROM PUBLIC;
GRANT SELECT ON public.event_roster_membership_view TO anon;
GRANT SELECT ON public.event_roster_membership_view TO authenticated;
GRANT SELECT ON public.event_roster_membership_view TO service_role;

-- ======================================================================
-- event_hosts REPLICA IDENTITY FULL — full-row realtime payloads for the
-- organizer roster (publication add in 960_realtime).
-- ======================================================================
ALTER TABLE ONLY public.event_hosts REPLICA IDENTITY FULL;

-- ======================================================================
-- event_hosts RLS: members (invitees of any standing) read the organizer
-- roster. Hosts/staff already read it via ep_read_event_access; ep_read_own
-- stays. OR'd with the existing policies, so this only WIDENS reads.
-- ======================================================================
CREATE POLICY ep_read_member_roster ON public.event_hosts FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM public.event_roster_membership_view m
        WHERE m.event_id = event_hosts.event_id
    )
);

-- ======================================================================
-- event_invites RLS: members read the event's CONFIRMED rows (accepted /
-- attended) — "who is going". Pending rows of OTHER people stay invisible to
-- members (ei_read_own shows only your own pending). Hosts/staff already read
-- every row via ei_read_event_access; OR'd, so reads only widen for the
-- accepted/attended subset.
-- ======================================================================
CREATE POLICY ei_read_confirmed_roster ON public.event_invites FOR SELECT USING (
    status IN ('accepted', 'attended')
    AND EXISTS (
        SELECT 1 FROM public.event_roster_membership_view m
        WHERE m.event_id = event_invites.event_id
    )
);
