-- Samay — Cron Job Setup
-- Pure SQL cron jobs for event status polling and account cleanup.
-- Edge Function cron jobs (rank calculation, shard distribution, override reconciler)
-- will be created when the corresponding Edge Functions are deployed.

-- 0. Helper: hard-delete expired users
CREATE OR REPLACE FUNCTION hard_delete_expired_users()
RETURNS void AS $$
DECLARE
    expired_user RECORD;
BEGIN
    FOR expired_user IN SELECT id, username FROM users WHERE deleted_at < now() - interval '30 days'
    LOOP
        -- Anonymize ledger entries (preserve for integrity)
        UPDATE shard_ledger SET user_id = NULL WHERE user_id = expired_user.id;
        UPDATE preshard_ledger SET user_id = NULL WHERE user_id = expired_user.id;

        -- Anonymize messages
        UPDATE messages SET sender_id = NULL, content = '[deleted]' WHERE sender_id = expired_user.id;

        -- Remove group memberships
        DELETE FROM group_members WHERE user_id = expired_user.id;

        -- Remove event associations
        DELETE FROM event_promotores WHERE user_id = expired_user.id;
        DELETE FROM event_invites WHERE user_id = expired_user.id;

        -- Delete user (cascade handles remaining)
        DELETE FROM users WHERE id = expired_user.id;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 1. Event status poll (every minute)
-- Transitions: upcoming → live, live → ended
SELECT cron.schedule(
    'events-status-poll',
    '* * * * *',
    $$UPDATE events SET status = 'live' WHERE status = 'upcoming' AND starts_at <= now();$$
);
SELECT cron.schedule(
    'events-end-events',
    '* * * * *',
    $$UPDATE events SET status = 'ended' WHERE status = 'live' AND ends_at <= now();$$
);

-- 2. Account hard delete (daily at 3:00 AM)
SELECT cron.schedule(
    'account-hard-delete',
    '0 3 * * *',
    $$SELECT hard_delete_expired_users();$$
);
