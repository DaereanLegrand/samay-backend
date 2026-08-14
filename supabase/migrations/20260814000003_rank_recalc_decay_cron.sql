-- Samay — Rank recalculation: boost decay + bracket-change notifications +
-- daily cron (docs-to-code audit, 2026-08-13)
--
-- Closes the GRCK gaps found by the audit (cross-references GRCK row):
--   1. Step 1 (decay) was missing: group_shards now recomputes as the SUM
--      of NON-expired contributions before ranking (expired boosts drop out
--      of the rank score; the contribution audit trail is preserved).
--   2. Step 5 (notifications) was missing: members are notified (in-app
--      `notifications` row) when their group's rank_bracket changes.
--   3. No cron schedule existed → leaderboards stayed empty/stale in
--      production. `ranks-recalculate` now runs daily honoring the
--      `ranks.update_cron` app_config key (seed default '59 23 * * *').
--   4. Hardening: the function now carries SET search_path = '' (I-31
--      pattern — it previously lacked it).
--
-- Also introduces the shared `insert_notification` helper (SECURITY
-- DEFINER, guarded): every notification producer (this migration's rank
-- recalc + the NTRG triggers, migration 20260814000004) writes through it.
-- Only service_role / postgres (admin CLI, cron, triggers) may notify OTHER
-- users; an authenticated caller may only notify themselves (spam guard).
--
-- References: docs/specs/steps/phase-11-gamification-minigames/
-- GRCK-rank-calculation-edge-function.md, docs/specs/steps/
-- phase-09-notifications-push/NTRG-notification-triggers-routing.md,
-- docs/specs/product/samay_mvp_spec.md#gamification--ranks.

-- ============================================================
-- 1. insert_notification helper — guarded SECURITY DEFINER writer
-- ============================================================
CREATE OR REPLACE FUNCTION public.insert_notification(
    p_user_id uuid,
    p_type text,
    p_title text,
    p_body text,
    p_data jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    -- Spam guard: non-privileged callers may only notify themselves.
    IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin')
       AND auth.uid() IS DISTINCT FROM p_user_id THEN
        RAISE EXCEPTION 'Not authorized';
    END IF;

    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (p_user_id, p_type, p_title, p_body, p_data);
END;
$$;

REVOKE ALL ON FUNCTION public.insert_notification(uuid, text, text, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.insert_notification(uuid, text, text, text, jsonb) FROM anon, authenticated;

-- ============================================================
-- 2. recalculate_ranks — decay + brackets + snapshots + notifications
-- ============================================================
CREATE OR REPLACE FUNCTION public.recalculate_ranks(p_tier text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_tiers text[] := ARRAY['micro', 'small', 'medium', 'large'];
    v_tier text;
    v_group RECORD;
    v_old_bracket public.rank_bracket;
    v_rank INT;
    v_total INT;
    v_percentile NUMERIC;
    v_bracket public.rank_bracket;
    v_decayed_shards integer;
    v_member RECORD;
BEGIN
    IF p_tier IS NOT NULL THEN v_tiers := ARRAY[p_tier]; END IF;

    FOREACH v_tier IN ARRAY v_tiers LOOP
        -- GRCK Step 1: decay expired boosts. group_shards = SUM of
        -- non-expired contributions (expires_at is NOT NULL by schema);
        -- expired donations drop out of the rank score but stay in
        -- group_shard_contributions for the historical audit.
        FOR v_group IN
            SELECT id FROM public.groups
            WHERE size_tier = v_tier::public.size_tier
        LOOP
            SELECT COALESCE(SUM(shards_contributed), 0)::integer
            INTO v_decayed_shards
            FROM public.group_shard_contributions
            WHERE group_id = v_group.id
              AND expires_at > now();

            UPDATE public.groups SET group_shards = v_decayed_shards
            WHERE id = v_group.id;
        END LOOP;

        SELECT COUNT(*) INTO v_total
        FROM public.groups WHERE size_tier = v_tier::public.size_tier;
        IF v_total = 0 THEN CONTINUE; END IF;

        -- GRCK Steps 2-4: percentile brackets + snapshots (existing logic,
        -- now over the decayed scores).
        v_rank := 0;
        FOR v_group IN
            SELECT id, group_shards FROM public.groups
            WHERE size_tier = v_tier::public.size_tier
            ORDER BY group_shards DESC
        LOOP
            v_rank := v_rank + 1;
            v_percentile := ((v_total - v_rank)::NUMERIC / GREATEST(v_total, 1)) * 100;

            v_bracket := CASE
                WHEN v_percentile >= 90 THEN 'b90_100'::public.rank_bracket
                WHEN v_percentile >= 80 THEN 'b80_90'::public.rank_bracket
                WHEN v_percentile >= 60 THEN 'b60_80'::public.rank_bracket
                WHEN v_percentile >= 40 THEN 'b40_60'::public.rank_bracket
                WHEN v_percentile >= 20 THEN 'b20_40'::public.rank_bracket
                ELSE 'b0_20'::public.rank_bracket
            END;

            SELECT rank_bracket INTO v_old_bracket
            FROM public.groups WHERE id = v_group.id;

            UPDATE public.groups SET rank_bracket = v_bracket WHERE id = v_group.id;

            -- GRCK Step 5: notify active members when the bracket changed.
            IF v_old_bracket IS DISTINCT FROM v_bracket THEN
                FOR v_member IN
                    SELECT user_id FROM public.group_members
                    WHERE group_id = v_group.id AND status = 'active'
                LOOP
                    PERFORM public.insert_notification(
                        v_member.user_id,
                        'rank_bracket',
                        'Nuevo rango de grupo',
                        'Tu grupo cambió de rango a ' || v_bracket::text,
                        jsonb_build_object('groupId', v_group.id, 'rankBracket', v_bracket)
                    );
                END LOOP;
            END IF;

            INSERT INTO public.group_rank_snapshots (
                group_id, size_tier, rank_bracket, rank_position, score, member_count
            )
            SELECT v_group.id, v_tier::public.size_tier, v_bracket, v_rank,
                   v_group.group_shards,
                   COUNT(gm.id) FILTER (WHERE gm.status = 'active')
            FROM public.group_members gm
            WHERE gm.group_id = v_group.id;
        END LOOP;
    END LOOP;

    DELETE FROM public.group_rank_snapshots
    WHERE calculated_at < now() - INTERVAL '30 days';
END;
$$;

REVOKE EXECUTE ON FUNCTION public.recalculate_ranks(text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recalculate_ranks(text) TO service_role;

-- ============================================================
-- 3. Daily cron — honors app_config `ranks.update_cron`
-- ============================================================
-- Idempotent (unschedule-then-schedule): re-running the migration or the
-- stack reset must not accumulate duplicate jobs.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'ranks-recalculate';

SELECT cron.schedule(
    'ranks-recalculate',
    COALESCE(
        (SELECT value FROM public.app_config WHERE key = 'ranks.update_cron'),
        '59 23 * * *'
    ),
    $$SELECT public.recalculate_ranks(NULL);$$
);
