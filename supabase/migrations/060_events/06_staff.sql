-- Samay — 060_events/06_staff.sql
--
-- Host designates staff (Stage 3, 2026-09-08). The HOST (creator or any
-- role=host member) can designate specific users as STAFF for an event and
-- remove them again; everyone on the roster (host + staff) reads the full
-- host/staff list, and host/staff are treated as ATTENDEES for the
-- attendance-code surface (they generate their own code like invited
-- guests do).
--
-- Model / decisions:
--
--   * designate_event_staff(p_event_id, p_staff_ids) — host-gated (creator or
--     role=host), idempotent (already-privileged candidates are skipped), and
--     capacity-enforced: host seats + all live guest seats + NEW staff seats
--     must fit the frozen events.capacity.
--   * A candidate who already holds an event_invites row (pending/accepted/
--     attended) is CONVERTED: their invite row is DELETEd and the seat moves
--     into event_hosts — seat-neutral (never double counts, mirror of the
--     "declined invite is deleted" semantics from 05_manual_invites).
--   * remove_event_staff(p_event_id, p_staff_user_id) — host-gated, deletes a
--     role=staff row (frees its seat). The HOST row can never be removed
--     (host_not_removable); removing a non-existent member is an idempotent ok.
--   * event_hosts RLS: the legacy client INSERT policy ep_insert_host is
--     DROPPED (its "host may insert any row" branch bypassed capacity and
--     could mint unlimited hosts/staff — a capacity contract hole). Event-host
--     writes are now exclusively the SECURITY DEFINER RPC family
--     (create_event, designate_event_staff). A SELECT policy
--     ep_read_event_access opens the FULL roster to the event's hosts/staff
--     (hosts view "who is host/staff" on the detail screen). A direct
--     self-referencing event_hosts policy would recurse infinitely (verified
--     in-repo), so the membership check goes through a security-barrier view
--     `event_host_access_view` that projects ONLY the caller's own rows
--     (`user_id = auth.uid()`). SELECT is granted to the API roles so policy
--     evaluation works on a PRISTINE schema (fresh init/apply): an ungranted
--     view makes every event_hosts read fail with "permission denied for
--     view" (the old volume only worked because default privileges had
--     auto-granted the view when it was applied later). Because the view is
--     filtered to the caller and runs as its owner (rolbypassrls), no client
--     can ever see another event's roster through it — full-roster reads
--     still go through event_hosts + the ep_read_event_access policy.
--   * The code-family RPCs (get_my_code / validate_code in 07_code.sql)
--     treat event_hosts members (host + staff) as attendees: they may
--     generate their own attendance code and be validated/confirmed like
--     invited guests. (The invite-flip UPDATE affects zero rows for
--     hosts/staff — attendance is recorded in event_attendances for
--     everyone.)

-- ======================================================================
-- event_host_access_view — security-barrier projection of event_hosts used
-- ONLY by the ep_read_event_access policy (recursion workaround). Filters to
-- the caller's own rows (`user_id = auth.uid()`); SELECT is granted to the
-- API roles so policy evaluation works on a pristine schema, while no client
-- can read any roster but their own through the view.
-- ======================================================================
CREATE OR REPLACE VIEW public.event_host_access_view WITH (security_barrier='true') AS
SELECT event_id, user_id, role
FROM public.event_hosts
WHERE user_id = auth.uid();

