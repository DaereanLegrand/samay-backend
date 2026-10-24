-- ============================================================================
-- 232_storage_policy_reassert — re-assert the SEC-030 event upload predicates
--
-- Problem: the 950_storage privileged baseline runs after the numbered
-- migrations and recreates storage_objects_insert_own/update_own without the
-- event-path checks added by 231_wave1_hardening/06_storage_privileged.sql.
-- A fresh stack therefore loses SEC-030 enforcement (pgTAP 1079-1080 fail).
--
-- This migration runs after 950_storage and restores the exact 231 predicates.
-- PRIVILEGED TIER (filename marker): storage.objects is owned by the storage
-- service role, so this must run as supabase_admin.
--
-- Forward-fix only: never relax these predicates or allow text/html or SVG.
-- ============================================================================

DROP POLICY IF EXISTS storage_objects_insert_own ON storage.objects;
CREATE POLICY storage_objects_insert_own
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id IN ('avatars', 'groups', 'events')
        AND owner_id = auth.jwt() ->> 'sub'
        AND (
            bucket_id <> 'avatars'
            OR (storage.foldername(name))[1] = auth.jwt() ->> 'sub'
        )
        AND (
            bucket_id <> 'events'
            OR EXISTS (
                SELECT 1
                  FROM public.events e
                 WHERE e.id::text = (storage.foldername(storage.objects.name))[1]
                   AND e.status IN ('upcoming', 'live')
                   AND (
                       EXISTS (
                           SELECT 1 FROM public.event_hosts h
                            WHERE h.event_id = e.id
                              AND h.user_id = auth.uid()
                       )
                       OR EXISTS (
                           SELECT 1 FROM public.event_invites i
                            WHERE i.event_id = e.id
                              AND i.user_id = auth.uid()
                              AND i.status IN ('accepted', 'attended')
                       )
                       OR EXISTS (
                           SELECT 1 FROM public.event_attendances a
                            WHERE a.event_id = e.id
                              AND a.user_id = auth.uid()
                       )
                   )
            )
        )
    );

DROP POLICY IF EXISTS storage_objects_update_own ON storage.objects;
CREATE POLICY storage_objects_update_own
    ON storage.objects FOR UPDATE TO authenticated
    USING (
        bucket_id IN ('avatars', 'groups', 'events', 'minigame_images')
        AND owner_id = auth.jwt() ->> 'sub'
    )
    WITH CHECK (
        bucket_id IN ('avatars', 'groups', 'events', 'minigame_images')
        AND owner_id = auth.jwt() ->> 'sub'
        AND (
            bucket_id <> 'events'
            OR EXISTS (
                SELECT 1
                  FROM public.events e
                 WHERE e.id::text = (storage.foldername(storage.objects.name))[1]
                   AND e.status IN ('upcoming', 'live')
                   AND (
                       EXISTS (
                           SELECT 1 FROM public.event_hosts h
                            WHERE h.event_id = e.id
                              AND h.user_id = auth.uid()
                       )
                       OR EXISTS (
                           SELECT 1 FROM public.event_invites i
                            WHERE i.event_id = e.id
                              AND i.user_id = auth.uid()
                              AND i.status IN ('accepted', 'attended')
                       )
                       OR EXISTS (
                           SELECT 1 FROM public.event_attendances a
                            WHERE a.event_id = e.id
                              AND a.user_id = auth.uid()
                       )
                   )
            )
        )
    );
