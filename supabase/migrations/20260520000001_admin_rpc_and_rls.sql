-- Fixes for Phase 04 inconsistencies found during audit:
--   1. Missing RPCs called by Go CLI (grant_shards, grant_preshards, distribute_shards, recalculate_ranks)
--   2. users_search RLS is too permissive (reads all columns) → replaced with restricted view

-- ============================================================
-- 1. grant_shards: SECURITY DEFINER RPC for admin CLI
-- ============================================================
CREATE OR REPLACE FUNCTION grant_shards(
    p_user_id uuid,
    p_amount integer,
    p_reason text DEFAULT 'admin_grant'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE users SET personal_shards = personal_shards + p_amount
    WHERE id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;

    INSERT INTO shard_ledger (user_id, delta, reason, reference_id)
    VALUES (p_user_id, p_amount, p_reason, NULL);
END;
$$;

-- ============================================================
-- 2. grant_preshards: SECURITY DEFINER RPC for admin CLI
-- ============================================================
CREATE OR REPLACE FUNCTION grant_preshards(
    p_user_id uuid,
    p_amount integer,
    p_reason text DEFAULT 'admin_grant'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE users SET preshards = preshards + p_amount
    WHERE id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;

    INSERT INTO preshard_ledger (user_id, delta, reason, reference_id)
    VALUES (p_user_id, p_amount, p_reason, NULL);
END;
$$;

-- ============================================================
-- 3. distribute_shards: SECURITY DEFINER RPC for admin CLI
--    Idempotent: skips if preshards_distributed = true.
--    Implements spec distribution flow with remainder handling.
-- ============================================================
CREATE OR REPLACE FUNCTION distribute_shards(
    p_event_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_event RECORD;
    v_promotor RECORD;
    v_attendee RECORD;
    v_total_invitees INT;
    v_confirmed_attendees INT;
    v_per_user INT;
    v_distributed_total INT;
    v_remainder INT;
    v_extra INT;
    v_return_amount INT;
    v_result jsonb;
BEGIN
    SELECT * INTO v_event FROM events WHERE id = p_event_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Event not found: %', p_event_id;
    END IF;

    IF v_event.preshards_distributed THEN
        RETURN jsonb_build_object('status', 'skipped', 'reason', 'already distributed');
    END IF;

    SELECT COUNT(*) INTO v_total_invitees FROM event_invites WHERE event_id = p_event_id;
    SELECT COUNT(*) INTO v_confirmed_attendees FROM event_attendances WHERE event_id = p_event_id;

    IF v_confirmed_attendees = 0 THEN
        FOR v_promotor IN
            SELECT user_id, preshards_contributed
            FROM event_promotores
            WHERE event_id = p_event_id AND preshards_contributed > 0
        LOOP
            UPDATE users SET preshards = preshards + v_promotor.preshards_contributed
            WHERE id = v_promotor.user_id;
            INSERT INTO preshard_ledger (user_id, delta, reason, reference_id)
            VALUES (v_promotor.user_id, v_promotor.preshards_contributed, 'event_pool_returned', p_event_id);
        END LOOP;
        UPDATE events SET preshards_pool = 0, preshards_distributed = true WHERE id = p_event_id;
        RETURN jsonb_build_object('status', 'completed', 'attendees', 0, 'action', 'full_return');
    END IF;

    v_per_user := floor(v_event.preshards_pool / v_total_invitees);
    IF v_event.preshards_cap_per_user IS NOT NULL AND v_per_user > v_event.preshards_cap_per_user THEN
        v_per_user := v_event.preshards_cap_per_user;
    END IF;

    v_distributed_total := v_per_user * v_confirmed_attendees;
    IF v_distributed_total > v_event.preshards_pool THEN
        v_distributed_total := v_event.preshards_pool;
        v_per_user := floor(v_event.preshards_pool / v_confirmed_attendees);
    END IF;

    FOR v_attendee IN SELECT ea.user_id FROM event_attendances ea WHERE ea.event_id = p_event_id LOOP
        UPDATE users SET personal_shards = personal_shards + v_per_user WHERE id = v_attendee.user_id;
        UPDATE event_attendances SET shards_received = v_per_user WHERE event_id = p_event_id AND user_id = v_attendee.user_id;
        INSERT INTO shard_ledger (user_id, delta, reason, reference_id) VALUES (v_attendee.user_id, v_per_user, 'event_attendance', p_event_id);
    END LOOP;

    v_remainder := v_event.preshards_pool - v_distributed_total;

    IF v_remainder > 0 THEN
        IF v_event.preshards_remainder_action = 'redistribute' THEN
            v_extra := floor(v_remainder / v_confirmed_attendees);
            FOR v_attendee IN SELECT ea.user_id FROM event_attendances ea WHERE ea.event_id = p_event_id LOOP
                UPDATE users SET personal_shards = personal_shards + v_extra WHERE id = v_attendee.user_id;
                UPDATE event_attendances SET shards_received = shards_received + v_extra WHERE event_id = p_event_id AND user_id = v_attendee.user_id;
            END LOOP;
        ELSE
            FOR v_promotor IN SELECT user_id, preshards_contributed FROM event_promotores WHERE event_id = p_event_id AND preshards_contributed > 0 LOOP
                v_return_amount := floor(v_remainder * v_promotor.preshards_contributed / NULLIF(v_event.preshards_pool, 0));
                IF v_return_amount > 0 THEN
                    UPDATE users SET preshards = preshards + v_return_amount WHERE id = v_promotor.user_id;
                    INSERT INTO preshard_ledger (user_id, delta, reason, reference_id) VALUES (v_promotor.user_id, v_return_amount, 'event_pool_returned', p_event_id);
                END IF;
            END LOOP;
        END IF;
    END IF;

    FOR v_promotor IN SELECT user_id, preshards_contributed FROM event_promotores WHERE event_id = p_event_id AND preshards_contributed > 0 LOOP
        INSERT INTO preshard_ledger (user_id, delta, reason, reference_id) VALUES (v_promotor.user_id, -v_promotor.preshards_contributed, 'event_pool_consumed', p_event_id);
    END LOOP;

    UPDATE events SET preshards_pool = 0, preshards_distributed = true WHERE id = p_event_id;

    v_result := jsonb_build_object('status', 'completed', 'attendees', v_confirmed_attendees, 'per_user', v_per_user, 'remainder_action', v_event.preshards_remainder_action, 'remainder', v_remainder);
    RETURN v_result;
END;
$$;

-- ============================================================
-- 4. recalculate_ranks: SECURITY DEFINER RPC for admin CLI
--    Manual rank recalc for a tier (or all tiers if null).
-- ============================================================
CREATE OR REPLACE FUNCTION recalculate_ranks(
    p_tier text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_tiers text[] := ARRAY['micro', 'small', 'medium', 'large'];
    v_tier text;
    v_group RECORD;
    v_rank INT;
    v_total INT;
    v_percentile NUMERIC;
    v_bracket rank_bracket;
BEGIN
    IF p_tier IS NOT NULL THEN v_tiers := ARRAY[p_tier]; END IF;

    FOREACH v_tier IN ARRAY v_tiers LOOP
        SELECT COUNT(*) INTO v_total FROM groups WHERE size_tier = v_tier::size_tier;
        IF v_total = 0 THEN CONTINUE; END IF;

        v_rank := 0;
        FOR v_group IN SELECT id, group_shards FROM groups WHERE size_tier = v_tier::size_tier ORDER BY group_shards DESC LOOP
            v_rank := v_rank + 1;
            v_percentile := ((v_total - v_rank)::NUMERIC / GREATEST(v_total, 1)) * 100;

            v_bracket := CASE
                WHEN v_percentile >= 90 THEN 'b90_100'::rank_bracket
                WHEN v_percentile >= 80 THEN 'b80_90'::rank_bracket
                WHEN v_percentile >= 60 THEN 'b60_80'::rank_bracket
                WHEN v_percentile >= 40 THEN 'b40_60'::rank_bracket
                WHEN v_percentile >= 20 THEN 'b20_40'::rank_bracket
                ELSE 'b0_20'::rank_bracket
            END;

            UPDATE groups SET rank_bracket = v_bracket WHERE id = v_group.id;

            INSERT INTO group_rank_snapshots (group_id, size_tier, rank_bracket, rank_position, score, member_count)
            SELECT v_group.id, v_tier::size_tier, v_bracket, v_rank, v_group.group_shards,
                   COUNT(gm.id) FILTER (WHERE gm.status = 'active')
            FROM group_members gm WHERE gm.group_id = v_group.id;
        END LOOP;
    END LOOP;

    DELETE FROM group_rank_snapshots WHERE calculated_at < now() - INTERVAL '30 days';
END;
$$;

-- ============================================================
-- 5. Tighten users_search: replace all-columns RLS with restricted view
--    The old users_search policy let any authenticated user read ALL
--    columns of any non-deleted user. Now search goes through a
--    security barrier view that only exposes id, username, avatar_url.
-- ============================================================
DROP POLICY IF EXISTS users_search ON users;

CREATE OR REPLACE VIEW user_search_view
WITH (security_barrier)
AS
SELECT id, username, avatar_url
FROM users
WHERE deleted_at IS NULL;

GRANT SELECT ON user_search_view TO authenticated, anon;
