-- Samay — RLS audit fixes (agent I-32)
-- Migration 20 of 20. Policy-by-policy audit in
-- docs/development/phase-00-foundation/2026-08-09_I32-rls-audit.md (all 60
-- live policies assessed). This migration fixes the genuine gaps found:
--
--   G-03 (API3:2023 mass assignment): users_update_own allowed any user to
--     UPDATE every column of their own row — personal_shards/preshards/
--     subscription_tier/banned_at/... → self-elevation + economy fraud.
--     Fix (§1): column-level REVOKE UPDATE (the standard PostgREST-safe
--     approach — RLS policies cannot restrict columns) + BEFORE INSERT OR
--     UPDATE trigger assert_safe_user_update() as defense-in-depth and to
--     enforce the one-way soft-delete rule on deleted_at.
--   NEW CRITICAL (found by audit): the 4 admin RPCs (grant_shards,
--     grant_preshards, distribute_shards, recalculate_ranks) + the cron
--     helper hard_delete_expired_users were SECURITY DEFINER with default
--     PUBLIC EXECUTE → ANY anon/authenticated caller could grant themselves
--     shards / distribute event pools / hard-delete accounts.
--     Fix (§2): REVOKE EXECUTE FROM PUBLIC; GRANT EXECUTE TO service_role.
--   SUP-07 class gaps (missing/over-broad policies), fixed in §3-§11:
--     * user_cosmetics_update_own / friendships_update_own had no WITH CHECK
--       (a user could rewrite ownership columns of rows they can see).
--     * groups: clients could INSERT/UPDATE economy/rank columns
--       (group_shards, size_tier, frozen_at, rank_bracket) → leaderboard
--       fraud. rank_bracket INSERT stays allowed (createGroup writes the
--       b0_20 default); nightly recalculate_ranks overwrites it.
--     * events: clients could UPDATE preshards_distributed (re-arm double
--       distribution), featured / featured_until (self-promotion).
--     * messages_read_participant lacked the group-member branch that
--       chats_read_participant has (group-event chat messages unreadable);
--       messages_insert_own allowed posting into chats you cannot access.
--     * ep_insert_promotor had a chicken-and-egg bug: the event creator
--       could never become the first promotor (policy required an existing
--       promotor), breaking createEvent's event_promotores insert.
--     * event_photos read/insert lacked the event_promotores access branch
--       (inconsistent with events_read_access); photo INSERT had no event-
--       access check (upload into invisible events).
--     * event_photo_likes INSERT had no photo-access check (like hidden
--       photos → likes_count manipulation).
--     * group_members: member lists were invisible after the 20260512000006
--       recursion fix (read_own replaced read_same) — restored recursion-
--       safely via SECURITY DEFINER helper is_group_member(); invites were
--       creator-only (co-promotores could not invite); invitees could not
--       accept their own invite (update policy was promotor-only);
--       update_promotor lacked WITH CHECK.
--     * groups/chats had no DELETE policy → leaveGroup's empty-group
--       cleanup silently no-oped.
--     * user_search_view was SELECT-granted to anon → pre-auth username
--       enumeration (app search is authenticated-only).
--
-- Pattern: I-31 hardening (SECURITY DEFINER + SET search_path = '' +
-- fully-qualified refs) for the two new functions where it applies; the
-- trigger function is deliberately SECURITY INVOKER (see §1.2 comment).

-- ============================================================
-- 1. G-03 — users UPDATE mass-assignment (economy/subscription/ban)
-- ============================================================

-- 1.1 Column-level REVOKE: the standard PostgREST-safe block (policies
-- cannot restrict columns). The app only ever UPDATEs username, avatar_url,
-- bio, deleted_at on users (verified: auth_service.softDeleteUser,
-- edit_profile_screen._save). INSERT is unaffected (createUserProfile still
-- sets personal_shards at signup — value is normalized by the trigger, §1.2).
REVOKE UPDATE (
    personal_shards,
    preshards,
    subscription_tier,
    subscription_expires_at,
    banned_at,
    ban_reason,
    date_of_birth
) ON public.users FROM authenticated, anon;

