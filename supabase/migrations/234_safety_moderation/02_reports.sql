-- ============================================================================
-- 234_safety_moderation / 02_reports.sql
--
-- Q6 (2026-10-23) report pipeline foundations:
--   * new report targets: minigame answers/images, avatars, group covers and
--     event descriptions (plus the existing message/photo/user/event);
--   * severity categories with a numeric priority (CSAM, credible threat and
--     NCII are immediate: priority 0/1/2, internal 24h/72h SLA);
--   * report workflow columns (reviewed/actioned, assignment, outcome) and the
--     priority-ordered processing queue;
--   * report-time evidence snapshots with a 2-year retention clock and a legal
--     hold flag, detached from reporter erasure;
--   * appeals table (owner-staffed; ban appeals + reporter outcomes).
--
-- Evidence retention: standard 2 years from report time; `legal_hold = true`
-- suspends automatic purge. CSAM/legal-hold retention follows the applicable
-- law and is the owner's call — nothing deletes held evidence automatically.
-- There is no implicit evidence purge job in this migration; a future job may
-- delete `retention_until < now() AND NOT legal_hold`.
--
-- Rollback:
--   * keep the added enum values (PostgreSQL cannot drop enum values safely);
--   * drop the new columns/tables/triggers by name (they are additive and the
--     legacy Go/SQL paths tolerate their absence).
-- Forward-fix:
--   * add targets/categories, never re-map an existing category to a lower
--     priority.
--
-- Backfill:
--   * existing reports get category='other' (priority 100) and no reviewer;
--   * existing moderation_evidence rows get retention_until = created_at + 2y.
-- Locking: both backfills are single UPDATEs (maintenance-window note).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Categories + priority.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'report_category') THEN
        CREATE TYPE public.report_category AS ENUM (
            'csam',
            'credible_threat',
            'ncii',
            'harassment',
            'hate',
            'spam',
            'impersonation',
            'other'
        );
    END IF;
END
$$;

ALTER TYPE public.report_target_type ADD VALUE IF NOT EXISTS 'minigame_answer';
ALTER TYPE public.report_target_type ADD VALUE IF NOT EXISTS 'minigame_image';
ALTER TYPE public.report_target_type ADD VALUE IF NOT EXISTS 'avatar';
ALTER TYPE public.report_target_type ADD VALUE IF NOT EXISTS 'group_cover';
ALTER TYPE public.report_target_type ADD VALUE IF NOT EXISTS 'event_description';

CREATE OR REPLACE FUNCTION public.report_category_priority(p_category public.report_category)
RETURNS smallint
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
    SELECT CASE p_category
        WHEN 'csam' THEN 0
        WHEN 'credible_threat' THEN 1
        WHEN 'ncii' THEN 2
        WHEN 'harassment' THEN 20
        WHEN 'hate' THEN 25
        WHEN 'impersonation' THEN 30
        WHEN 'spam' THEN 60
        ELSE 100
    END::smallint;
$$;

-- Legacy `reports.reason` strings (226/231 clients) map onto the new enum so
-- old clients keep working without a release.
CREATE OR REPLACE FUNCTION public.report_category_from_text(p_reason text)
RETURNS public.report_category
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
    SELECT CASE lower(btrim(coalesce(p_reason, '')))
        WHEN 'csam' THEN 'csam'::public.report_category
        WHEN 'child_sexual_abuse' THEN 'csam'::public.report_category
        WHEN 'credible_threat' THEN 'credible_threat'::public.report_category
        WHEN 'threat' THEN 'credible_threat'::public.report_category
        WHEN 'ncii' THEN 'ncii'::public.report_category
        WHEN 'non_consensual_intimate' THEN 'ncii'::public.report_category
        WHEN 'harassment' THEN 'harassment'::public.report_category
        WHEN 'abuse' THEN 'harassment'::public.report_category
        WHEN 'hate' THEN 'hate'::public.report_category
        WHEN 'hate_speech' THEN 'hate'::public.report_category
        WHEN 'spam' THEN 'spam'::public.report_category
        WHEN 'impersonation' THEN 'impersonation'::public.report_category
        ELSE 'other'::public.report_category
    END;
$$;

