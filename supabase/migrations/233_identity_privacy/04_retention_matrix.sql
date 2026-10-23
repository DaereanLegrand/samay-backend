-- ============================================================================
-- 233_identity_privacy / 04_retention_matrix.sql — Q1 published matrix
--
-- One machine-readable matrix drives the public copy, the export document and
-- the expiry job. Values are the owner decision from Q1:
--   * ledgers/attendance: pseudonymized, 5 years;
--   * report evidence: restricted, 2 years (CSAM/legal hold per law);
--   * infra logs/backups: 90 days (outside this schema).
--
-- Rollback: drop retention_matrix/purge_expired_retention and the two cron
-- jobs. Retained rows are not removed by a rollback.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.retention_matrix (
    data_class text NOT NULL,
    action text NOT NULL,
    retention_period text NOT NULL,
    legal_basis text,
    notes text,
    CONSTRAINT retention_matrix_pkey PRIMARY KEY (data_class),
    CONSTRAINT retention_matrix_action_check
        CHECK (action IN ('hard_delete', 'pseudonymize', 'retain_restricted'))
);

ALTER TABLE public.retention_matrix ENABLE ROW LEVEL SECURITY;
ALTER TABLE ONLY public.retention_matrix FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.retention_matrix FROM anon;
REVOKE ALL ON TABLE public.retention_matrix FROM authenticated;
GRANT SELECT ON TABLE public.retention_matrix TO service_role;

INSERT INTO public.retention_matrix (data_class, action, retention_period, legal_basis, notes)
VALUES
    ('account', 'hard_delete', 'immediate', 'Ley N° 29733', 'Email, credentials, profile row and auth.users row deleted in the same purge.'),
    ('profile', 'hard_delete', 'immediate', 'Ley N° 29733', 'Username, bio, avatar and privacy preferences.'),
    ('media', 'hard_delete', 'immediate', 'Ley N° 29733', 'Storage metadata deleted immediately; object bytes are queued in pending_object_deletions and drained by the storage worker.'),
    ('messages', 'hard_delete', 'immediate', 'Ley N° 29733', 'Messages authored by the user. Received messages remain with the other chat participants and lose the user id reference.'),
    ('friend_graph', 'hard_delete', 'immediate', 'Ley N° 29733', 'Friendships and pending requests.'),
    ('membership', 'hard_delete', 'immediate', 'Ley N° 29733', 'Group memberships, event hosts, invites and attendance identity link (the attendance fact itself is pseudonymized below).'),
    ('device_tokens', 'hard_delete', 'immediate', 'Ley N° 29733', 'Push registration tokens.'),
    ('ledgers', 'pseudonymize', '5 years', 'Ley N° 29733 / accounting integrity', 'shard_ledger, preshard_ledger and group_shard_contributions keep their amounts/reasons with user_id = NULL, pseudonymized_at and retention_until.'),
    ('attendance', 'pseudonymize', '5 years', 'Ley N° 29733 / event integrity', 'event_attendances keeps event/time/shards with user_id = NULL.'),
    ('report_evidence', 'retain_restricted', '2 years (CSAM/legal hold per law)', 'Ley N° 29733 / child protection', 'reports, moderation_evidence and message_reports survive account deletion with a non-reversible reporter pseudonym and restricted staff-only access.'),
    ('subscriptions_purchases', 'hard_delete', 'immediate + processor policy', 'Ley N° 29733 / tax', 'Account row deleted immediately; Apple/Google/RevenueCat retention is governed by the store processor.'),
    ('server_logs_backups', 'hard_delete', '90 days', 'Ley N° 29733', 'Rotated/overwritten on the infrastructure side; not exported.')
ON CONFLICT (data_class) DO UPDATE
    SET action = EXCLUDED.action,
        retention_period = EXCLUDED.retention_period,
        legal_basis = EXCLUDED.legal_basis,
        notes = EXCLUDED.notes;

COMMENT ON TABLE public.retention_matrix IS
    'Q1 data-class deletion/retention matrix. Published in samay/privacy.html and samay/delete-account.html; exported inside export_my_data() v2.';

