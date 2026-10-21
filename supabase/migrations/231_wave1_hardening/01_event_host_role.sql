-- ============================================================================
-- 231_wave1_hardening / 01_event_host_role.sql — SEC-014
--
-- Events may only be mutated by a HOST (not staff). The old policy accepted
-- any event_hosts row (host or staff) and had no WITH CHECK, so staff could
-- rename/relocate/cancel an event. The WITH CHECK pins the row to the host and
-- to the event's creator/owner; the server-managed column guard in
-- assert_safe_event_update() remains the backstop for group_id/invite_token/
-- pool/featured/status changes.
--
-- Rollback: DROP POLICY events_update_host; CREATE POLICY events_update_host
-- ON public.events FOR UPDATE USING (EXISTS (SELECT 1 FROM public.event_hosts
-- WHERE event_hosts.event_id = events.id AND event_hosts.user_id = auth.uid()));
-- Forward-fix: replace this policy again; never restore the staff-wide branch.
-- ============================================================================

DROP POLICY IF EXISTS events_update_host ON public.events;

CREATE POLICY events_update_host ON public.events
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1
              FROM public.event_hosts h
             WHERE h.event_id = events.id
               AND h.user_id = auth.uid()
               AND h.role = 'host'::public.event_role
        )
    )
    WITH CHECK (
        created_by_user_id = auth.uid()
        AND EXISTS (
            SELECT 1
              FROM public.event_hosts h
             WHERE h.event_id = events.id
               AND h.user_id = auth.uid()
               AND h.role = 'host'::public.event_role
        )
    );
