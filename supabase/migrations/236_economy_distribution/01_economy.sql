-- ============================================================================
-- 236_economy_distribution/01_economy.sql — E1 economy
--
-- 1. dispatch_shard_distribution() now performs the real, idempotent,
--    transactional distribution on `status = 'ended'` instead of only logging.
-- 2. Eligibility is confirmed `event_attendances` EXCLUDING hosts. Hosts get
--    only the configured remainder; there is no host attendance payout.
-- 3. Remainder: `redistribute` splits it among confirmed attendees (exact sum),
--    otherwise it returns to the hosts (default) proportional to their
--    contribution. A pool is never burned silently.
-- 4. Cancellation is only allowed while `status = 'upcoming'`; each host is
--    refunded its own contribution and the pool is zeroed. There is no refund
--    after distribution.
-- 5. A cron fallback distributes any ended event missed by the trigger, plus a
--    read-only reconciliation report/alert and a service-only audited
--    correction.
--
-- Rollback: restore the 060/03 bodies and drop the new functions/triggers/cron
-- jobs. Forward-fix only for payout semantics (never burn a pool).
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Real distribution.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.distribute_shards(p_event_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_event       RECORD;
    v_host        RECORD;
    v_attendee    RECORD;
    v_attendees   uuid[];
    v_confirmed   integer;
    v_pool        integer;
    v_per_user    integer;
    v_remainder   integer;
    v_base        integer;
    v_extra       integer;
    v_i           integer := 0;
    v_share       integer;
    v_host_total  integer;
    v_host_share  integer;
    v_host_left   integer;
    v_returned    integer := 0;
    v_target      uuid;
BEGIN
    SELECT * INTO v_event FROM public.events WHERE id = p_event_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'event_not_found' USING ERRCODE = 'P0001';
    END IF;
    IF v_event.preshards_distributed THEN
        RETURN jsonb_build_object('status', 'skipped', 'reason', 'already distributed');
    END IF;
    IF v_event.status <> 'ended' THEN
        RETURN jsonb_build_object(
            'status', 'skipped',
            'reason', 'not_ended',
            'event_status', v_event.status);
    END IF;

    -- Confirmed attendees only, minus hosts; deterministic order.
    SELECT COALESCE(array_agg(ea.user_id ORDER BY ea.user_id), '{}'::uuid[])
      INTO v_attendees
      FROM public.event_attendances ea
     WHERE ea.event_id = p_event_id
       AND NOT EXISTS (
            SELECT 1 FROM public.event_hosts h
             WHERE h.event_id = p_event_id AND h.user_id = ea.user_id);

    v_confirmed := COALESCE(array_length(v_attendees, 1), 0);
    v_pool := GREATEST(v_event.preshards_pool, 0);

    -- No eligible attendee: return each host's own contribution.
    IF v_confirmed = 0 THEN
        FOR v_host IN
            SELECT user_id, preshards_contributed
              FROM public.event_hosts
             WHERE event_id = p_event_id AND preshards_contributed > 0
             ORDER BY user_id
        LOOP
            UPDATE public.users
               SET preshards = preshards + v_host.preshards_contributed
             WHERE id = v_host.user_id;
            INSERT INTO public.preshard_ledger (user_id, delta, reason, reference_id)
            VALUES (v_host.user_id, v_host.preshards_contributed,
                    'event_pool_returned', p_event_id);
            v_returned := v_returned + v_host.preshards_contributed;
        END LOOP;

        UPDATE public.events
           SET preshards_pool = 0, preshards_distributed = true
         WHERE id = p_event_id;

        RETURN jsonb_build_object(
            'status', 'completed', 'attendees', 0,
            'action', 'full_return', 'returned', v_returned);
    END IF;

    v_per_user := v_pool / v_confirmed;
    IF v_event.preshards_cap_per_user IS NOT NULL THEN
        v_per_user := LEAST(v_per_user, v_event.preshards_cap_per_user);
    END IF;

    IF v_per_user > 0 THEN
        FOR v_attendee IN
            SELECT ea.user_id
              FROM public.event_attendances ea
             WHERE ea.event_id = p_event_id
               AND ea.user_id = ANY (v_attendees)
             ORDER BY ea.user_id
        LOOP
            UPDATE public.users
               SET personal_shards = personal_shards + v_per_user
             WHERE id = v_attendee.user_id;
            UPDATE public.event_attendances
               SET shards_received = v_per_user
             WHERE event_id = p_event_id AND user_id = v_attendee.user_id;
            INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
            VALUES (v_attendee.user_id, v_per_user, 'event_attendance', p_event_id);
        END LOOP;
    END IF;

    v_remainder := v_pool - (v_per_user * v_confirmed);

    IF v_remainder > 0 THEN
        IF v_event.preshards_remainder_action = 'redistribute' THEN
            -- Exact split: base + one extra for the first `extra` attendees.
            v_base := v_remainder / v_confirmed;
            v_extra := v_remainder % v_confirmed;
            v_i := 0;
            FOR v_attendee IN
                SELECT unnest(v_attendees) AS user_id
            LOOP
                v_i := v_i + 1;
                v_share := v_base + CASE WHEN v_i <= v_extra THEN 1 ELSE 0 END;
                IF v_share > 0 THEN
                    UPDATE public.users
                       SET personal_shards = personal_shards + v_share
                     WHERE id = v_attendee.user_id;
                    UPDATE public.event_attendances
                       SET shards_received = shards_received + v_share
                     WHERE event_id = p_event_id AND user_id = v_attendee.user_id;
                    INSERT INTO public.shard_ledger
                        (user_id, delta, reason, reference_id)
                    VALUES (v_attendee.user_id, v_share,
                            'event_attendance', p_event_id);
                END IF;
            END LOOP;
        ELSE
            -- Default `return`: proportional to contribution, exact sum.
            SELECT COALESCE(SUM(preshards_contributed), 0)
              INTO v_host_total
              FROM public.event_hosts
             WHERE event_id = p_event_id AND preshards_contributed > 0;

            IF v_host_total > 0 THEN
                v_host_left := v_remainder;
                FOR v_host IN
                    SELECT user_id, preshards_contributed
                      FROM public.event_hosts
                     WHERE event_id = p_event_id AND preshards_contributed > 0
                     ORDER BY preshards_contributed DESC, user_id
                LOOP
                    v_host_share := (v_remainder * v_host.preshards_contributed)
                                    / v_host_total;
                    v_host_share := LEAST(v_host_share, v_host_left);
                    IF v_host_share > 0 THEN
                        UPDATE public.users
                           SET preshards = preshards + v_host_share
                         WHERE id = v_host.user_id;
                        INSERT INTO public.preshard_ledger
                            (user_id, delta, reason, reference_id)
                        VALUES (v_host.user_id, v_host_share,
                                'event_pool_returned', p_event_id);
                        v_host_left := v_host_left - v_host_share;
                        v_returned := v_returned + v_host_share;
                    END IF;
                END LOOP;

                -- Rounding residue goes to the largest contributor (deterministic).
                IF v_host_left > 0 THEN
                    SELECT user_id INTO v_target
                      FROM public.event_hosts
                     WHERE event_id = p_event_id AND preshards_contributed > 0
                     ORDER BY preshards_contributed DESC, user_id
                     LIMIT 1;
                    UPDATE public.users
                       SET preshards = preshards + v_host_left
                     WHERE id = v_target;
                    INSERT INTO public.preshard_ledger
                        (user_id, delta, reason, reference_id)
                    VALUES (v_target, v_host_left, 'event_pool_returned', p_event_id);
                    v_returned := v_returned + v_host_left;
                END IF;
            ELSE
                -- No recorded contribution: never burn; give it to the creator
                -- (fallback: the first host).
                SELECT user_id INTO v_target
                  FROM public.event_hosts
                 WHERE event_id = p_event_id
                 ORDER BY (user_id = v_event.created_by_user_id) DESC, user_id
                 LIMIT 1;
                IF v_target IS NOT NULL THEN
                    UPDATE public.users
                       SET preshards = preshards + v_remainder
                     WHERE id = v_target;
                    INSERT INTO public.preshard_ledger
                        (user_id, delta, reason, reference_id)
                    VALUES (v_target, v_remainder, 'event_pool_returned', p_event_id);
                    v_returned := v_returned + v_remainder;
                END IF;
            END IF;
        END IF;
    END IF;

    -- The pool was already deducted from the hosts and recorded as
    -- `event_pool_set` when the event was created. Do NOT write a second
    -- `event_pool_consumed` entry here: the wallet/ledger invariant is that
    -- the sum of ledger deltas equals the wallet balance.

    UPDATE public.events
       SET preshards_pool = 0, preshards_distributed = true
     WHERE id = p_event_id;

    RETURN jsonb_build_object(
        'status', 'completed',
        'attendees', v_confirmed,
        'per_user', v_per_user,
        'remainder', v_remainder,
        'remainder_action', COALESCE(v_event.preshards_remainder_action::text, 'return'),
        'returned', v_returned);
END;
$$;

REVOKE ALL ON FUNCTION public.distribute_shards(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.distribute_shards(uuid) TO service_role;

-- Trigger body: real distribution, still idempotent inside distribute_shards.
CREATE OR REPLACE FUNCTION public.dispatch_shard_distribution()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    IF NEW.status = 'ended' AND COALESCE(NEW.preshards_distributed, false) = false THEN
        PERFORM public.distribute_shards(NEW.id);
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.dispatch_shard_distribution() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dispatch_shard_distribution() TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Cancellation only before start.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_cancel_only_upcoming()
RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    IF NEW.status = 'cancelled'
       AND OLD.status <> 'cancelled'
       AND OLD.status <> 'upcoming' THEN
        RAISE EXCEPTION 'cancel_only_before_start' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_cancel_only_upcoming() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS events_cancel_only_upcoming ON public.events;
CREATE TRIGGER events_cancel_only_upcoming
    BEFORE UPDATE OF status ON public.events
    FOR EACH ROW
    WHEN (NEW.status = 'cancelled' AND OLD.status <> 'cancelled')
    EXECUTE FUNCTION public.assert_cancel_only_upcoming();

-- ---------------------------------------------------------------------------
-- 3. Cron fallback for missed distributions.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.distribute_pending_event_shards()
RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_row RECORD;
    v_done integer := 0;
BEGIN
    FOR v_row IN
        SELECT id FROM public.events
         WHERE status = 'ended' AND preshards_distributed = false
         ORDER BY ends_at
    LOOP
        BEGIN
            PERFORM public.distribute_shards(v_row.id);
            v_done := v_done + 1;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'distribute_pending_event_shards: event % failed: %',
                v_row.id, SQLERRM;
        END;
    END LOOP;
    RETURN v_done;
END;
$$;

REVOKE ALL ON FUNCTION public.distribute_pending_event_shards()
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.distribute_pending_event_shards() TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Read-only ledger reconciliation + alert.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.economy_ledger_reconciliation()
RETURNS TABLE(
    user_id uuid,
    wallet_shards bigint,
    ledger_shards bigint,
    shard_delta bigint,
    wallet_preshards bigint,
    ledger_preshards bigint,
    preshard_delta bigint
)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    WITH shard AS (
        SELECT u.id,
               u.personal_shards::bigint AS wallet,
               COALESCE(SUM(l.delta), 0)::bigint AS ledger
          FROM public.users u
          LEFT JOIN public.shard_ledger l ON l.user_id = u.id
         GROUP BY u.id, u.personal_shards
    ),
    preshard AS (
        SELECT u.id,
               u.preshards::bigint AS wallet,
               COALESCE(SUM(l.delta), 0)::bigint AS ledger
          FROM public.users u
          LEFT JOIN public.preshard_ledger l ON l.user_id = u.id
         GROUP BY u.id, u.preshards
    )
    SELECT s.id,
           s.wallet,
           s.ledger,
           s.wallet - s.ledger,
           p.wallet,
           p.ledger,
           p.wallet - p.ledger
      FROM shard s
      JOIN preshard p ON p.id = s.id;
$$;

REVOKE ALL ON FUNCTION public.economy_ledger_reconciliation()
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.economy_ledger_reconciliation() TO service_role;

CREATE OR REPLACE FUNCTION public.log_economy_ledger_alerts()
RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_row RECORD;
    v_n integer := 0;
BEGIN
    FOR v_row IN
        SELECT * FROM public.economy_ledger_reconciliation()
         WHERE shard_delta <> 0 OR preshard_delta <> 0
    LOOP
        RAISE WARNING
            'economy ledger mismatch user=% shard wallet/ledger/delta=%/%/% preshard %/%/%',
            v_row.user_id,
            v_row.wallet_shards, v_row.ledger_shards, v_row.shard_delta,
            v_row.wallet_preshards, v_row.ledger_preshards, v_row.preshard_delta;
        v_n := v_n + 1;
    END LOOP;
    RETURN v_n;
END;
$$;

REVOKE ALL ON FUNCTION public.log_economy_ledger_alerts()
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_economy_ledger_alerts() TO service_role;

-- Per-event reconciliation: what the event paid vs what the ledgers recorded.
CREATE OR REPLACE FUNCTION public.event_economy_reconciliation(p_event_id uuid)
RETURNS TABLE(
    user_id uuid,
    role text,
    shards_received bigint,
    shard_ledger_sum bigint,
    shard_delta bigint,
    preshards_contributed bigint,
    preshard_ledger_sum bigint,
    preshard_delta bigint
)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    WITH sh AS (
        SELECT l.user_id, COALESCE(SUM(l.delta), 0)::bigint AS total
          FROM public.shard_ledger l
         WHERE l.reference_id = p_event_id
         GROUP BY l.user_id
    ),
    pr AS (
        SELECT l.user_id, COALESCE(SUM(l.delta), 0)::bigint AS total
          FROM public.preshard_ledger l
         WHERE l.reference_id = p_event_id
         GROUP BY l.user_id
    ),
    att AS (
        SELECT a.user_id, a.shards_received::bigint AS received
          FROM public.event_attendances a
         WHERE a.event_id = p_event_id
    ),
    host AS (
        SELECT h.user_id, h.preshards_contributed::bigint AS contributed
          FROM public.event_hosts h
         WHERE h.event_id = p_event_id
    )
    SELECT COALESCE(att.user_id, host.user_id, sh.user_id, pr.user_id),
           CASE
               WHEN att.user_id IS NOT NULL AND host.user_id IS NOT NULL THEN 'host_attendee'
               WHEN att.user_id IS NOT NULL THEN 'attendee'
               ELSE 'host'
           END,
           COALESCE(att.received, 0),
           COALESCE(sh.total, 0),
           COALESCE(att.received, 0) - COALESCE(sh.total, 0),
           COALESCE(host.contributed, 0),
           COALESCE(pr.total, 0),
           COALESCE(pr.total, 0) + COALESCE(host.contributed, 0)
      FROM att
      FULL JOIN host ON host.user_id = att.user_id
      FULL JOIN sh ON sh.user_id = COALESCE(att.user_id, host.user_id)
      FULL JOIN pr ON pr.user_id = COALESCE(att.user_id, host.user_id)
     WHERE COALESCE(att.user_id, host.user_id) IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.event_economy_reconciliation(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_economy_reconciliation(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Audited admin correction (service_role only, never automatic).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_correct_balance(
    p_user_id uuid,
    p_shard_delta integer DEFAULT 0,
    p_preshard_delta integer DEFAULT 0,
    p_reason text DEFAULT NULL
) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_system_admin uuid := '00000000-0000-0000-0000-000000000000';
BEGIN
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'reason_required' USING ERRCODE = 'P0001';
    END IF;
    IF p_shard_delta = 0 AND p_preshard_delta = 0 THEN
        RAISE EXCEPTION 'zero_correction' USING ERRCODE = 'P0001';
    END IF;

    IF p_shard_delta <> 0 THEN
        UPDATE public.users
           SET personal_shards = personal_shards + p_shard_delta
         WHERE id = p_user_id
           AND personal_shards + p_shard_delta >= 0;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'invalid_shard_correction' USING ERRCODE = 'P0001';
        END IF;
        INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
        VALUES (p_user_id, p_shard_delta, 'admin_grant', NULL);
    END IF;

    IF p_preshard_delta <> 0 THEN
        UPDATE public.users
           SET preshards = preshards + p_preshard_delta
         WHERE id = p_user_id
           AND preshards + p_preshard_delta >= 0;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'invalid_preshard_correction' USING ERRCODE = 'P0001';
        END IF;
        INSERT INTO public.preshard_ledger (user_id, delta, reason, reference_id)
        VALUES (p_user_id, p_preshard_delta, 'admin_grant', NULL);
    END IF;

    INSERT INTO public.admin_audit_log
        (admin_user_id, action, target_type, target_id, details)
    VALUES (
        v_system_admin,
        'economy_correction',
        'user',
        p_user_id::text,
        jsonb_build_object(
            'reason', p_reason,
            'shard_delta', p_shard_delta,
            'preshard_delta', p_preshard_delta,
            'source', 'admin_correct_balance'));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_correct_balance(uuid, integer, integer, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_correct_balance(uuid, integer, integer, text)
    TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Schedules (idempotent upsert by name).
-- ---------------------------------------------------------------------------
DO $job$ BEGIN
    PERFORM cron.schedule('events-distribute-missed', '*/5 * * * *',
        $cmd$SELECT public.distribute_pending_event_shards();$cmd$);
END $job$;

DO $job$ BEGIN
    PERFORM cron.schedule('economy-ledger-alert', '45 4 * * *',
        $cmd$SELECT public.log_economy_ledger_alerts();$cmd$);
END $job$;

COMMIT;
