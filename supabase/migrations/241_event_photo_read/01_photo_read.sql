-- ============================================================================
-- 241_event_photo_read/01_photo_read.sql — E5 triage fix
--
-- `eph_read_access` (070) decided visibility by SELECTing the parent `events`
-- row. 229/SEC-005 narrowed `events_read_access` to hosts/staff and accepted
-- invitees, so the policy's own subquery now hides the event from group
-- members — and with it every group-scoped photo, even for the uploader.
--
-- Move the visibility predicate into a SECURITY DEFINER helper that evaluates
-- the relationship directly (group membership / event invite / event host),
-- independent of the parent row's RLS. Behaviour is otherwise unchanged; group
-- membership now requires `status = 'active'` (231 hardening).
--
-- Rollback: forward-fix only.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.can_view_event_photos(p_event_id uuid)
RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT EXISTS (
        SELECT 1
          FROM public.events e
         WHERE e.id = p_event_id
           AND (
                e.group_id IS NULL
                OR EXISTS (
                    SELECT 1 FROM public.group_members gm
                     WHERE gm.group_id = e.group_id
                       AND gm.user_id = auth.uid()
                       AND gm.status = 'active'
                )
                OR EXISTS (
                    SELECT 1 FROM public.event_invites ei
                     WHERE ei.event_id = e.id
                       AND ei.user_id = auth.uid()
                )
                OR EXISTS (
                    SELECT 1 FROM public.event_hosts eh
                     WHERE eh.event_id = e.id
                       AND eh.user_id = auth.uid()
                )
           )
    );
$$;

REVOKE ALL ON FUNCTION public.can_view_event_photos(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_view_event_photos(uuid)
    TO authenticated, service_role;

DROP POLICY IF EXISTS eph_read_access ON public.event_photos;
CREATE POLICY eph_read_access ON public.event_photos
    FOR SELECT TO authenticated
    USING (public.can_view_event_photos(event_id));

COMMIT;
