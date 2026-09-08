-- Samay — 060_events/06_staff.sql
--
-- Host designates staff (Stage 3, 2026-09-08). The HOST (creator or any
-- role=host member) can designate specific users as STAFF for an event and
-- remove them again; everyone on the roster (host + staff) reads the full
-- host/staff list, and host/staff are treated as ATTENDEES for the QR/swirl
-- token surface (they generate their own code like invited guests do).
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
--     `event_host_access_view` (view runs as its owner postgres, which has
--     rolbypassrls — the view is NOT granted to any role, so no client can
--     query it directly; only the policy subquery reaches it).
--   * rotate_qr_token / validate_qr_token attendee gates are widened to count
--     event_hosts members (host + staff) as attendees: they may generate
--     their own attendance code and be validated/confirmed like invited
--     guests. (The invite-flip UPDATE simply affects zero rows for hosts/staff
--     — attendance is recorded in event_attendances for everyone.)

-- ======================================================================
-- event_host_access_view — security-barrier projection of event_hosts used
-- ONLY by the ep_read_event_access policy (recursion workaround). No grants:
-- invisible to anon/authenticated/service_role through PostgREST.
-- ======================================================================
CREATE OR REPLACE VIEW public.event_host_access_view WITH (security_barrier='true') AS
SELECT event_id, user_id, role
FROM public.event_hosts;

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

