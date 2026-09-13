-- Samay — 060_events/05_manual_invites.sql
--
-- Manual guest invites (Stage 2, 2026-09-08): the HOST of an event invites
-- SPECIFIC users (search + multi-select, reusing the minigame invite
-- mechanism), each invitee receives an `event_invite` notification and can
-- accept or decline, and the event stays under its frozen `events.capacity`
-- (total incl. host + staff + guests, Stage-1 semantics).
--
-- Model (mirrors the 140/205 minigame-invite family):
--
--   * event_invites already exists with UNIQUE(event_id, user_id), status
--     pending/accepted/declined/attended and the notify_event_invite
--     AFTER-INSERT trigger (110) that dispatches the invitee's notification.
--     Rows are written ONLY by this RPC family (SECURITY DEFINER); the legacy
--     client ei_update_own UPDATE policy is DROPPED so a pending invite can
--     never be flipped by a raw table update (capacity/attendance stays a
--     server contract).
--   * invite_event_guests(p_event_id, p_invitees) — CREATOR/host-gated,
--     idempotent (already pending/accepted/attended invitees are skipped),
--     per-invitee gates (live user, NOT blocked either direction), and a
--     seat-reservation capacity check: event_hosts + all non-declined
--     event_invites rows + the NEW invitees must fit events.capacity.
--   * accept_event_invite(p_invite_id) — the invitee flips pending → accepted
--     (responded_at). Idempotent; declined/attended rows reject.
--   * decline_event_invite(p_invite_id) — the invitee DELETES their pending
--     row (2026-09-02 user directive: a declined invite is indistinguishable
--     from one that never existed, so the seat frees and a later re-invite is
--     a fresh INSERT with a fresh notification).
--   * ei_read_event_access SELECT policy: hosts/staff of the event read the
--     full guest roster (event detail "who is invited / attending"), while
--     everyone else keeps reading only their own rows (ei_read_own).
--
-- Capacity semantics: `events.capacity` is the total headcount (host + staff
-- + guests). Pending invites RESERVE a seat (that is what makes over-inviting
-- impossible while guests are still undecided); a decline frees it again.