-- ======================================================================
-- designate_event_staff(uuid, uuid[])
-- ----------------------------------------------------------------------
-- The host designates [p_staff_ids] as staff of [p_event_id]. Returns jsonb:
--   ok / not_authenticated / event_not_found / event_closed / not_host /
--   staff_not_allowed / too_many_staff / capacity_reached
-- `ok` carries "added": the count of NEW event_hosts staff rows inserted
-- (idempotent re-designates report 0). Candidates already holding an
-- event_invites row are converted (invite DELETEd, seat-neutral).
-- ======================================================================
CREATE OR REPLACE FUNCTION public.designate_event_staff(p_event_id uuid, p_staff_ids uuid[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_capacity integer;
    v_status public.event_status;
    v_candidate uuid;
    v_added integer := 0;
    v_clean uuid[] := '{}'::uuid[];
BEGIN
    -- 1. Authentication gate.
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Event lookup + row lock (serialize concurrent designates / invites /
    --    removals against capacity).
    SELECT capacity, status INTO v_capacity, v_status
    FROM public.events
    WHERE id = p_event_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'event_not_found');
    END IF;

    -- 3. Lifecycle gate: no staff into a finished/cancelled event.
    IF v_status IN ('ended', 'cancelled') THEN
        RETURN jsonb_build_object('status', 'event_closed');
    END IF;

    -- 4. Host gate: the CREATOR or a role=host member may designate; staff
    --    cannot grow the roster.
    IF NOT EXISTS (
        SELECT 1 FROM public.events
        WHERE id = p_event_id AND created_by_user_id = v_me
    ) AND NOT EXISTS (
        SELECT 1 FROM public.event_hosts
        WHERE event_id = p_event_id AND user_id = v_me
          AND role = 'host'
    ) THEN
        RETURN jsonb_build_object('status', 'not_host');
    END IF;

    -- 5. Candidate cleaning: dedupe, never staff yourself (you are already a
    --    host), live-user gate, and skip anyone already host/staff (their
    --    seat already exists — idempotent).
    IF p_staff_ids IS NOT NULL AND array_length(p_staff_ids, 1) > 0 THEN
        FOR v_candidate IN
            SELECT DISTINCT unnest(p_staff_ids)
        LOOP
            IF v_candidate = v_me THEN
                CONTINUE; -- never staff yourself
            END IF;
            IF array_length(v_clean, 1) >= 20 THEN
                RETURN jsonb_build_object('status', 'too_many_staff');
            END IF;

            IF NOT EXISTS (
                SELECT 1 FROM public.users
                WHERE id = v_candidate AND deleted_at IS NULL
            ) THEN
                RETURN jsonb_build_object('status', 'staff_not_allowed');
            END IF;
            IF EXISTS (
                SELECT 1 FROM public.event_hosts
                WHERE event_id = p_event_id AND user_id = v_candidate
            ) THEN
                CONTINUE; -- already host/staff: no-op
            END IF;

            v_clean := v_clean || v_candidate;
        END LOOP;
    END IF;

    -- 6. Capacity check. Current reserved seats = event_hosts + live
    --    event_invites rows (declined rows are deleted, so every row lives).
    --    A candidate holding an invite is CONVERTED (invite deleted, seat
    --    moves into event_hosts) → seat-neutral; a candidate with no invite
    --    adds one seat.
    IF (SELECT count(*)::integer FROM public.event_hosts
        WHERE event_id = p_event_id)
       + (SELECT count(*)::integer FROM public.event_invites
          WHERE event_id = p_event_id)
       + COALESCE((
            SELECT count(*)::integer FROM unnest(v_clean) AS c(uid)
            WHERE NOT EXISTS (
                SELECT 1 FROM public.event_invites ei
                WHERE ei.event_id = p_event_id AND ei.user_id = c.uid
            )
         ), 0) > v_capacity THEN
        RETURN jsonb_build_object('status', 'capacity_reached');
    END IF;

    -- 7. Insert staff rows (converting any existing invite seat).
    IF array_length(v_clean, 1) > 0 THEN
        FOREACH v_candidate IN ARRAY v_clean
        LOOP
            DELETE FROM public.event_invites
            WHERE event_id = p_event_id AND user_id = v_candidate;
            INSERT INTO public.event_hosts (event_id, user_id, role)
            VALUES (p_event_id, v_candidate, 'staff'::public.event_role);
            v_added := v_added + 1;
        END LOOP;
    END IF;

    RETURN jsonb_build_object('status', 'ok', 'added', v_added);
END;
$$;

-- ======================================================================
-- remove_event_staff(uuid, uuid)
-- ----------------------------------------------------------------------
-- The host removes [p_staff_user_id] from [p_event_id]'s staff. Returns:
--   ok / not_authenticated / event_not_found / event_closed / not_host /
--   host_not_removable
-- `ok` is idempotent (removing a non-existent member is already-gone); the
-- host row itself can never be removed (host_not_removable). Removing frees
-- the staff member's seat (their invite was converted away on designation,
-- so no guest seat is restored).
-- ======================================================================
CREATE OR REPLACE FUNCTION public.remove_event_staff(p_event_id uuid, p_staff_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_status public.event_status;
    v_role public.event_role;
BEGIN
    -- 1. Authentication gate.
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Event lifecycle gate.
    SELECT status INTO v_status
    FROM public.events
    WHERE id = p_event_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'event_not_found');
    END IF;
    IF v_status IN ('ended', 'cancelled') THEN
        RETURN jsonb_build_object('status', 'event_closed');
    END IF;

    -- 3. Host gate: the CREATOR or a role=host member may remove.
    IF NOT EXISTS (
        SELECT 1 FROM public.events
        WHERE id = p_event_id AND created_by_user_id = v_me
    ) AND NOT EXISTS (
        SELECT 1 FROM public.event_hosts
        WHERE event_id = p_event_id AND user_id = v_me
          AND role = 'host'
    ) THEN
        RETURN jsonb_build_object('status', 'not_host');
    END IF;

    -- 4. Target membership (row lock for serialization).
    SELECT role INTO v_role
    FROM public.event_hosts
    WHERE event_id = p_event_id AND user_id = p_staff_user_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'ok'); -- already gone: idempotent
    END IF;
    IF v_role = 'host' THEN
        RETURN jsonb_build_object('status', 'host_not_removable');
    END IF;

    -- 5. Remove the staff row (seat freed).
    DELETE FROM public.event_hosts
    WHERE event_id = p_event_id AND user_id = p_staff_user_id
      AND role = 'staff';

    RETURN jsonb_build_object('status', 'ok');
