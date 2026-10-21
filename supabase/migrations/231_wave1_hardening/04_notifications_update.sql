-- ============================================================================
-- 231_wave1_hardening / 04_notifications_update.sql — SEC-019
--
-- Notification owners could rewrite title/body/type/data/push_sent_at through
-- the table-level UPDATE grant (spoofed push content). The owner path is now
-- column-scoped to `read`; push_sent_at stays with service_role (the push
-- worker), which already holds table-level ALL.
--
-- Rollback: GRANT UPDATE ON public.notifications TO authenticated; (and anon
-- only if a pre-231 client depended on the unsafe grant — do not restore it).
-- Forward-fix: keep column-level grants; add columns explicitly if needed.
-- ============================================================================

REVOKE UPDATE ON TABLE public.notifications FROM anon;
REVOKE UPDATE ON TABLE public.notifications FROM authenticated;

GRANT UPDATE (read) ON TABLE public.notifications TO authenticated;

-- The owner policy remains the row gate; the column grant is the column gate.
DROP POLICY IF EXISTS notif_update_own ON public.notifications;
CREATE POLICY notif_update_own ON public.notifications
    FOR UPDATE
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid() AND read IS NOT NULL);