-- ======================================================================
-- invite_event_guests(uuid, uuid[])
-- ----------------------------------------------------------------------
-- The host invites [p_invitees] to [p_event_id]. Returns jsonb:
--   ok / not_authenticated / event_not_found / event_closed / not_host /
--   invitee_not_allowed / too_many_invitees / capacity_reached
-- `ok` carries "invited": the count of NEW pending rows inserted (idempotent
-- re-invites report 0). Each inserted row fires notify_event_invite_trigger
-- (the invitee's event_invite notification) exactly once.
-- ======================================================================
CREATE FUNCTION public.invite_event_guests(p_event_id uuid, p_invitees uuid[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_capacity integer;
    v_status public.event_status;
    v_invitee uuid;
    v_invited integer := 0;
    v_clean_invitees uuid[] := '{}'::uuid[];
BEGIN
    -- 1. Authentication gate.
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Event lookup + row lock (serialize concurrent invites / capacity).
    SELECT capacity, status INTO v_capacity, v_status
    FROM public.events
    WHERE id = p_event_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'event_not_found');
    END IF;

    -- 3. Lifecycle gate: no invites into a finished/cancelled event.
    IF v_status IN ('ended', 'cancelled') THEN
        RETURN jsonb_build_object('status', 'event_closed');
    END IF;

    -- 4. Host gate: the CREATOR may invite; event_hosts with role host or
    --    staff may also invite (staff arrive in Stage 3 — kept in the gate
    --    so Stage 3 adds only UI, not schema).
    IF NOT EXISTS (
        SELECT 1 FROM public.events
        WHERE id = p_event_id AND created_by_user_id = v_me
    ) AND NOT EXISTS (
        SELECT 1 FROM public.event_hosts
        WHERE event_id = p_event_id AND user_id = v_me
          AND role IN ('host', 'staff')
    ) THEN
        RETURN jsonb_build_object('status', 'not_host');
    END IF;

    -- 5. Invitee cleaning + per-invitee gates (mirror of 205): self skip,
    --    dedupe, live user (deleted_at IS NULL), NOT blocked either
    --    direction. A violation rejects the WHOLE batch atomically.
    IF p_invitees IS NOT NULL AND array_length(p_invitees, 1) > 0 THEN
        FOR v_invitee IN
            SELECT DISTINCT unnest(p_invitees)
        LOOP
            IF v_invitee = v_me THEN
                CONTINUE; -- never invite yourself
            END IF;
            IF array_length(v_clean_invitees, 1) >= 20 THEN
                RETURN jsonb_build_object('status', 'too_many_invitees');
            END IF;

            IF NOT EXISTS (
                SELECT 1 FROM public.users
                WHERE id = v_invitee AND deleted_at IS NULL
            ) THEN
                RETURN jsonb_build_object('status', 'invitee_not_allowed');
            END IF;
            IF EXISTS (
                SELECT 1 FROM public.friendships
                WHERE status = 'blocked'::public.friendship_status
                  AND ((requester_id = v_me AND addressee_id = v_invitee)
                    OR (requester_id = v_invitee AND addressee_id = v_me))
            ) THEN
                RETURN jsonb_build_object('status', 'invitee_not_allowed');
            END IF;

            v_clean_invitees := v_clean_invitees || v_invitee;
        END LOOP;
    END IF;

    -- 6. Idempotency: drop invitees who already hold a row (pending,
    --    accepted or attended — declined rows no longer exist because
    --    decline_event_invite deletes them, so a declined guest is a fresh
    --    invitee and re-inviting is a normal INSERT). Also drop invitees who
    --    are already host/staff of the event: their seat lives in
    --    event_hosts, never in event_invites.
    v_clean_invitees := ARRAY(
        SELECT t.v FROM unnest(v_clean_invitees) AS t(v)
        WHERE NOT EXISTS (
            SELECT 1 FROM public.event_invites ei
            WHERE ei.event_id = p_event_id AND ei.user_id = t.v
        )
        AND NOT EXISTS (
            SELECT 1 FROM public.event_hosts eh
            WHERE eh.event_id = p_event_id AND eh.user_id = t.v
        )
    );

    -- 7. Seat-reservation capacity check: host/staff seats (event_hosts) +
    --    every live guest row (pending/accepted/attended) + the NEW invitees
    --    must fit the frozen events.capacity. Declined rows are gone, so no
    --    exclusion term is needed here.
    IF (SELECT count(*)::integer FROM public.event_hosts
        WHERE event_id = p_event_id)
       + (SELECT count(*)::integer FROM public.event_invites
          WHERE event_id = p_event_id)
       + COALESCE(array_length(v_clean_invitees, 1), 0) > v_capacity THEN
        RETURN jsonb_build_object('status', 'capacity_reached');
    END IF;

    -- 8. Invite rows (one pending row per invitee; the notify trigger on
    --    event_invites dispatches the event_invite notification per row).
    IF array_length(v_clean_invitees, 1) > 0 THEN
        FOREACH v_invitee IN ARRAY v_clean_invitees
        LOOP
            INSERT INTO public.event_invites (event_id, user_id, invited_by_user_id)
            VALUES (p_event_id, v_invitee, v_me);
            v_invited := v_invited + 1;
        END LOOP;
    END IF;

    RETURN jsonb_build_object('status', 'ok', 'invited', v_invited);
END;
$$;

-- ======================================================================
-- accept_event_invite(uuid)
-- ----------------------------------------------------------------------
-- The INVITEE (self only) accepts a pending invite: pending → accepted,
-- responded_at set. Idempotent (repeat → already_accepted). Only PENDING
-- rows accept — a declined row is deleted (so reads invite_not_found) and an
-- attended row is past accepting. Accepts are allowed while the event is
-- still open (draft/upcoming/live); ended/cancelled → event_closed.
-- ======================================================================
CREATE FUNCTION public.accept_event_invite(p_invite_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_status public.invite_status;
    v_event_id uuid;
    v_event_status public.event_status;
BEGIN
    -- 1. Authentication gate.
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Own-invite lookup + row lock (the invitee_id filter folds the
    --    ownership gate into the lookup — a foreign row reads not_found).
    SELECT status, event_id INTO v_status, v_event_id
    FROM public.event_invites
    WHERE id = p_invite_id AND user_id = v_me
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'invite_not_found');
    END IF;

    -- 3. Idempotent accept / terminal-state guards.
    IF v_status = 'accepted' THEN
        RETURN jsonb_build_object('status', 'already_accepted');
    END IF;
    IF v_status = 'attended' THEN
        RETURN jsonb_build_object('status', 'already_attended');
    END IF;

    -- 4. Event lifecycle gate: accepting into an ended/cancelled event is
    --    meaningless (the seat can no longer be occupied).
    SELECT status INTO v_event_status
    FROM public.events WHERE id = v_event_id;
    IF NOT FOUND OR v_event_status IN ('ended', 'cancelled') THEN
        RETURN jsonb_build_object('status', 'event_closed');
    END IF;

    -- 5. Flip pending → accepted (responded_at). The seat was already
    --    reserved by the pending invite, so accept cannot exceed capacity.
    UPDATE public.event_invites
    SET status = 'accepted'::public.invite_status, responded_at = now()
    WHERE id = p_invite_id AND user_id = v_me;

    RETURN jsonb_build_object('status', 'accepted');
END;
$$;

-- ======================================================================
-- decline_event_invite(uuid)
-- ----------------------------------------------------------------------
-- The INVITEE (self only) declines a pending invite. The row is DELETED
-- (2026-09-02 user directive: "declined must delete the invite like it
-- never happened") — this is what frees the reserved seat and makes
-- RE-INVITE a plain fresh INSERT (UNIQUE(event_id, user_id) satisfied, and
-- notify_event_invite_trigger fires the INSERT-time notification again).
-- Accepted/attended invites cannot be declined.
-- ======================================================================
CREATE FUNCTION public.decline_event_invite(p_invite_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_status public.invite_status;
BEGIN
    -- 1. Authentication gate.
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Own-invite lookup + row lock (ownership folded into the lookup).
    SELECT status INTO v_status
    FROM public.event_invites
    WHERE id = p_invite_id AND user_id = v_me
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'invite_not_found');
    END IF;

    -- 3. Only pending invites decline (an accepted invite is committed; an
    --    attended invite already happened).
    IF v_status = 'accepted' THEN
        RETURN jsonb_build_object('status', 'already_accepted');
    END IF;
    IF v_status = 'attended' THEN
        RETURN jsonb_build_object('status', 'already_attended');
    END IF;

    -- 4. Delete the row (free the seat; a re-invite is a fresh invite).
    DELETE FROM public.event_invites
    WHERE id = p_invite_id AND user_id = v_me;

    RETURN jsonb_build_object('status', 'declined');
END;
$$;

-- ======================================================================
-- event_invites RLS: drop the legacy client UPDATE policy (accept/decline
-- now live in the SECURITY DEFINER family above) and open a HOST/STAFF read
-- policy so the event detail can show the guest roster per invite status.
-- FORCE RLS stays: non-privileged users keep ei_read_own (their rows only).
-- ======================================================================
DROP POLICY IF EXISTS ei_update_own ON public.event_invites;

CREATE POLICY ei_read_event_access ON public.event_invites FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM public.event_hosts
        WHERE event_hosts.event_id = event_invites.event_id
          AND event_hosts.user_id = auth.uid()
    )
);

-- ======================================================================
-- ACLs — hardened posture (no PUBLIC; authenticated + service_role only).
-- ======================================================================
REVOKE ALL ON FUNCTION public.invite_event_guests(p_event_id uuid, p_invitees uuid[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.invite_event_guests(p_event_id uuid, p_invitees uuid[]) TO authenticated;
GRANT ALL ON FUNCTION public.invite_event_guests(p_event_id uuid, p_invitees uuid[]) TO service_role;

REVOKE ALL ON FUNCTION public.accept_event_invite(p_invite_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.accept_event_invite(p_invite_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.accept_event_invite(p_invite_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.decline_event_invite(p_invite_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.decline_event_invite(p_invite_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.decline_event_invite(p_invite_id uuid) TO service_role;

-- ======================================================================
-- ACL hardening for the Stage-1 capacity helpers (04_capacity.sql created
-- them SECURITY DEFINER without revoking the default PUBLIC EXECUTE — the
-- pgTAP anon-EXECUTE gate (schema_test §48/49) tripped as soon as they
-- existed). They are server-internal (used by assert_event_capacity /
-- create_event and the admin opt-tests via service_role); no client calls
-- them, so service_role-only is the tightest posture.
-- ======================================================================
-- ======================================================================
-- ACL hardening for the Stage-1 capacity helpers (04_capacity.sql created
-- them SECURITY DEFINER without revoking the default PUBLIC EXECUTE — the
-- pgTAP anon-EXECUTE gate (schema_test §48/49) tripped as soon as they
-- existed). They are server-internal (used by assert_event_capacity /
-- create_event and the admin opt-tests via service_role); no client calls
-- them, so service_role-only is the tightest posture.
-- ======================================================================
REVOKE ALL ON FUNCTION public.event_seats_used(p_event_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.event_seats_used(p_event_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.assert_event_capacity() FROM PUBLIC;
GRANT ALL ON FUNCTION public.assert_event_capacity() TO service_role;