COMMENT ON COLUMN public.shard_ledger.pseudonymized_at IS
    'Q1: set when the account is purged. Amounts/reasons stay for 5 years; user_id is NULL.';
COMMENT ON COLUMN public.shard_ledger.retention_until IS
    'Q1: pseudonymized ledger expiration (5 years). purge_expired_retention() removes it.';
COMMENT ON COLUMN public.preshard_ledger.pseudonymized_at IS
    'Q1: set when the account is purged. user_id is NULL; retained 5 years.';
COMMENT ON COLUMN public.preshard_ledger.retention_until IS
    'Q1: pseudonymized ledger expiration (5 years).';
COMMENT ON COLUMN public.group_shard_contributions.pseudonymized_at IS
    'Q1: set when the account is purged. user_id is NULL; retained 5 years.';
COMMENT ON COLUMN public.group_shard_contributions.retention_until IS
    'Q1: pseudonymized contribution expiration (5 years).';
COMMENT ON COLUMN public.message_reports.retention_until IS
    'Q1: restricted report evidence retention (2 years, CSAM per law).';

CREATE OR REPLACE FUNCTION public.purge_expired_retention() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_ledger integer := 0;
    v_preshard integer := 0;
    v_contrib integer := 0;
    v_attendance integer := 0;
    v_evidence integer := 0;
    v_reports integer := 0;
BEGIN
    DELETE FROM public.shard_ledger
     WHERE user_id IS NULL
       AND retention_until IS NOT NULL
       AND retention_until < now();
    GET DIAGNOSTICS v_ledger = ROW_COUNT;

    DELETE FROM public.preshard_ledger
     WHERE user_id IS NULL
       AND retention_until IS NOT NULL
       AND retention_until < now();
    GET DIAGNOSTICS v_preshard = ROW_COUNT;

    DELETE FROM public.group_shard_contributions
     WHERE user_id IS NULL
       AND retention_until IS NOT NULL
       AND retention_until < now();
    GET DIAGNOSTICS v_contrib = ROW_COUNT;

    DELETE FROM public.event_attendances
     WHERE user_id IS NULL
       AND retention_until IS NOT NULL
       AND retention_until < now();
    GET DIAGNOSTICS v_attendance = ROW_COUNT;

    -- Report evidence: never purge an open report, and never purge a row
    -- flagged as CSAM/legal hold. Otherwise the fixed 2-year clock applies.
    DELETE FROM public.moderation_evidence
     WHERE retention_until IS NOT NULL
       AND retention_until < now()
       AND retention_exempt = false;
    GET DIAGNOSTICS v_evidence = ROW_COUNT;

    DELETE FROM public.reports r
     WHERE r.retention_until < now()
       AND r.status <> 'pending'::public.report_status
       AND NOT EXISTS (
            SELECT 1 FROM public.moderation_evidence me
             WHERE me.report_id = r.id
               AND (me.retention_exempt = true
                    OR me.retention_until IS NULL
                    OR me.retention_until >= now())
       );
    GET DIAGNOSTICS v_reports = ROW_COUNT;

    RETURN jsonb_build_object(
        'shard_ledger', v_ledger,
        'preshard_ledger', v_preshard,
        'group_shard_contributions', v_contrib,
        'event_attendances', v_attendance,
        'moderation_evidence', v_evidence,
        'reports', v_reports
    );
END;
$$;
REVOKE ALL ON FUNCTION public.purge_expired_retention() FROM PUBLIC;
GRANT ALL ON FUNCTION public.purge_expired_retention() TO service_role;

DO $job$ BEGIN
  PERFORM cron.schedule('retention-expiry', '15 4 * * *',
    $cmd$SELECT public.purge_expired_retention();$cmd$);
END $job$;

DO $job$ BEGIN
  PERFORM cron.schedule('auth-cleanup-retry', '30 3 * * *',
    $cmd$SELECT public.retry_auth_cleanup();$cmd$);
END $job$;

COMMIT;
