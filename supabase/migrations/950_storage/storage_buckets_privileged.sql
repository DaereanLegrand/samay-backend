-- Samay baseline — 010_infra/storage_buckets_privileged.sql
-- PRIVILEGED TIER (filename marker: *_privileged.sql): applied via
-- `docker exec <db> psql -U supabase_admin` because storage.objects is owned
-- by the storage service role — the plain `postgres` role cannot attach
-- policies to it (this is the exact failure that silently broke fresh inits).
-- Bucket rows are idempotent inserts; policies are DROP/CREATE pairs.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
    ('avatars', 'avatars', true, NULL, NULL),
    ('groups',  'groups',  true, NULL, NULL),
    ('events',  'events',  false, NULL, NULL)
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- 2. storage.objects RLS — enabled (assert) + policies
-- ============================================================
-- storage.objects RLS is enabled by the storage schema itself (tenant
-- migration 0002, present in v1.60.4) — the ALTER below is a defensive no-op
-- so this migration is self-sufficient on any stack that skipped it.
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- 2.1 Public read — avatars + groups (public buckets; anon + authenticated).
--     No events bucket here: event photos are private (signed URLs only).
DROP POLICY IF EXISTS storage_objects_public_read_avatars_groups ON storage.objects;
CREATE POLICY storage_objects_public_read_avatars_groups
    ON storage.objects FOR SELECT
    USING (bucket_id IN ('avatars', 'groups'));

-- 2.2 Events SELECT — authenticated users with event access ONLY.
--     Required for signed-URL issuance (SECURITY NOTE 1: signObjectUrl runs
--     findObject through the caller's RLS session) AND it is the ONLY read
--     path for events objects: anon/direct GET is denied (no public policy).
--     Access predicate = the event_photos row is visible to the caller:
--     public.event_photos is FORCE RLS with eph_read_access (migration
--     20260809000002 §9 — group_id IS NULL OR group member OR invitee OR
--     promotor), and RLS applies inside policy subqueries, so the EXISTS
--     transitively enforces the canonical event-access predicate without
--     duplicating it. Recursion-safe: eph_read_access's chain terminates on
--     column checks / is_group_member (SECURITY DEFINER, RLS-bypassing) and
--     never re-enters storage.objects.
DROP POLICY IF EXISTS storage_objects_events_select_access ON storage.objects;
CREATE POLICY storage_objects_events_select_access
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'events'
        AND EXISTS (
            SELECT 1 FROM public.event_photos ep
            WHERE ep.storage_path = storage.objects.name
        )
    );

-- 2.3 Own-row INSERT — authenticated uploads into the three app buckets.
--     owner_id is written by storage-api from the JWT sub. Avatars add the
--     SECU spec path-prefix rule: the first path segment must be the caller's
--     own user id (MediaService uploadUserAvatar writes <userId>/…).
DROP POLICY IF EXISTS storage_objects_insert_own ON storage.objects;
CREATE POLICY storage_objects_insert_own
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id IN ('avatars', 'groups', 'events')
        AND owner_id = auth.jwt() ->> 'sub'
        AND (bucket_id <> 'avatars'
             OR (storage.foldername(name))[1] = auth.jwt() ->> 'sub')
    );

-- 2.4 Own-row UPDATE — the app does not update objects today (no client
--     replace/upsert path), but SECU-rls-policies.md requires owner-only
--     writes; WITH CHECK re-asserts bucket scope + ownership on the NEW row
--     (a USING-only policy would let an owner rewrite bucket_id/owner_id).
DROP POLICY IF EXISTS storage_objects_update_own ON storage.objects;
CREATE POLICY storage_objects_update_own
    ON storage.objects FOR UPDATE TO authenticated
    USING (
        bucket_id IN ('avatars', 'groups', 'events')
        AND owner_id = auth.jwt() ->> 'sub'
    )
    WITH CHECK (
        bucket_id IN ('avatars', 'groups', 'events')
        AND owner_id = auth.jwt() ->> 'sub'
    );

-- 2.5 Own-row DELETE — owner-only (admin moderation runs as service_role,
--     which has BYPASSRLS and is unaffected).
DROP POLICY IF EXISTS storage_objects_delete_own ON storage.objects;
CREATE POLICY storage_objects_delete_own
    ON storage.objects FOR DELETE TO authenticated
    USING (
        bucket_id IN ('avatars', 'groups', 'events')
        AND owner_id = auth.jwt() ->> 'sub'
    );