-- ======================================================================
-- rotate_qr_token / validate_qr_token — attendee gates widened to treat
-- event_hosts members (host + staff) as attendees: everyone on the event
-- generates their own attendance code and can be confirmed. The event_invites
-- flip in validate_qr_token affects zero rows for hosts/staff; attendance is
-- recorded in event_attendances for every confirmed person.
-- ======================================================================
CREATE OR REPLACE FUNCTION public.rotate_qr_token(p_event_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_activation_minutes integer;
    v_token_valid_seconds integer;
    v_event RECORD;
    v_token RECORD;
BEGIN
    IF v_me IS NULL THEN
        RAISE EXCEPTION 'Not authorized';
    END IF;

    SELECT COALESCE(
        (SELECT value::integer FROM public.app_config
         WHERE key = 'qr.activation_minutes_before'), 30
    ) INTO v_activation_minutes;
    SELECT COALESCE(
        (SELECT value::integer FROM public.app_config
         WHERE key = 'qr.token_valid_seconds'), 15
    ) INTO v_token_valid_seconds;

    -- Activation window (QRAT / MVP §6.4): the QR exists only from
    -- `starts_at - activation_minutes` until the event ends.
    SELECT * INTO v_event FROM public.events WHERE id = p_event_id;
    IF NOT FOUND OR v_event.status NOT IN ('upcoming', 'live')
       OR now() < v_event.starts_at - make_interval(mins => v_activation_minutes)
       OR (v_event.ends_at IS NOT NULL AND now() > v_event.ends_at) THEN
        RETURN jsonb_build_object('status', 'not_in_window');
    END IF;

    -- Attendee gate (060_events/06_staff.sql): hosts/staff are attendees too.
    -- Everyone on the event — host, staff, invited guest (not declined) —
    -- holds their own attendance code. Declined invites no longer exist
    -- (deleted), so presence in event_hosts OR event_invites is the gate.
    IF NOT EXISTS (
        SELECT 1 FROM public.event_hosts
        WHERE event_id = p_event_id AND user_id = v_me
    ) AND NOT EXISTS (
        SELECT 1 FROM public.event_invites
        WHERE event_id = p_event_id AND user_id = v_me
    ) THEN
        RETURN jsonb_build_object('status', 'not_invited');
    END IF;

    -- Serialize concurrent rotates for the same (event, user).
    PERFORM pg_advisory_xact_lock(hashtext(p_event_id::text || v_me::text));

    -- Return the still-valid current token; otherwise rotate.
    SELECT * INTO v_token FROM public.event_qr_tokens
    WHERE event_id = p_event_id AND user_id = v_me
    ORDER BY created_at DESC LIMIT 1;

    IF v_token.id IS NOT NULL
       AND v_token.expires_at > now()
       AND NOT v_token.attendance_confirmed THEN
        RETURN jsonb_build_object(
            'status', 'ok',
            'token', v_token.token,
            'expiresAt', v_token.expires_at
        );
    END IF;

    -- Invalidate the previous token(s) so a captured old QR dies instantly
    -- (QEDG rotation semantics), then issue the fresh one.
    UPDATE public.event_qr_tokens
    SET expires_at = now()
    WHERE event_id = p_event_id AND user_id = v_me
      AND expires_at > now();

    INSERT INTO public.event_qr_tokens (event_id, user_id, expires_at)
    VALUES (p_event_id, v_me, now() + make_interval(secs => v_token_valid_seconds))
    RETURNING token, expires_at INTO v_token.token, v_token.expires_at;

    RETURN jsonb_build_object(
        'status', 'ok',
        'token', v_token.token,
        'expiresAt', v_token.expires_at
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.validate_qr_token(p_event_id uuid, p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_activation_minutes integer;
    v_event RECORD;
    v_token_row RECORD;
BEGIN
    -- 1. Scanner-role check (QRSC: host/staff only). auth.uid()
    --    resolves in the auth schema by explicit qualification; anon callers
    --    (auth.uid() = NULL) fail this gate.
    IF NOT EXISTS (
        SELECT 1 FROM public.event_hosts
        WHERE event_id = p_event_id
          AND user_id = auth.uid()
          AND role IN ('host', 'staff')
    ) THEN
        RETURN jsonb_build_object('status', 'not_host');
    END IF;

    -- 2. Event window (QEDG §Function 2 step 2): status IN ('upcoming','live')
    --    AND now() >= starts_at - qr.activation_minutes_before (default 30).
    SELECT COALESCE(
        (SELECT value::integer FROM public.app_config
         WHERE key = 'qr.activation_minutes_before'),
        30
    ) INTO v_activation_minutes;

    SELECT * INTO v_event FROM public.events WHERE id = p_event_id;
    IF NOT FOUND OR v_event.status NOT IN ('upcoming', 'live')
       OR now() < v_event.starts_at - make_interval(mins => v_activation_minutes)
       OR (v_event.ends_at IS NOT NULL AND now() > v_event.ends_at) THEN
        RETURN jsonb_build_object('status', 'not_in_window');
    END IF;

    -- 3. Token lock + validation (QEDG steps 3-5). FOR UPDATE holds the row
    --    lock until the transaction commits — concurrent scans serialize, so
    --    a token can never be confirmed twice (MVP §6.4).
    SELECT * INTO v_token_row
    FROM public.event_qr_tokens
    WHERE event_id = p_event_id AND token = p_token
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'invalid_token');
    END IF;
    IF v_token_row.expires_at <= now() THEN
        RETURN jsonb_build_object('status', 'expired');
    END IF;
    IF v_token_row.scanned_at IS NOT NULL OR v_token_row.attendance_confirmed THEN
        RETURN jsonb_build_object('status', 'already_scanned');
    END IF;

    -- 4. Attendee gate (060_events/06_staff.sql): the token holder is an
    --    attendee if they are host/staff (event_hosts) OR hold a live invite.
    --    Declined invites are gone (deleted), so any event_invites row is
    --    valid. Hosts/staff carry no invite row — their token is their ticket.
    IF NOT EXISTS (
        SELECT 1 FROM public.event_hosts
        WHERE event_id = p_event_id AND user_id = v_token_row.user_id
    ) AND NOT EXISTS (
        SELECT 1 FROM public.event_invites
        WHERE event_id = p_event_id AND user_id = v_token_row.user_id
    ) THEN
        RETURN jsonb_build_object('status', 'not_invited');
    END IF;

    -- 5. Atomic writes (QEDG step 6) — one transaction. The invite flip is a
    --    no-op for host/staff holders (no invite row); event_attendances
    --    records every confirmed person.
    UPDATE public.event_qr_tokens
    SET scanned_at = now(), attendance_confirmed = true
    WHERE id = v_token_row.id;

    INSERT INTO public.event_attendances (event_id, user_id)
    VALUES (p_event_id, v_token_row.user_id)
    ON CONFLICT (event_id, user_id) DO NOTHING;

    UPDATE public.event_invites
    SET status = 'attended',
        responded_at = COALESCE(responded_at, now())
    WHERE event_id = p_event_id AND user_id = v_token_row.user_id;

    RETURN jsonb_build_object(
        'status', 'confirmed',
        'attendeeUserId', v_token_row.user_id,
        'attendeeName', (SELECT username FROM public.users WHERE id = v_token_row.user_id),
        'confirmedAt', now()
    );
END;
$$;

-- ======================================================================
-- ACLs — hardened posture (no PUBLIC; authenticated + service_role only).
-- The rotate/validate redefinitions keep their existing ACLs (authenticated
-- only, set in 02_qr.sql — CREATE OR REPLACE preserves them).
-- ======================================================================
REVOKE ALL ON FUNCTION public.designate_event_staff(p_event_id uuid, p_staff_ids uuid[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.designate_event_staff(p_event_id uuid, p_staff_ids uuid[]) TO authenticated;
GRANT ALL ON FUNCTION public.designate_event_staff(p_event_id uuid, p_staff_ids uuid[]) TO service_role;

REVOKE ALL ON FUNCTION public.remove_event_staff(p_event_id uuid, p_staff_user_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.remove_event_staff(p_event_id uuid, p_staff_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.remove_event_staff(p_event_id uuid, p_staff_user_id uuid) TO service_role;