END;
$$;

-- ======================================================================
-- event_hosts RLS: drop the legacy client INSERT policy (capacity-bypass
-- hole; writes are RPC-only now) and open the FULL roster read to the
-- event's hosts/staff via the security-barrier view (recursion-free).
-- ep_read_own stays: everyone keeps reading their own row.
-- ======================================================================
DROP POLICY IF EXISTS ep_insert_host ON public.event_hosts;

CREATE POLICY ep_read_event_access ON public.event_hosts FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM public.event_host_access_view eh
        WHERE eh.event_id = event_hosts.event_id
          AND eh.user_id = auth.uid()
    )
);

-- The policy references event_host_access_view, so the API roles MUST hold
-- SELECT on it — on a pristine schema (fresh init/apply) an ungranted view
-- makes every event_hosts read fail with "permission denied for view". Safe
-- because the view projects only `user_id = auth.uid()` rows: no client can
-- see any roster but their own through it (full-roster reads go through
-- event_hosts + the policy above). REVOKE FROM PUBLIC keeps it off anon-able
-- default ACLs; anon SELECT returns zero rows (auth.uid() is NULL).
REVOKE ALL ON public.event_host_access_view FROM PUBLIC;
GRANT SELECT ON public.event_host_access_view TO anon;
GRANT SELECT ON public.event_host_access_view TO authenticated;
GRANT SELECT ON public.event_host_access_view TO service_role;

-- ======================================================================
-- ACLs — hardened posture (no PUBLIC; authenticated + service_role only).
-- ======================================================================
REVOKE ALL ON FUNCTION public.designate_event_staff(p_event_id uuid, p_staff_ids uuid[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.designate_event_staff(p_event_id uuid, p_staff_ids uuid[]) TO authenticated;
GRANT ALL ON FUNCTION public.designate_event_staff(p_event_id uuid, p_staff_ids uuid[]) TO service_role;

REVOKE ALL ON FUNCTION public.remove_event_staff(p_event_id uuid, p_staff_user_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.remove_event_staff(p_event_id uuid, p_staff_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.remove_event_staff(p_event_id uuid, p_staff_user_id uuid) TO service_role;
