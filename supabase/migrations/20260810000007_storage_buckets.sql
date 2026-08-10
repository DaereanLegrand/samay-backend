-- Samay — Storage buckets + storage.objects RLS (agent M-08)
-- Migration 24 of 24.
--
-- Closes the S-09/M-track bucket-creation gap flagged by I-36 ("avatars storage
-- bucket missing from all migrations"), I-59 ("no storage.buckets migration
-- anywhere — events/groups/avatars are provisioned out-of-band; event_photos
-- INSERT + uploadBinary fail with 404/PGRST until the bucket exists") and
-- TODO.md:893-894. The storage SCHEMA (storage.buckets/storage.objects) is
-- created by the storage-api migrations baked into the supabase/postgres image
-- (supabase/storage migrations/tenant 0002/0007/0008/0013/0018 — all present in
-- v1.60.4, the pinned storage-api tag per SELFHOSTING.md §2.2); this migration
-- adds the DATA (bucket rows) and the storage.objects RLS policies the app's
-- access model requires (SECU-rls-policies.md §Storage Bucket Policies).
--
-- ============================================================
-- SECURITY NOTES — signed-URL issuance + uploadBinary paths
-- ============================================================
-- Verified against storage-api v1.60.4 source (supabase/storage @ v1.60.4):
--
-- 1. SIGNED-URL ISSUANCE (client POST /object/sign/:bucket/* →
--    routes/object/getSignedURL.ts → storage/object.ts signObjectUrl):
--    signObjectUrl FIRST runs `await this.findObject(objectName)` through the
--    CALLER's RLS-scoped DB session — NOT asSuperUser(). Signing therefore
--    REQUIRES a storage.objects SELECT policy that matches the caller's access
--    (a zero-policy events bucket makes createSignedUrl fail with "object not
--    found" even for legitimate users). The mission sketch claimed signing
--    bypasses RLS (service-role) — that claim is FALSE for issuance and is
--    corrected here: the events SELECT policy below (storage_objects_
--    events_select_access) is the minimal non-public SELECT that keeps the
--    app's createSignedUrl flow working while denying everyone else.
-- 2. SIGNED-URL RETRIEVAL (client GET /object/sign/:bucket/* →
--    routes/object/getSignedObject.ts): runs WITHOUT JWT auth — the signed
--    token IS the authorization (verifyJWT + url===path check), and the object
--    read goes through `request.storage.asSuperUser()` (BYBASSRLS). So the
--    RLS absence for anon users on events objects blocks only DIRECT
--    SELECT/list/download; signed-URL consumption is unaffected by RLS.
-- 3. uploadBinary (client POST /object/:bucket/* → routes/object/
--    createObject.ts): the pre-check storage.can_insert_object (tenant
--    migration 0015) probes the INSERT policy with a dummy row whose owner is
--    the JWT sub — the INSERT policy below must pass for the uploader's own
--    id (owner_id = auth.jwt()->>'sub').
-- 4. COLUMN VERIFICATION: the owner column on storage.objects is **owner_id**
--    (TEXT) since tenant migration 0018-add_owner_id_column_deprecate_owner.sql
--    (`owner` uuid is deprecated, kept only for back-compat). Both columns
--    exist in v1.60.4. The policies compare owner_id to auth.jwt()->>'sub'
--    (text-to-text, the official docs pattern).
-- 5. BUCKET VISIBILITY: storage.buckets RLS is ENABLED by tenant migration
--    0007 (no FORCE, no policies) — bucket rows are invisible to client roles
--    but that is irrelevant: the app never reads storage.buckets through
--    PostgREST (buckets are addressed by id/name constants in MediaService).
--    Rows inserted here as postgres (superuser, RLS-bypassing) remain visible
--    to the storage-api's own DB role.
-- 6. EVENT COVER WARNING (S-09 handoff, NOT fixed here): MediaService.
--    uploadEventCover (lib/core/services/media_service.dart:45-51) uploads
--    into the PRIVATE events bucket and returns getPublicUrl — a public-URL
--    read on a public=false bucket serves nothing (getPublicObject requires
--    the bucket's public flag). Event covers must move to the 'groups' bucket
--    or be served via signed URLs (ECRT follow-up).

-- ============================================================
-- 1. BUCKETS — idempotent, out-of-band provisioning becomes declarative
-- ============================================================
-- avatars/groups: public=true (app reads via getPublicUrl — MediaService
-- uploadUserAvatar/uploadGroupCover; storage.buckets.public exists since
-- tenant migration 0008). events: public=false (private — PHUP §photo
-- retrieval reads via createSignedUrl only). ON CONFLICT (id) DO NOTHING is
-- idempotent for stacks that already provisioned the buckets by hand
-- (dashboard/CLI) and re-runs (migrate.sh applies this file repeatedly).
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
--     own user id (MediaService uploadUserAvatar writes avatars/<userId>/…).
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