REVOKE ALL ON FUNCTION public.report_category_priority(public.report_category) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.report_category_from_text(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.report_category_priority(public.report_category) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.report_category_from_text(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. reports workflow columns.
-- ---------------------------------------------------------------------------
ALTER TABLE public.reports
    ADD COLUMN IF NOT EXISTS category public.report_category NOT NULL DEFAULT 'other',
    ADD COLUMN IF NOT EXISTS priority smallint NOT NULL DEFAULT 100,
    ADD COLUMN IF NOT EXISTS reviewed_at timestamp with time zone,
    ADD COLUMN IF NOT EXISTS reviewed_by uuid,
    ADD COLUMN IF NOT EXISTS actioned_at timestamp with time zone,
    ADD COLUMN IF NOT EXISTS actioned_by uuid,
    ADD COLUMN IF NOT EXISTS resolution_note text,
    ADD COLUMN IF NOT EXISTS reporter_outcome text,
    ADD COLUMN IF NOT EXISTS reporter_notified_at timestamp with time zone,
    ADD COLUMN IF NOT EXISTS claimed_by uuid,
    ADD COLUMN IF NOT EXISTS claimed_at timestamp with time zone,
    ADD COLUMN IF NOT EXISTS updated_at timestamp with time zone DEFAULT now() NOT NULL;

-- Priority is derived from the category; a client cannot lower it.
CREATE OR REPLACE FUNCTION public.set_report_priority()
RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    NEW.category := COALESCE(NEW.category, public.report_category_from_text(NEW.reason));
    NEW.priority := public.report_category_priority(NEW.category);
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS reports_set_priority_trigger ON public.reports;
CREATE TRIGGER reports_set_priority_trigger
    BEFORE INSERT OR UPDATE OF category ON public.reports
    FOR EACH ROW
    EXECUTE FUNCTION public.set_report_priority();

REVOKE ALL ON FUNCTION public.set_report_priority() FROM PUBLIC;

UPDATE public.reports
   SET category = COALESCE(NULLIF(category, 'other'), public.report_category_from_text(reason)),
       priority = public.report_category_priority(
           COALESCE(NULLIF(category, 'other'), public.report_category_from_text(reason)));

-- Reporter erasure must not delete the report (or its evidence). The reporter
-- reference becomes NULL; the queue row and evidence stay for moderation and
-- legal retention.
ALTER TABLE public.reports ALTER COLUMN reporter_id DROP NOT NULL;
ALTER TABLE public.reports DROP CONSTRAINT IF EXISTS reports_reporter_id_fkey;
ALTER TABLE public.reports
    ADD CONSTRAINT reports_reporter_id_fkey
    FOREIGN KEY (reporter_id) REFERENCES public.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_reports_queue
    ON public.reports USING btree (priority, created_at)
    WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_reports_category
    ON public.reports USING btree (category);
CREATE INDEX IF NOT EXISTS idx_reports_reporter
    ON public.reports USING btree (reporter_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- 3. Evidence: snapshot at report time, retention, legal hold.
-- ---------------------------------------------------------------------------
ALTER TABLE public.moderation_evidence
    ADD COLUMN IF NOT EXISTS reporter_id uuid,
    ADD COLUMN IF NOT EXISTS retention_until timestamp with time zone
        DEFAULT (now() + interval '2 years') NOT NULL,
    ADD COLUMN IF NOT EXISTS legal_hold boolean DEFAULT false NOT NULL,
    ADD COLUMN IF NOT EXISTS hold_reason text,
    ADD COLUMN IF NOT EXISTS processing_state text DEFAULT 'captured' NOT NULL,
    ADD COLUMN IF NOT EXISTS captured_at timestamp with time zone DEFAULT now() NOT NULL;

ALTER TABLE public.moderation_evidence
    DROP CONSTRAINT IF EXISTS moderation_evidence_report_id_fkey;
ALTER TABLE public.moderation_evidence
    ADD CONSTRAINT moderation_evidence_report_id_fkey
    FOREIGN KEY (report_id) REFERENCES public.reports(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_moderation_evidence_retention
    ON public.moderation_evidence USING btree (retention_until)
    WHERE NOT legal_hold;
CREATE INDEX IF NOT EXISTS idx_moderation_evidence_report
    ON public.moderation_evidence USING btree (report_id);
CREATE INDEX IF NOT EXISTS idx_moderation_evidence_reporter
    ON public.moderation_evidence USING btree (reporter_id);

UPDATE public.moderation_evidence
   SET retention_until = created_at + interval '2 years'
 WHERE retention_until IS NULL;

COMMENT ON TABLE public.moderation_evidence IS
    'Report-time immutable snapshots. Retained 2 years by default; legal_hold suspends deletion. Service-role only.';

-- ---------------------------------------------------------------------------
-- 4. Appeals. A banned user can submit while `banned_at` is set: the RPC is
-- SECURITY DEFINER and this table deliberately has no `active_users_only`
-- restrictive policy. RLS still hides other users' appeals.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.appeals (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id uuid REFERENCES public.reports(id) ON DELETE SET NULL,
    appellant_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
    message text NOT NULL,
    status text NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'reviewing', 'upheld', 'overturned', 'closed')),
    is_ban_appeal boolean NOT NULL DEFAULT false,
    decision_note text,
    decided_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    decided_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT appeals_message_length CHECK (char_length(message) BETWEEN 10 AND 4000)
);

ALTER TABLE public.appeals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.appeals FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS appeals_read_own ON public.appeals;
CREATE POLICY appeals_read_own ON public.appeals
    FOR SELECT USING (appellant_id = auth.uid());

REVOKE ALL ON TABLE public.appeals FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.appeals FROM authenticated;
GRANT SELECT ON TABLE public.appeals TO authenticated;
GRANT ALL ON TABLE public.appeals TO service_role;

CREATE INDEX IF NOT EXISTS idx_appeals_open
    ON public.appeals USING btree (created_at)
    WHERE status IN ('open', 'reviewing');
CREATE INDEX IF NOT EXISTS idx_appeals_appellant
    ON public.appeals USING btree (appellant_id, created_at DESC);

COMMENT ON TABLE public.appeals IS
    'Q6 appeals: owner-staffed. Ban appeals accepted while banned (RPC is SECURITY DEFINER); decisions audit the real admin actor.';