-- 1.2 SECURITY INVOKER BEFORE INSERT OR UPDATE trigger.
-- MISTAKE (avoided): the mission sketch said "SECURITY DEFINER" — that
-- would self-defeat. Inside a SECURITY DEFINER function current_user is the
-- function owner (postgres, superuser), so the BYPASSRLS/superuser gate
-- would be true for EVERY caller and the trigger would never block anyone.
-- SECURITY INVOKER keeps current_user = the effective role (PostgREST does
-- SET ROLE authenticated|service_role on a shared authenticator session,
-- so session_user is NOT usable either). No privilege escalation: the
-- function runs with the caller's own privileges.
-- Gate: allow when the effective role has BYPASSRLS (service_role) or is
-- superuser (postgres — cron jobs, SECURITY DEFINER function bodies that
-- UPDATE users: grant_shards, grant_preshards, distribute_shards,
-- donate_shards_to_group, hard_delete_expired_users).
-- INSERT: normalize protected columns to safe values (signup shard grant
-- read from app_config — the app reads the same key) so a crafted signup
-- cannot mint arbitrary balances/bans.
-- UPDATE: every protected column must be unchanged in NEW, EXCEPT
-- deleted_at NULL → NOT NULL, which is the legitimate self soft-delete
-- (auth_service.softDeleteUser). Clearing deleted_at (self-un-delete) is
-- blocked; account restoration is a service_role/admin action.
CREATE OR REPLACE FUNCTION public.assert_safe_user_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    v_privileged boolean;
BEGIN
    SELECT rolbypassrls OR rolsuper INTO v_privileged
    FROM pg_catalog.pg_roles
    WHERE rolname = current_user;

    IF COALESCE(v_privileged, false) THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        NEW.personal_shards := COALESCE(
            (SELECT value::integer FROM public.app_config WHERE key = 'economy.user_signup_shards'),
            0
        );
        NEW.preshards := 0;
        NEW.subscription_tier := 'free'::public.subscription_tier;
        NEW.subscription_expires_at := NULL;
        NEW.banned_at := NULL;
        NEW.ban_reason := NULL;
        NEW.deleted_at := NULL;
        RETURN NEW;
    END IF;

    IF NEW.personal_shards = OLD.personal_shards
        AND NEW.preshards = OLD.preshards
        AND NEW.subscription_tier = OLD.subscription_tier
        AND NEW.subscription_expires_at IS NOT DISTINCT FROM OLD.subscription_expires_at
        AND NEW.banned_at IS NOT DISTINCT FROM OLD.banned_at
        AND NEW.ban_reason IS NOT DISTINCT FROM OLD.ban_reason
        AND NEW.date_of_birth IS NOT DISTINCT FROM OLD.date_of_birth
        AND (
            NEW.deleted_at IS NOT DISTINCT FROM OLD.deleted_at
            OR (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
        )
    THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'users protected columns (personal_shards, preshards, subscription_tier, subscription_expires_at, banned_at, ban_reason, deleted_at, date_of_birth) may only be changed by a privileged role';
END;
$$;

CREATE TRIGGER assert_safe_user_update_trigger
    BEFORE INSERT OR UPDATE ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.assert_safe_user_update();

-- ============================================================
-- 2. CRITICAL — admin RPCs no longer PUBLIC-EXECUTABLE
-- ============================================================
-- grant_shards/grant_preshards/distribute_shards/recalculate_ranks are
-- SECURITY DEFINER (run as postgres) with default PUBLIC EXECUTE — any
-- anonymous or authenticated caller could call them via PostgREST
-- (/rest/v1/rpc/grant_shards) and mint unlimited shards / drain event
-- pools. hard_delete_expired_users (cron helper) likewise. pg_cron jobs
-- run as postgres and are unaffected by the REVOKE. The Go admin CLI calls
-- them as service_role → GRANT service_role (donate_shards_to_group and
-- check_signup_email already had explicit REVOKE/GRANT — untouched).
REVOKE EXECUTE ON FUNCTION public.grant_shards(uuid, integer, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.grant_preshards(uuid, integer, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.distribute_shards(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.recalculate_ranks(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.hard_delete_expired_users() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.grant_shards(uuid, integer, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.grant_preshards(uuid, integer, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.distribute_shards(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.recalculate_ranks(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.hard_delete_expired_users() TO service_role;

-- ============================================================
-- 3. user_cosmetics_update_own — add WITH CHECK
-- ============================================================
-- Without WITH CHECK the USING clause only filters the OLD row: a user
-- could rewrite user_id/cosmetic_id of their own cosmetics row (transfer
-- or counterfeit). Recreated with the same name → policies_are unchanged.
DROP POLICY IF EXISTS user_cosmetics_update_own ON public.user_cosmetics;
CREATE POLICY user_cosmetics_update_own ON public.user_cosmetics
    FOR UPDATE USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- ============================================================
-- 4. friendships_update_own — add WITH CHECK
-- ============================================================
-- Same gap: OLD-row-only USING let a requester/addressee rewrite the
-- friendship's actor columns. WITH CHECK keeps the caller on one side of
-- the NEW row (legitimate role changes: accept/decline/block stay possible
-- because the caller is requester or addressee of the NEW row).
DROP POLICY IF EXISTS friendships_update_own ON public.friendships;
CREATE POLICY friendships_update_own ON public.friendships
    FOR UPDATE USING (requester_id = auth.uid() OR addressee_id = auth.uid())
    WITH CHECK (requester_id = auth.uid() OR addressee_id = auth.uid());

-- ============================================================
-- 5. groups — economy/rank columns are server-managed
-- ============================================================
-- group_shards (donation trigger + recalculate_ranks), size_tier (member-
-- count trigger), frozen_at, rank_bracket are written only by triggers /
-- SECURITY DEFINER functions / the admin CLI (service_role). Client writes
-- = leaderboard/rank fraud. rank_bracket INSERT stays allowed: the app
-- writes the 'b0_20' default at creation (group_service.createGroup) and
-- the nightly recalculate_ranks overwrites it anyway.
REVOKE INSERT (group_shards, size_tier, frozen_at) ON public.groups FROM authenticated, anon;
REVOKE UPDATE (group_shards, size_tier, frozen_at, rank_bracket) ON public.groups FROM authenticated, anon;

-- ============================================================
-- 6. events — distribution/monetization columns are server-managed
-- ============================================================
-- preshards_distributed (idempotency flag of distribute_shards — client
-- reset would re-arm double distribution), featured / featured_until
-- (paid self-promotion). Cron + admin CLI (service_role) unaffected.
REVOKE UPDATE (preshards_distributed, featured, featured_until) ON public.events FROM authenticated, anon;

-- ============================================================
-- 7. messages — participation checks (read + insert)
-- ============================================================
-- messages_read_participant lacked the group-member branch present in
-- chats_read_participant (group-event chat messages were unreadable to
-- group members). messages_insert_own had no chat-access check at all
-- (post into any chat id). Both rewritten with the same access predicate
-- as chats_read_participant. Recursion-safe: every referenced table's
-- policies terminate on column checks or is_group_member() (§11).
DROP POLICY IF EXISTS messages_read_participant ON public.messages;
CREATE POLICY messages_read_participant ON public.messages FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.chats WHERE id = messages.chat_id AND (
        (type = 'direct' AND EXISTS (SELECT 1 FROM public.chat_participants WHERE chat_id = chats.id AND user_id = auth.uid()))
        OR (type = 'group' AND EXISTS (SELECT 1 FROM public.group_members WHERE group_id = chats.reference_id AND user_id = auth.uid()))
        OR (type = 'event' AND (
            EXISTS (SELECT 1 FROM public.event_invites WHERE event_id = chats.reference_id AND user_id = auth.uid())
            OR EXISTS (SELECT 1 FROM public.event_promotores WHERE event_id = chats.reference_id AND user_id = auth.uid())
            OR EXISTS (SELECT 1 FROM public.group_members gm JOIN public.events e ON e.group_id = gm.group_id WHERE e.id = chats.reference_id AND gm.user_id = auth.uid())
        ))
    ))
);

DROP POLICY IF EXISTS messages_insert_own ON public.messages;
CREATE POLICY messages_insert_own ON public.messages FOR INSERT WITH CHECK (
    sender_id = auth.uid() AND EXISTS (
        SELECT 1 FROM public.chats WHERE id = messages.chat_id AND (
            (type = 'direct' AND EXISTS (SELECT 1 FROM public.chat_participants WHERE chat_id = chats.id AND user_id = auth.uid()))
            OR (type = 'group' AND EXISTS (SELECT 1 FROM public.group_members WHERE group_id = chats.reference_id AND user_id = auth.uid()))
            OR (type = 'event' AND (
                EXISTS (SELECT 1 FROM public.event_invites WHERE event_id = chats.reference_id AND user_id = auth.uid())
                OR EXISTS (SELECT 1 FROM public.event_promotores WHERE event_id = chats.reference_id AND user_id = auth.uid())
                OR EXISTS (SELECT 1 FROM public.group_members gm JOIN public.events e ON e.group_id = gm.group_id WHERE e.id = chats.reference_id AND gm.user_id = auth.uid())
            ))
        )
    )
);

-- ============================================================
-- 8. event_promotores — creator can become first promotor
-- ============================================================
-- Chicken-and-egg bug: WITH CHECK required an existing 'promotor' row, so
-- the event creator could never insert themselves (createEvent does
-- exactly that) and event creation died after the chat insert. Now the
-- event creator may insert their own row (any role), and an existing
-- promotor may add further promotores. Self-subquery is recursion-safe:
-- the subquery runs under ep_read_own (terminal user_id check).
DROP POLICY IF EXISTS ep_insert_promotor ON public.event_promotores;
CREATE POLICY ep_insert_promotor ON public.event_promotores FOR INSERT WITH CHECK (
    (event_promotores.user_id = auth.uid()
     AND EXISTS (SELECT 1 FROM public.events WHERE id = event_promotores.event_id AND created_by_user_id = auth.uid()))
    OR EXISTS (SELECT 1 FROM public.event_promotores ep2
        WHERE ep2.event_id = event_promotores.event_id
          AND ep2.user_id = auth.uid()
          AND ep2.role = 'promotor')
);

-- ============================================================
-- 9. event_photos — access alignment + insert check
-- ============================================================
-- eph_read_access was inconsistent with events_read_access (no
-- event_promotores branch) and eph_insert_own allowed uploading into any
-- event id. Aligned with the canonical event-access predicate.
DROP POLICY IF EXISTS eph_read_access ON public.event_photos;
CREATE POLICY eph_read_access ON public.event_photos FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.events WHERE id = event_photos.event_id AND (
        group_id IS NULL
        OR EXISTS (SELECT 1 FROM public.group_members WHERE group_id = public.events.group_id AND user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM public.event_invites WHERE event_id = public.events.id AND user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM public.event_promotores WHERE event_id = public.events.id AND user_id = auth.uid())
    ))
);

DROP POLICY IF EXISTS eph_insert_own ON public.event_photos;
CREATE POLICY eph_insert_own ON public.event_photos FOR INSERT WITH CHECK (
    uploaded_by_user_id = auth.uid() AND EXISTS (
        SELECT 1 FROM public.events WHERE id = event_photos.event_id AND (
            group_id IS NULL
            OR EXISTS (SELECT 1 FROM public.group_members WHERE group_id = public.events.group_id AND user_id = auth.uid())
            OR EXISTS (SELECT 1 FROM public.event_invites WHERE event_id = public.events.id AND user_id = auth.uid())
            OR EXISTS (SELECT 1 FROM public.event_promotores WHERE event_id = public.events.id AND user_id = auth.uid())
        )
    )
);

-- ============================================================
-- 10. event_photo_likes — insert requires photo access
-- ============================================================
-- Without it a user could like photos of events they cannot access and
-- pump likes_count (collage selection) on invisible content.
DROP POLICY IF EXISTS epl_insert_own ON public.event_photo_likes;
CREATE POLICY epl_insert_own ON public.event_photo_likes FOR INSERT WITH CHECK (
    user_id = auth.uid() AND EXISTS (
        SELECT 1 FROM public.event_photos WHERE id = event_photo_likes.photo_id AND (
            EXISTS (SELECT 1 FROM public.events WHERE id = public.event_photos.event_id AND (
                group_id IS NULL
                OR EXISTS (SELECT 1 FROM public.group_members WHERE group_id = public.events.group_id AND user_id = auth.uid())
                OR EXISTS (SELECT 1 FROM public.event_invites WHERE event_id = public.events.id AND user_id = auth.uid())
                OR EXISTS (SELECT 1 FROM public.event_promotores WHERE event_id = public.events.id AND user_id = auth.uid())
            ))
        )
    )
);

-- ============================================================
-- 11. group_members — member lists, promotor invites, self-accept
-- ============================================================
-- 11.1 is_group_member: SECURITY DEFINER helper (canonical Supabase
-- pattern for group-scoped access checks). Runs as postgres → bypasses RLS
-- → no policy recursion (the 20260512000006 bug class); auth.uid() gates
-- the answer to the caller. STABLE is required for use inside policies
-- (volatile functions are rejected there).
CREATE OR REPLACE FUNCTION public.is_group_member(p_group_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.group_members
        WHERE group_id = p_group_id
          AND user_id = auth.uid()
          AND status = 'active'
    );
$$;

-- 11.2 read_same restored: since 20260512000006, group_members read is
-- own-row-only → member lists showed a single row (group detail members
-- tab broken). read_same (any active member of the group sees the member
-- list) is recursion-safe because it delegates to is_group_member.
CREATE POLICY group_members_read_same ON public.group_members FOR SELECT USING (
    public.is_group_member(group_id)
);

-- 11.3 insert: creator may insert themselves (any role — createGroup
-- inserts the creator as promotor), promotores/co-promotores may invite
-- members (role = 'member'). The old empty-group heuristic is gone — under
-- RLS-filtered subqueries it let non-members insert themselves into any
-- group that looked empty to them. Self-subqueries are safe: the read
-- policies (read_own + read_same) are terminal. status is constrained to
-- the two CHECK-constraint values.
DROP POLICY IF EXISTS group_members_insert_creator ON public.group_members;
CREATE POLICY group_members_insert_promotor ON public.group_members FOR INSERT WITH CHECK (
    (role = 'member' AND status IN ('active', 'invited')
     AND EXISTS (SELECT 1 FROM public.group_members gm2
        WHERE gm2.group_id = group_members.group_id
          AND gm2.user_id = auth.uid()
          AND gm2.role IN ('promotor', 'co_promotor')))
    OR (user_id = auth.uid()
        AND EXISTS (SELECT 1 FROM public.groups
            WHERE id = group_members.group_id AND created_by_user_id = auth.uid()))
);

-- 11.4 self-accept: acceptGroupInvite updates the invitee's own row
-- (status invited → active) but the only UPDATE policy required a
-- promotor/co_promotor — invites could never be accepted. Members may
-- update only their own row, and the WITH CHECK pins role='member' +
-- status='active' so self-updates cannot self-promote (row-level policies
-- cannot compare columns to OLD values; this is the tightest expressible
-- bound and the app never writes anything else on its own membership row).
CREATE POLICY group_members_update_own_status ON public.group_members FOR UPDATE
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid() AND role = 'member' AND status = 'active');

-- 11.5 update_promotor WITH CHECK: previously USING-only → a promotor
-- could move membership rows into groups they do not control. The WITH
-- CHECK re-asserts promotor/co_promotor standing on the NEW row's group.
-- Recursion-safe (read policies terminal; is_group_member bypasses RLS).
DROP POLICY IF EXISTS group_members_update_promotor ON public.group_members;
CREATE POLICY group_members_update_promotor ON public.group_members FOR UPDATE USING (
    EXISTS (SELECT 1 FROM public.group_members gm2
        WHERE gm2.group_id = group_members.group_id
          AND gm2.user_id = auth.uid()
          AND gm2.role IN ('promotor', 'co_promotor'))
) WITH CHECK (
    EXISTS (SELECT 1 FROM public.group_members gm2
        WHERE gm2.group_id = group_members.group_id
          AND gm2.user_id = auth.uid()
          AND gm2.role IN ('promotor', 'co_promotor'))
);

-- ============================================================
-- 12. groups / chats DELETE — empty-group cleanup
-- ============================================================
-- leaveGroup deletes the group + its chat when the last member leaves
-- (group_service.leaveGroup). No DELETE policy existed → the cleanup
-- silently no-oped (orphaned groups). Creator-only predicates; the client
-- now sees the true member list (read_same) so it only deletes genuinely
-- empty groups. The creator can already achieve the same destruction via
-- kickMember, so this adds no new abuse primitive.
CREATE POLICY groups_delete_own ON public.groups FOR DELETE USING (
    created_by_user_id = auth.uid()
);

CREATE POLICY chats_delete_related ON public.chats FOR DELETE USING (
    (type = 'group' AND EXISTS (SELECT 1 FROM public.groups WHERE id = reference_id AND created_by_user_id = auth.uid()))
    OR (type = 'event' AND EXISTS (SELECT 1 FROM public.events WHERE id = reference_id AND created_by_user_id = auth.uid()))
);

-- ============================================================
-- 13. user_search_view — authenticated search only
-- ============================================================
-- The app only ever queries the search view with a signed-in client
-- (lib/features/friends/search_screen.dart); anon SELECT exposed username
-- enumeration pre-auth.
REVOKE SELECT ON public.user_search_view FROM anon;
