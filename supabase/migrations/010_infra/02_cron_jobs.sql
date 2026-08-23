-- Samay baseline — 010_infra/02_cron_jobs.sql
-- pg_cron schedules (canonical state extracted from cron.job on the live DB).
-- cron.schedule() upserts by job name → idempotent, never interferes with
-- platform init. Commands reference functions created by later domain files;
-- registration is lazy (strings executed by the scheduler at fire time).
DO $job$ BEGIN
  PERFORM cron.schedule('events-status-poll', '* * * * *',
    $cmd$UPDATE events SET status = 'live' WHERE status = 'upcoming' AND starts_at <= now();$cmd$);
END $job$;

DO $job$ BEGIN
  PERFORM cron.schedule('events-end-events', '* * * * *',
    $cmd$UPDATE events SET status = 'ended' WHERE status = 'live' AND ends_at <= now();$cmd$);
END $job$;

DO $job$ BEGIN
  PERFORM cron.schedule('ranks-recalculate', '59 23 * * *',
    $cmd$SELECT public.recalculate_ranks(NULL);$cmd$);
END $job$;

DO $job$ BEGIN
  PERFORM cron.schedule('account-hard-delete', '0 3 * * *',
    $cmd$SELECT hard_delete_expired_users();$cmd$);
END $job$;
