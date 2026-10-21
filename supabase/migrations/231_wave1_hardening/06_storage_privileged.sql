-- ============================================================================
-- 231_wave1_hardening / 06_storage_privileged.sql — SEC-030
--
-- Per-bucket MIME allow-lists and size limits (no HTML/SVG active content,
-- bounded uploads) plus event-bound upload paths for the private `events`
-- bucket. The events policy requires the first path segment to be an event the
-- caller can access (host/staff, accepted/attended invitee, or confirmed
-- attendee) and the event to be upcoming/live. Own-row UPDATE re-checks the
-- same path so an owner cannot relocate a valid object after upload.
--
-- PRIVILEGED TIER (filename marker): applied as `supabase_admin` because
-- storage.objects is owned by the storage service role.
--
-- Rollback: restore NULL limits/MIME lists and the 950_storage
-- storage_objects_insert_own/update_own bodies. Forward-fix: only tighten the
-- lists/predicates; never allow text/html or image/svg+xml.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Bucket limits.
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
    ('avatars', 'avatars', true, 5242880,
     ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]),
    ('groups', 'groups', true, 5242880,
     ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]),
    ('events', 'events', false, 10485760,
     ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]),
    ('minigame_images', 'minigame_images', false, 10485760,
     ARRAY['application/octet-stream']::text[])
ON CONFLICT (id) DO UPDATE
    SET file_size_limit = EXCLUDED.file_size_limit,
        allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ---------------------------------------------------------------------------
-- 2. Upload path binding.
-- ---------------------------------------------------------------------------
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
