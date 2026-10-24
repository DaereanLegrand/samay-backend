-- Samay Schema pgTAP Tests — Comprehensive
-- Covers the MSQ-01 baseline tree (feature-organized migrations; squash of
-- the historical 49-file pile). Schema-identical to that pile (pg_dump-proven).
BEGIN;

SELECT plan(1140);

-- ============================================================
-- SECTION 1: Extensions (migration 20260510000001)
-- ============================================================
SELECT has_extension('pgcrypto');
SELECT has_extension('moddatetime');
SELECT has_extension('pg_cron');

-- ============================================================
-- SECTION 2: Enums — all 21 (migrations 20260510000001, 20260520000001)
-- ============================================================
SELECT has_type('subscription_tier');
SELECT has_type('friendship_status');
SELECT has_type('group_role');
SELECT has_type('size_tier');
SELECT has_type('rank_bracket');
SELECT has_type('event_type');
SELECT has_type('event_status');
SELECT has_type('join_mode');
SELECT has_type('event_role');
SELECT has_type('invite_status');
SELECT has_type('cosmetic_type');
SELECT has_type('chat_type');
SELECT has_type('mini_game_type');
SELECT has_type('mini_game_status');
SELECT has_type('shard_reason');
SELECT has_type('preshard_reason');
SELECT has_type('report_target_type');
SELECT has_type('report_status');
SELECT has_type('admin_role');
SELECT has_type('preshard_remainder_action');
SELECT has_type('feature_request_status');

-- ============================================================
-- SECTION 3: Tables — 29 (migration 20260510000001);
-- the legacy static QR-token table was removed 2026-09-08 (superseded by the code flow)
-- ============================================================
SELECT has_table('users');
SELECT has_table('cosmetics');
SELECT has_table('user_cosmetics');
SELECT has_table('group_cosmetics');
SELECT has_table('friendships');
SELECT has_table('groups');
SELECT has_table('group_members');
SELECT has_table('group_shard_contributions');
SELECT has_table('group_rank_snapshots');
SELECT has_table('events');
SELECT has_table('event_hosts');
SELECT has_table('event_invites');
SELECT has_table('event_attendances');
SELECT has_table('event_photos');
SELECT has_table('event_photo_likes');
SELECT has_table('chats');
SELECT has_table('messages');
SELECT has_table('chat_participants');
SELECT has_table('shard_ledger');
SELECT has_table('preshard_ledger');
SELECT has_table('minigame_sessions');
SELECT has_table('notifications');
SELECT has_table('feature_requests');
SELECT has_table('reports');
SELECT has_table('admin_users');
SELECT has_table('admin_audit_log');
SELECT has_table('subscription_overrides');
SELECT has_table('app_config');
SELECT has_table('processed_webhooks');

-- ============================================================
-- SECTION 4: Migration 20260512000010 — display_name dropped from users
-- ============================================================
SELECT hasnt_column('users', 'display_name', 'display_name was dropped from users table');

-- ============================================================
-- SECTION 5: Migration 20260512000011 — status column on group_members
-- ============================================================
SELECT has_column('group_members', 'status', 'group_members has status column');
SELECT col_type_is('group_members', 'status', 'text', 'group_members.status is text');
SELECT col_not_null('group_members', 'status', 'group_members.status is NOT NULL');

-- ============================================================
-- SECTION 6: Migrations 20260513000002 + 20260724000001 — signup_tracker table
-- ============================================================
SELECT has_table('signup_tracker');
SELECT has_column('signup_tracker', 'email');
SELECT has_column('signup_tracker', 'profile_created');
SELECT has_column('signup_tracker', 'created_at');
SELECT has_column('signup_tracker', 'updated_at');
SELECT col_is_pk('signup_tracker', 'email');

-- signup_tracker RLS is enabled AND forced (migration 20260724000001
-- added FORCE ROW LEVEL SECURITY so even the table owner must obey policies)
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'signup_tracker'::regclass),
    'signup_tracker has RLS enabled'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'signup_tracker'::regclass),
    'signup_tracker has FORCE ROW LEVEL SECURITY (migration 20260724000001)'
);

-- ============================================================
-- SECTION 7: Migration 20260520000001 — user_search_view
-- (bio added 20260815000001 — public profile copy only; the sensitive
--  columns stay out of the barrier.)
-- ============================================================
SELECT has_view('user_search_view');
SELECT columns_are('user_search_view', ARRAY['id', 'username', 'avatar_url', 'bio', 'profile_public'],
    'user_search_view exposes the safe identity columns + profile_public (Q8)');

-- ============================================================
-- SECTION 8: Triggers — all 9 (migrations 20260510000001, 20260512000007)
-- ============================================================
SELECT has_trigger('users', 'users_updated_at');
SELECT has_trigger('groups', 'groups_updated_at');
SELECT has_trigger('events', 'events_updated_at');
SELECT has_trigger('group_members', 'group_size_tier_trigger');
SELECT has_trigger('events', 'dynamic_qr_enabled_trigger');
SELECT has_trigger('messages', 'message_cap_trigger');
SELECT has_trigger('group_shard_contributions', 'group_shards_increment_trigger');
SELECT has_trigger('event_photo_likes', 'photo_likes_count_trigger');
SELECT has_trigger('events', 'shard_distribution_dispatch_trigger');

-- ============================================================
-- SECTION 9: Trigger Functions (6 SECURITY DEFINER)
-- ============================================================
SELECT has_function('update_group_size_tier');
SELECT has_function('set_dynamic_qr_enabled');
SELECT has_function('enforce_message_cap');
SELECT has_function('increment_group_shards');
SELECT has_function('update_photo_likes_count');
SELECT has_function('dispatch_shard_distribution');

-- ============================================================
-- SECTION 10: RPC — donate_shards_to_group
-- (migrations 20260512000001, 20260724000002)
-- ============================================================
-- Migration 20260724000002 hardened the RPC: an auth.uid() != p_user_id
-- guard rejects cross-user donations and EXECUTE was REVOKEd from PUBLIC
-- and GRANTed to authenticated only. Behavioral checks (anon denied,
-- cross-user donation blocked) are covered by the curl integration test
-- test/opt-001-rls-security.sh (TEST H1-H3) — run it once the stack is up.
SELECT has_function('donate_shards_to_group', ARRAY['uuid', 'uuid', 'integer', 'timestamptz'],
    'donate_shards_to_group(p_group_id, p_user_id, p_amount, p_expires_at)');

-- ============================================================
-- SECTION 11: RPC — hard_delete_expired_users (migration 20260510000002)
-- ============================================================
SELECT has_function('hard_delete_expired_users');

-- ============================================================
-- SECTION 12: RPCs — Admin RPCs (migration 20260520000001)
-- ============================================================
SELECT has_function('grant_shards', ARRAY['uuid', 'integer', 'text'],
    'grant_shards(p_user_id, p_amount, p_reason)');
SELECT has_function('grant_preshards', ARRAY['uuid', 'integer', 'text'],
    'grant_preshards(p_user_id, p_amount, p_reason)');
SELECT has_function('distribute_shards', ARRAY['uuid'],
    'distribute_shards(p_event_id)');
SELECT has_function('recalculate_ranks', ARRAY['text'],
    'recalculate_ranks(p_tier)');

-- ============================================================
-- SECTION 13: Migration 20260513000001/02 — handle_signup RPC was dropped
-- ============================================================
SELECT hasnt_function('handle_signup', ARRAY['text'],
    'handle_signup RPC was dropped in migration 20260513000002');

-- ============================================================
-- SECTION 14: RLS Policies — users
-- ============================================================
SELECT policies_are('users', ARRAY[
    'users_read_own',
    'users_update_own',
    'users_insert_own'
], 'users has expected RLS policies');

-- ============================================================
-- SECTION 15: RLS Policies — signup_tracker (email-scoped, migration 20260724000001)
-- ============================================================
-- The four wide-open "Anyone can ..." policies were dropped in
-- 20260724000001 and replaced with email-scoped policies
-- (email = auth.jwt() ->> 'email').
SELECT policies_are('signup_tracker', ARRAY[
    'signup_tracker_select_own',
    'signup_tracker_insert_own',
    'signup_tracker_update_own',
    'signup_tracker_delete_own'
], 'signup_tracker has email-scoped RLS policies (own email only)');

-- ============================================================
-- SECTION 16: RLS Policies — friendships
-- ============================================================
SELECT policies_are('friendships', ARRAY[
    'friendships_read_involving',
    'friendships_insert_own',
    'friendships_update_own',
    'friendships_delete_own',
    'active_users_only'
], 'friendships has expected RLS policies');

-- ============================================================
-- SECTION 17: RLS Policies — groups
-- groups_delete_own added by migration 20260809000002 (I-32) — creator
-- deletes own group during leaveGroup's empty-group cleanup.
-- ============================================================
SELECT policies_are('groups', ARRAY[
    'groups_read_member',
    'groups_read_own',
    'groups_update_host',
    'groups_insert_own',
    'groups_delete_own',
    'active_users_only'
], 'groups has expected RLS policies');

-- ============================================================
-- SECTION 18: RLS Policies — group_members (no recursion)
-- Migration 20260809000002 (I-32): insert_creator → insert_host
-- (creator self-insert + host invites), read_same restored via
-- SECURITY DEFINER is_group_member() (member lists), update_own_status
-- added (invitees accept their own invite; role pinned to 'member').
-- ============================================================
SELECT policies_are('group_members', ARRAY[
    'group_members_read_own',
    'group_members_read_same',
    'group_members_insert_host',
    'group_members_delete_own',
    'group_members_delete_host',
    'group_members_update_own_status',
    'group_members_update_host',
    'active_users_only'
], 'group_members has expected RLS policies (no recursion)');

-- ============================================================
-- SECTION 19: RLS Policies — events (no recursion)
-- ============================================================
SELECT policies_are('events', ARRAY[
    'events_read_access',
    'events_update_host',
    'events_insert_own',
    'active_users_only'
], 'events has expected RLS policies');

-- ============================================================
-- SECTION 20: RLS Policies — event_hosts (no recursion)
-- ============================================================
-- 060_events/06_staff.sql (Stage 3): ep_insert_host was DROPPED (its
-- creator/host INSERT branch bypassed the frozen capacity — event_hosts
-- writes are exclusively the create_event / designate_event_staff SECURITY
-- DEFINER RPCs). ep_read_event_access opens the FULL roster to the event's
-- hosts/staff (via the security-barrier event_host_access_view, because a
-- direct self-referencing SELECT policy recurses infinitely); ep_read_own
-- stays for everyone else.
SELECT policies_are('event_hosts', ARRAY[
    'ep_read_own',
    'ep_read_event_access',
    'ep_read_member_roster',
    'active_users_only'
], 'event_hosts has expected RLS policies (ep_insert_host dropped — RPC-only writes; ep_read_member_roster opens the organizer roster to event members, 09_attendee_roster.sql)');

-- ============================================================
-- SECTION 21: RLS Policies — event_invites
-- ============================================================
SELECT policies_are('event_invites', ARRAY[
    'ei_read_own',
    'ei_read_event_access',
    'ei_read_confirmed_roster',
    'active_users_only'
], 'event_invites has expected RLS policies (own-row read + host/staff event-read + member confirmed-roster read; ei_update_own dropped for the SECURITY DEFINER invite family)');

-- ============================================================
-- SECTION 21b: Events manual invites RPC family (migration
-- 060_events/05_manual_invites.sql, 2026-09-08) — host invites specific
-- guests (search + multi-select), invitees accept/decline, frozen capacity
-- is seat-reservation-enforced while inviting. Behavior: opt-025. Here:
-- presence + ACL posture (SECURITY DEFINER, PUBLIC revoked).
-- ============================================================
SELECT has_function('invite_event_guests', ARRAY['uuid', 'uuid[]'],
    'invite_event_guests(uuid, uuid[]) exists (060_events/05 manual invites)');
SELECT has_function('accept_event_invite', ARRAY['uuid'],
    'accept_event_invite(uuid) exists (060_events/05 manual invites)');
SELECT has_function('decline_event_invite', ARRAY['uuid'],
    'decline_event_invite(uuid) exists (060_events/05 manual invites)');

SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('invite_event_guests', 'accept_event_invite',
                         'decline_event_invite')
       AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')) = 3,
    'event invite RPC family has no PUBLIC/anon EXECUTE (authenticated + service_role only)'
);

-- ============================================================
-- SECTION 21c: Events staff RPC family + roster view (migration
-- 060_events/06_staff.sql, 2026-09-08) — the host designates/removes staff
-- (capacity + conversion semantics) and hosts/staff read the full roster.
-- Behavior: opt-026. Here: presence + ACL posture (SECURITY DEFINER, PUBLIC
-- revoked) + the recursion-free roster view exists.
-- ============================================================
SELECT has_function('designate_event_staff', ARRAY['uuid', 'uuid[]'],
    'designate_event_staff(uuid, uuid[]) exists (060_events/06 staff)');
SELECT has_function('remove_event_staff', ARRAY['uuid', 'uuid'],
    'remove_event_staff(uuid, uuid) exists (060_events/06 staff)');

SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('designate_event_staff', 'remove_event_staff')
       AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')) = 2,
    'staff RPC family has no PUBLIC/anon EXECUTE (authenticated + service_role only)'
);

SELECT has_view('public', 'event_host_access_view',
    'event_host_access_view (security-barrier event_hosts projection) exists — recursion-free roster read');

SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'event_hosts'::regclass),
    'event_hosts keeps FORCE ROW LEVEL SECURITY (RPC writes still RLS-checked reads)'
);

-- ============================================================
-- SECTION 21d: Events attendance code (migration
-- 060_events/07_code.sql, 2026-09-08) — authenticator-style 24-hex code
-- derived from a per-attendee secret + 30-s window (event_code), issued
-- to attendees (get_my_code) and validated host/staff-only ONCE
-- (validate_code). Behavior: opt-027. Here: presence + ACL posture
-- (SECURITY DEFINER, PUBLIC revoked, zero client table grants) + FORCE RLS,
-- and (2026-09-09 security fix) the CONFIRMED-invite attendee gate — a PENDING
-- invitee is not an attendee (no code, never confirmable).
-- ============================================================
SELECT has_table('event_code_keys',
    'event_code_keys exists (060_events/07 code secrets)');
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'event_code_keys'::regclass),
    'event_code_keys has FORCE ROW LEVEL SECURITY (secrets RPC-only)'
);
SELECT ok(
    (SELECT count(*)::int FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'event_code_keys') = 0,
    'event_code_keys has NO client RLS policies (only the SECURITY DEFINER RPC touches it)'
);
SELECT ok(
    (SELECT count(*)::int FROM pg_constraint
     WHERE conname = 'event_code_keys_event_id_user_id_key') = 1,
    'event_code_keys has a UNIQUE (event_id, user_id) key (one secret per attendee)'
);
SELECT has_function('event_code', ARRAY['text', 'bigint'],
    'event_code(text, bigint) exists (060_events/07 code derivation)');
SELECT has_function('get_my_code', ARRAY['uuid'],
    'get_my_code(uuid) exists (060_events/07 code issue)');
SELECT has_function('validate_code', ARRAY['uuid', 'text'],
    'validate_code(uuid, text) exists (060_events/07 code validate)');

SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('event_code', 'get_my_code',
                         'validate_code')
       AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')) = 3,
    'code RPC family has no PUBLIC/anon EXECUTE (authenticated/service_role only)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%AND status = ''accepted''%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%status = ''attended''%'
       AND pg_get_functiondef(p.oid) LIKE '%not_invited%'
     FROM pg_proc p WHERE proname = 'get_my_code'),
    'get_my_code requires an ACCEPTED invite (accepted-only; attended/pending → not_invited, 2026-09-10)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%status = ''accepted'' OR status = ''attended''%'
       AND pg_get_functiondef(p.oid) LIKE '%not_invited%'
     FROM pg_proc p WHERE proname = 'validate_code'),
    'validate_code refuses to confirm a PENDING invitee (CONFIRMED-invite gate, 2026-09-09)'
);

SELECT has_trigger('event_invites', 'code_key_purge_on_invite_delete',
    'event_invites purge trigger removes code keys on invite-row deletion (declined/converted)');
SELECT has_trigger('event_hosts', 'code_key_purge_on_host_delete',
    'event_hosts purge trigger removes code keys on staff removal');

-- SECTION 21e: Events guest-roster realtime (060_events/08_realtime.sql +
-- 960_realtime, 2026-09-09) — event_invites joins supabase_realtime with
-- REPLICA IDENTITY FULL so the host/staff guest roster on the event detail
-- live-updates when an invitee accepts/declines on their own device (client
-- invalidates eventGuestsProvider on every row event for the event). Delivery
-- stays RLS-gated: hosts/staff get full-roster rows, invitees their own.
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'event_invites'
    ),
    'event_invites joins the supabase_realtime publication (guest-roster live updates, 060_events/08_realtime.sql)'
);
SELECT is(
    (SELECT relreplident FROM pg_class WHERE oid = 'public.event_invites'::regclass),
    'f',
    'event_invites has REPLICA IDENTITY FULL (full-row realtime UPDATE/DELETE payloads, 060_events/08_realtime.sql)'
);

-- SECTION 21f: Attendee-side event roster (060_events/09_attendee_roster.sql,
-- 2026-09-09, tightened 2026-09-09) — event members read the organizer roster
-- (`event_hosts`) and the event's CONFIRMED invite rows only; other people's
-- pending invites stay host/own-only. Membership is CONFIRMED only
-- (accepted/attended): a PENDING invitee reads no roster (security fix,
-- 2026-09-09) and keeps `ei_read_own` for the accept/decline card. The
-- membership check rides a security-barrier view (recursion-free); event_hosts
-- joins supabase_realtime with REPLICA IDENTITY FULL so the organizer roster
-- streams live. Behavior: opt-025 TEST H. Here: view + policy + realtime
-- posture.
SELECT has_view('public', 'event_roster_membership_view',
    'event_roster_membership_view (security-barrier caller invite projection) exists — recursion-free member check');
SELECT ok(
    (SELECT pg_get_viewdef('public.event_roster_membership_view'::regclass, true)
            LIKE '%status = ''accepted''::invite_status%'
       AND pg_get_viewdef('public.event_roster_membership_view'::regclass, true)
            LIKE '%status = ''attended''::invite_status%'),
    'event_roster_membership_view projects only CONFIRMED (accepted/attended) memberships — pending invitees read no roster (2026-09-09)'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'event_hosts'
          AND policyname = 'ep_read_member_roster'
    ),
    'event_hosts has ep_read_member_roster (members read the organizer roster)'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'event_invites'
          AND policyname = 'ei_read_confirmed_roster'
    ),
    'event_invites has ei_read_confirmed_roster (members read accepted/attended rows only)'
);
SELECT is(
    (SELECT relreplident FROM pg_class WHERE oid = 'public.event_hosts'::regclass),
    'f',
    'event_hosts has REPLICA IDENTITY FULL (full-row realtime payloads for the organizer roster, 060_events/09_attendee_roster.sql)'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'event_hosts'
    ),
    'event_hosts joins the supabase_realtime publication (organizer roster streams live to members, 060_events/09_attendee_roster.sql)'
);

-- SECTION 21g: Attendance realtime (060_events/08_realtime.sql +
-- 960_realtime, 2026-09-10, Task C) — event_attendances joins
-- supabase_realtime with REPLICA IDENTITY FULL so a scan that confirms the
-- caller (guest OR host/staff — only this table records a host/staff member)
-- flips an already-open detail/QR screen to the terminal "Ya te registraste"
-- state (client invalidates myAttendanceProvider on every row event). Delivery
-- stays RLS-gated (ea_read_access).
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'event_attendances'
    ),
    'event_attendances joins the supabase_realtime publication (assist flip streams live, 060_events/08_realtime.sql)'
);
SELECT is(
    (SELECT relreplident FROM pg_class WHERE oid = 'public.event_attendances'::regclass),
    'f',
    'event_attendances has REPLICA IDENTITY FULL (full-row realtime payloads for the assist flip, 060_events/08_realtime.sql)'
);

-- ============================================================
-- SECTION 23: RLS Policies — event_attendances
-- ============================================================
SELECT policies_are('event_attendances', ARRAY[
    'ea_read_access',
    'active_users_only'
], 'event_attendances has expected RLS policies');

-- ============================================================
-- SECTION 24: RLS Policies — event_photos
-- ============================================================
SELECT policies_are('event_photos', ARRAY[
    'eph_read_access',
    'eph_insert_own',
    'eph_delete_own_or_host',
    'active_users_only'
], 'event_photos has expected RLS policies');

-- ============================================================
-- SECTION 25: RLS Policies — event_photo_likes
-- ============================================================
SELECT policies_are('event_photo_likes', ARRAY[
    'epl_read_access',
    'epl_insert_own',
    'epl_delete_own',
    'active_users_only'
], 'event_photo_likes has expected RLS policies');

-- ============================================================
-- SECTION 26: RLS Policies — chats
-- chats_delete_related added by migration 20260809000002 (I-32) — creator
-- deletes the group/event chat during leaveGroup cleanup.
-- ============================================================
SELECT policies_are('chats', ARRAY[
    'chats_insert_related',
    'chats_read_participant',
    'chats_delete_related',
    'active_users_only'
], 'chats has expected RLS policies');

-- 26a: the direct branches must correlate to the OUTER chats.id. The original
-- policies used an unqualified `id` (shadowed by chat_participants.id →
-- chat_participants.chat_id = chat_participants.id, never true): direct chats
-- were invisible to participants and every messages INSERT violated
-- messages_insert_participant with 42501. Fixed 20260815000003.
SELECT ok(
    (SELECT pg_get_expr(polqual, polrelid) FROM pg_policy
      WHERE polname = 'chats_read_participant' AND polrelid = 'public.chats'::regclass)
        LIKE '%chat_participants.chat_id = chats.id%'
      AND (SELECT pg_get_expr(polqual, polrelid) FROM pg_policy
            WHERE polname = 'chats_read_participant' AND polrelid = 'public.chats'::regclass)
        NOT LIKE '%chat_participants.chat_id = chat_participants.id%',
    'chats_read_participant correlates the direct branch to chats.id (20260815000003)'
);
SELECT ok(
    (SELECT pg_get_expr(polwithcheck, polrelid) FROM pg_policy
      WHERE polname = 'chats_insert_related' AND polrelid = 'public.chats'::regclass)
        LIKE '%chat_participants.chat_id = chats.id%'
      AND (SELECT pg_get_expr(polwithcheck, polrelid) FROM pg_policy
            WHERE polname = 'chats_insert_related' AND polrelid = 'public.chats'::regclass)
        NOT LIKE '%chat_participants.chat_id = chat_participants.id%',
    'chats_insert_related correlates the direct branch to chats.id (20260815000003)'
);

-- ============================================================
-- SECTION 27: RLS Policies — messages
-- ============================================================
SELECT policies_are('messages', ARRAY[
    'messages_read_participant',
    'messages_insert_participant',
    'active_users_only'
], 'messages has expected RLS policies');

-- ============================================================
-- SECTION 28: RLS Policies — chat_participants
-- ============================================================
SELECT policies_are('chat_participants', ARRAY[
    'cp_read_own',
    'cp_read_participant',
    'active_users_only'
], 'chat_participants has expected RLS policies');

-- 28a: chat inbox (migration 20260815000004) — read watermark + RPCs
SELECT has_column('chat_participants', 'last_read_at',
    'chat_participants has the last_read_at read watermark');
SELECT col_type_is('chat_participants', 'last_read_at', 'timestamp with time zone',
    'last_read_at is timestamptz');
SELECT col_not_null('chat_participants', 'last_read_at',
    'last_read_at defaults now() — existing participants start read');
SELECT has_function('get_chat_inbox',
    'get_chat_inbox() exists (SECURITY DEFINER RPC, migration 20260815000004)');
SELECT is_definer('public', 'get_chat_inbox', ARRAY[]::name[],
    'get_chat_inbox is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'get_chat_inbox'),
    'get_chat_inbox sets search_path = '''' (migration 20260815000004)'
);
SELECT function_privs_are('public', 'get_chat_inbox', ARRAY[]::name[], 'public', ARRAY[]::name[],
    'get_chat_inbox is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'get_chat_inbox', ARRAY[]::name[], 'authenticated', ARRAY['EXECUTE'],
    'get_chat_inbox is authenticated-EXECUTABLE');
SELECT has_function('mark_chat_read', ARRAY['uuid'],
    'mark_chat_read(p_chat_id uuid) exists (SECURITY DEFINER RPC)');
SELECT is_definer('public', 'mark_chat_read', ARRAY['uuid'],
    'mark_chat_read is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'mark_chat_read'),
    'mark_chat_read sets search_path = '''' (migration 20260815000004)'
);
SELECT function_privs_are('public', 'mark_chat_read', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'mark_chat_read is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'mark_chat_read', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'mark_chat_read is authenticated-EXECUTABLE');

-- 28b: chat read receipts (migration 20260815000005) — read_at + privacy switch
SELECT has_column('messages', 'read_at',
    'messages has the read_at read-receipt timestamp');
SELECT col_type_is('messages', 'read_at', 'timestamp with time zone',
    'read_at is timestamptz');
SELECT col_is_null('messages', 'read_at',
    'read_at is nullable — NULL until the recipient marks the message read');
SELECT has_column('users', 'read_receipts_enabled',
    'users has the read_receipts_enabled privacy switch');
SELECT col_type_is('users', 'read_receipts_enabled', 'boolean',
    'read_receipts_enabled is boolean');
SELECT col_not_null('users', 'read_receipts_enabled',
    'read_receipts_enabled is NOT NULL');
SELECT col_default_is('users', 'read_receipts_enabled', 'true',
    'read_receipts_enabled defaults true — receipts on by default');
SELECT has_function('mark_messages_read', ARRAY['uuid'],
    'mark_messages_read(p_chat_id uuid) exists (SECURITY DEFINER RPC)');
SELECT is_definer('public', 'mark_messages_read', ARRAY['uuid'],
    'mark_messages_read is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'mark_messages_read'),
    'mark_messages_read sets search_path = '''' (migration 20260815000005)'
);
SELECT function_privs_are('public', 'mark_messages_read', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'mark_messages_read is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'mark_messages_read', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'mark_messages_read is authenticated-EXECUTABLE');

-- 28c: global user ranking (migration 20260818000002) — profile_public + get_user_ranking
SELECT has_column('users', 'profile_public',
    'users has the profile_public privacy flag (migration 20260818000002)');
SELECT col_type_is('users', 'profile_public', 'boolean',
    'profile_public is boolean');
SELECT col_not_null('users', 'profile_public',
    'profile_public is NOT NULL — every account starts private');
SELECT col_default_is('users', 'profile_public', 'false',
    'profile_public defaults false — anonymous until the user opts in');
SELECT has_function('get_user_ranking', ARRAY['integer'],
    'get_user_ranking(p_limit integer) exists (SECURITY DEFINER RPC, migration 20260818000002)');
SELECT is_definer('public', 'get_user_ranking', ARRAY['integer'],
    'get_user_ranking is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'get_user_ranking'),
    'get_user_ranking sets search_path = '''' (migration 20260818000002)'
);
SELECT function_privs_are('public', 'get_user_ranking', ARRAY['integer']::name[], 'public', ARRAY[]::name[],
    'get_user_ranking is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'get_user_ranking', ARRAY['integer']::name[], 'authenticated', ARRAY['EXECUTE'],
    'get_user_ranking is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%deleted_at IS NULL%'
      AND pg_get_functiondef(p.oid) LIKE '%ORDER BY u.personal_shards DESC%'
     FROM pg_proc p WHERE proname = 'get_user_ranking'),
    'get_user_ranking excludes deleted users and orders by personal_shards DESC (20260818000002)'
);

-- 28c: message deletion (migration 20260815000006) — 5-min delete_for_everyone
--      + undecryptable cleanup + audit trail
SELECT has_table('deleted_messages',
    'deleted_messages audit trail exists (migration 20260815000006)');
SELECT has_column('messages', 'sent_at',
    'messages has the server-authoritative sent_at send timestamp');
SELECT col_type_is('messages', 'sent_at', 'timestamp with time zone',
    'sent_at is timestamptz');
SELECT col_not_null('messages', 'sent_at',
    'sent_at is NOT NULL');
SELECT col_default_is('messages', 'sent_at', 'now()',
    'sent_at defaults to now() — the SERVER clock anchors the 5-minute delete window');
SELECT has_function('delete_message_for_everyone', ARRAY['uuid'],
    'delete_message_for_everyone(p_message_id uuid) exists (SECURITY DEFINER RPC)');
SELECT is_definer('public', 'delete_message_for_everyone', ARRAY['uuid'],
    'delete_message_for_everyone is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'delete_message_for_everyone'),
    'delete_message_for_everyone sets search_path = '''' (migration 20260815000006)'
);
SELECT function_privs_are('public', 'delete_message_for_everyone', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'delete_message_for_everyone is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'delete_message_for_everyone', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'delete_message_for_everyone is authenticated-EXECUTABLE');
SELECT has_function('delete_undecryptable_messages', ARRAY['uuid', 'uuid[]'],
    'delete_undecryptable_messages(p_chat_id uuid, p_message_ids uuid[]) exists (SECURITY DEFINER RPC)');
SELECT is_definer('public', 'delete_undecryptable_messages', ARRAY['uuid', 'uuid[]'],
    'delete_undecryptable_messages is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'delete_undecryptable_messages'),
    'delete_undecryptable_messages sets search_path = '''' (migration 20260815000006)'
);
SELECT function_privs_are('public', 'delete_undecryptable_messages', ARRAY['uuid', 'uuid[]']::name[], 'public', ARRAY[]::name[],
    'delete_undecryptable_messages is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'delete_undecryptable_messages', ARRAY['uuid', 'uuid[]']::name[], 'authenticated', ARRAY['EXECUTE'],
    'delete_undecryptable_messages is authenticated-EXECUTABLE');

-- ============================================================
-- SECTION 29: RLS Policies — shard_ledger / preshard_ledger
-- ============================================================
SELECT policies_are('shard_ledger', ARRAY[
    'sl_read_own',
    'active_users_only'
], 'shard_ledger has expected RLS policies');

SELECT policies_are('preshard_ledger', ARRAY[
    'pl_read_own',
    'active_users_only'
], 'preshard_ledger has expected RLS policies');

-- ============================================================
-- SECTION 30: RLS Policies — user_cosmetics
-- ============================================================
SELECT policies_are('user_cosmetics', ARRAY[
    'user_cosmetics_read_own',
    'user_cosmetics_update_own',
    'active_users_only'
], 'user_cosmetics has expected RLS policies');

-- ============================================================
-- SECTION 31: RLS Policies — cosmetics, group_cosmetics (public read)
-- ============================================================
SELECT policies_are('cosmetics', ARRAY[
    'cosmetics_read_all'
], 'cosmetics is public-readable');
SELECT policies_are('group_cosmetics', ARRAY[
    'group_cosmetics_select'
], 'group_cosmetics is public-readable');

-- ============================================================
-- SECTION 32: RLS Policies — remaining non-admin tables
-- ============================================================
SELECT policies_are('group_shard_contributions', ARRAY[
    'gsc_read_member',
    'active_users_only'
], 'group_shard_contributions has expected RLS policies');
SELECT policies_are('group_rank_snapshots', ARRAY[
    'grs_read_all'
], 'group_rank_snapshots is public-readable');
SELECT policies_are('minigame_sessions', ARRAY[
    'ms_read_group_member',
    'ms_read_invitee',
    'ms_read_direct_participant',
    'ms_read_public',
    'active_users_only'
], 'minigame_sessions has expected RLS policies (ms_read_public added by 211_minigame_public)');
SELECT col_is_null('minigame_sessions', 'group_id',
    'minigame_sessions.group_id is NULLABLE (NULL = direct session, direct-minigames 2026-08-27)');
SELECT col_not_null('minigame_sessions', 'player_limit',
    'minigame_sessions.player_limit is NOT NULL (subscription-scaled player cap, frozen at creation)');
SELECT col_has_default('minigame_sessions', 'player_limit',
    'minigame_sessions.player_limit defaults to 8 (free tier baseline)');
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'minigame_sessions'
          AND policyname = 'ms_read_direct_participant'
          AND cmd = 'SELECT'
          AND qual LIKE '%group_id IS NULL%'
          AND qual LIKE '%participants%'
    )),
    'ms_read_direct_participant requires group_id IS NULL AND auth.uid() IN participants (direct-session read only)'
);
SELECT policies_are('notifications', ARRAY[
    'notif_read_own',
    'notif_update_own',
    'active_users_only'
], 'notifications has expected RLS policies');
SELECT policies_are('feature_requests', ARRAY[
    'fr_read_own',
    'fr_insert_own'
], 'feature_requests has expected RLS policies');
SELECT policies_are('reports', ARRAY[
    'reports_insert_own',
    'active_users_only'
], 'reports has expected RLS policies');
SELECT policies_are('app_config', ARRAY[
    'app_config_read_all'
], 'app_config is public-readable');

-- ============================================================
-- SECTION 33: RLS Policies — admin tables (service_role only)
-- ============================================================
SELECT policies_are('admin_users', ARRAY[
    'admin_users_no_access'
], 'admin_users is service_role only');
SELECT policies_are('admin_audit_log', ARRAY[
    'admin_audit_log_no_access'
], 'admin_audit_log is service_role only');
SELECT policies_are('subscription_overrides', ARRAY[
    'subscription_overrides_no_access'
], 'subscription_overrides is service_role only');
SELECT policies_are('processed_webhooks', ARRAY[
    'processed_webhooks_no_access'
], 'processed_webhooks is service_role only');

-- ============================================================
-- SECTION 34: Seed data
-- NOTE (I-33, 2026-08-09): seed INSERTs were removed from
-- migrations/20260510000001_full_schema.sql §7 — supabase/seed.sql is now the
-- single source of truth (SUP-04). Applied post-migration via config.toml
-- [db.seed] / reset.sh / migrate.sh. Post-reset state is unchanged except for
-- app.search_debounce_ms which I-33 added to seed.sql (read by invite/search
-- screens, PERF-05/L-24) and ranking.anonymize_names which C-social added for
-- the global user-ranking censor (20260818000002) → count is 39.
-- ============================================================
-- MSQ-01 contract (user directive 2026-08-23): init/reset apply migrations
-- PLUS required seed-config.sql automatically (fundamental app config,
-- zero user data). Test data is explicit-only (`make supabase-seed-test`).
SELECT ok(
    (SELECT count(*) = 1 FROM admin_users),
    'admin_users has the system admin row (from auto-applied seed-config)'
);
SELECT ok(
    (SELECT count(*) = 43 FROM app_config),
    'app_config has 43 tuning rows (from auto-applied seed-config; +3 minigame player caps, 2026-08-27, +4 events capacity keys 2026-09-08, +1 code.window_seconds 2026-09-08, −3 legacy QR-token/config rows removed 2026-09-08)'
);

-- ============================================================
-- SECTION 35: admin_users retains display_name (never dropped)
-- ============================================================
SELECT has_column('admin_users', 'display_name',
    'admin_users retains display_name (only dropped from users)');
SELECT ok(
    (SELECT count(*) = 0 FROM users),
    'users table is empty after init/reset; seed-config seeds no user rows (reviewer is staging-only)'
);

-- ============================================================
-- SECTION 36: Verify handle_signup was actually dropped
-- ============================================================
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_proc WHERE proname = 'handle_signup'
    ),
    'handle_signup function is confirmed absent from pg_proc'
);

-- ============================================================
-- SECTION 37: RPC — check_signup_email (migration 20260724000001)
-- ============================================================
-- SECURITY DEFINER pre-auth email lookup used by checkSignupEmail()
-- (lib/core/services/supabase_service.dart). Migration 20260724000001
-- REVOKEd EXECUTE from PUBLIC and granted it to anon + authenticated.
SELECT has_function('check_signup_email', ARRAY['text'],
    'check_signup_email(p_email text) exists');
SELECT function_privs_are('public', 'check_signup_email', ARRAY['text']::name[], 'anon', ARRAY['EXECUTE'],
    'anon has EXECUTE on check_signup_email');
SELECT function_privs_are('public', 'check_signup_email', ARRAY['text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'authenticated has EXECUTE on check_signup_email');

-- ============================================================
-- SECTION 37b: RPC — upsert_signup_tracker (migration 20260812000001)
-- ============================================================
-- SECURITY DEFINER pre-auth signup_tracker WRITE used by sendOtp()
-- (lib/core/services/auth_service.dart): the email-scoped RLS policies
-- (email = auth.jwt()->>'email') can never match an ANONYMOUS JWT (no
-- email claim), so the client's pre-OTP upsert 42501'd into the OTP
-- funnel's "No tienes permiso..." error. Same posture as check_signup_email:
-- search_path = '' + EXECUTE granted to anon + authenticated only. The
-- p_profile_created = true branch is gated on the JWT email matching
-- p_email (anon must not be able to squat 'exists' rows).
SELECT has_function('upsert_signup_tracker', ARRAY['text', 'boolean'],
    'upsert_signup_tracker(p_email text, p_profile_created boolean) exists');
SELECT is((SELECT prosecdef FROM pg_proc WHERE proname = 'upsert_signup_tracker'),
    true, 'upsert_signup_tracker is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY(proconfig) FROM pg_proc WHERE proname = 'upsert_signup_tracker'),
    'upsert_signup_tracker sets search_path = '''' (migration 20260812000001)'
);
SELECT function_privs_are('public', 'upsert_signup_tracker', ARRAY['text', 'boolean']::name[], 'anon', ARRAY['EXECUTE'],
    'anon has EXECUTE on upsert_signup_tracker');
SELECT function_privs_are('public', 'upsert_signup_tracker', ARRAY['text', 'boolean']::name[], 'authenticated', ARRAY['EXECUTE'],
    'authenticated has EXECUTE on upsert_signup_tracker');
-- Behavioral: anon-style claims (no email claim) can write the pre-verify
-- row (profile_created = false) but cannot squat profile_created = true.
SELECT set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000000","role":"anon"}', false);
SELECT lives_ok($$SELECT public.upsert_signup_tracker('tracker-probe@test.local', false)$$,
    'anon-style claims: pre-verify write (profile_created = false) works');
SELECT throws_ok($$SELECT public.upsert_signup_tracker('tracker-probe@test.local', true)$$,
    'P0001', 'Not authorized',
    'anon-style claims: profile_created = true raises (JWT-email guard, 20260812000001)');

-- ============================================================
-- SECTION 38: Hardening migration 20260809000001 (agent I-31)
--   38a. FORCE ROW LEVEL SECURITY on all 31 RLS-enabled tables
--        (30 from 20260510000001 §6 + signup_tracker, re-asserted).
--        relforcerowsecurity mirrors D-04's signup_tracker pattern (Section 6).
--   38b. SET search_path = '' on all 12 hardened SECURITY DEFINER
--        functions — asserted via pg_proc.proconfig containing 'search_path='.
--   38c. service_role BYPASSRLS — FORCE RLS must NOT lock out the admin CLI
--        (Go + SUPABASE_SERVICE_ROLE_KEY via PostgREST as service_role;
--        bypassrls granted by the supabase/postgres image's baked-in
--        00-initial-schema.sql, verified against upstream at commit 8d3216973).
-- ============================================================

-- 38a: FORCE ROW LEVEL SECURITY
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'users'::regclass),
    'users has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'user_cosmetics'::regclass),
    'user_cosmetics has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'cosmetics'::regclass),
    'cosmetics has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'group_cosmetics'::regclass),
    'group_cosmetics has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'friendships'::regclass),
    'friendships has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'groups'::regclass),
    'groups has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'group_members'::regclass),
    'group_members has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'group_shard_contributions'::regclass),
    'group_shard_contributions has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'group_rank_snapshots'::regclass),
    'group_rank_snapshots has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'events'::regclass),
    'events has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'event_hosts'::regclass),
    'event_hosts has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'event_invites'::regclass),
    'event_invites has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'event_attendances'::regclass),
    'event_attendances has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'event_photos'::regclass),
    'event_photos has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'event_photo_likes'::regclass),
    'event_photo_likes has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'chats'::regclass),
    'chats has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'messages'::regclass),
    'messages has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'chat_participants'::regclass),
    'chat_participants has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'shard_ledger'::regclass),
    'shard_ledger has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'preshard_ledger'::regclass),
    'preshard_ledger has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'minigame_sessions'::regclass),
    'minigame_sessions has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'notifications'::regclass),
    'notifications has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'feature_requests'::regclass),
    'feature_requests has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'reports'::regclass),
    'reports has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'app_config'::regclass),
    'app_config has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'admin_users'::regclass),
    'admin_users has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'admin_audit_log'::regclass),
    'admin_audit_log has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'subscription_overrides'::regclass),
    'subscription_overrides has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'processed_webhooks'::regclass),
    'processed_webhooks has FORCE ROW LEVEL SECURITY (migration 20260809000001)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'signup_tracker'::regclass),
    'signup_tracker has FORCE ROW LEVEL SECURITY (migration 20260809000001 re-assertion)'
);

-- 38b: SECURITY DEFINER functions hardened with SET search_path = ''
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'update_group_size_tier'),
    'update_group_size_tier sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'set_dynamic_qr_enabled'),
    'set_dynamic_qr_enabled sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'enforce_message_cap'),
    'enforce_message_cap sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'increment_group_shards'),
    'increment_group_shards sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'update_photo_likes_count'),
    'update_photo_likes_count sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'dispatch_shard_distribution'),
    'dispatch_shard_distribution sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'hard_delete_expired_users'),
    'hard_delete_expired_users sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'donate_shards_to_group'),
    'donate_shards_to_group sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'grant_shards'),
    'grant_shards sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'grant_preshards'),
    'grant_preshards sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'distribute_shards'),
    'distribute_shards sets search_path = '''' (migration 20260809000001)'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'recalculate_ranks'),
    'recalculate_ranks sets search_path = '''' (migration 20260809000001)'
);

-- 38c: service_role BYPASSRLS — admin CLI keeps bypassing RLS under FORCE
SELECT ok(
    (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'service_role'),
    'service_role has BYPASSRLS — FORCE RLS does not lock out admin (migration 20260809000001)'
);

-- ============================================================
-- SECTION 39: RLS audit fixes migration 20260809000002 (agent I-32)
--   39a. G-03 users UPDATE mass-assignment: column-level REVOKE UPDATE on
--        the 7 protected columns (personal_shards, preshards,
--        subscription_tier, subscription_expires_at, banned_at, ban_reason,
--        date_of_birth). PostgREST-safe standard approach — RLS policies
--        cannot restrict columns. REVOKE'd from authenticated + anon.
--   39b. assert_safe_user_update_trigger + function. SECURITY INVOKER on
--        purpose: SECURITY DEFINER would set current_user = postgres
--        (superuser) and the BYPASSRLS/superuser gate would always pass —
--        the trigger would never block anyone.
--   39c. Admin RPCs no longer PUBLIC-EXECUTABLE: grant_shards,
--        grant_preshards, distribute_shards, recalculate_ranks,
--        hard_delete_expired_users were SECURITY DEFINER with default
--        PUBLIC EXECUTE → any anon/authenticated caller could mint shards
--        or drain event pools via PostgREST. Now service_role only
--        (pg_cron runs as postgres — unaffected).
--   39d. Server-managed groups/events columns revoked from authenticated:
--        groups INSERT (group_shards, size_tier, frozen_at) + UPDATE
--        (group_shards, size_tier, frozen_at, rank_bracket); events UPDATE
--        (preshards_distributed, featured, featured_until).
--   39e. user_search_view anon SELECT revoked (authenticated search only).
--   39f. Recreated/added policies asserted via policies_are (Section
--        17/18/26 lists updated in place).
-- ============================================================

-- 39a: users protected columns carry no column-level grants. NOTE: the
-- image's default privileges grant TABLE-level UPDATE to authenticated, so
-- has_column_privilege() still resolves UPDATE — the real enforcement for
-- the protected columns is assert_safe_user_update() (39b), which rejects
-- changes by non-privileged roles. Table-level grant cleanup is an S-03 item.
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.users'::regclass AND a.attname = 'personal_shards'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'users.personal_shards has no column-level UPDATE grant (G-03; trigger is the enforcement)');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.users'::regclass AND a.attname = 'preshards'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'users.preshards has no column-level UPDATE grant (G-03; trigger is the enforcement)');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.users'::regclass AND a.attname = 'subscription_tier'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'users.subscription_tier has no column-level UPDATE grant (G-03; trigger is the enforcement)');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.users'::regclass AND a.attname = 'subscription_expires_at'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'users.subscription_expires_at has no column-level UPDATE grant (G-03; trigger is the enforcement)');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.users'::regclass AND a.attname = 'banned_at'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'users.banned_at has no column-level UPDATE grant (G-03; trigger is the enforcement)');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.users'::regclass AND a.attname = 'ban_reason'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'users.ban_reason has no column-level UPDATE grant (G-03; trigger is the enforcement)');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.users'::regclass AND a.attname = 'date_of_birth'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'users.date_of_birth has no column-level UPDATE grant (G-03; trigger is the enforcement)');

-- 39b: assert_safe_user_update trigger + function
SELECT has_trigger('users', 'assert_safe_user_update_trigger',
    'users has assert_safe_user_update_trigger (migration 20260809000002)');
SELECT has_function('public', 'assert_safe_user_update', ARRAY[]::text[],
    'assert_safe_user_update() exists (migration 20260809000002)');
SELECT ok(
    (SELECT NOT prosecdef FROM pg_proc WHERE proname = 'assert_safe_user_update'),
    'assert_safe_user_update is SECURITY INVOKER (gate must see the real caller)'
);

-- 39c: admin RPC EXECUTE lockdown (REVOKE PUBLIC / GRANT service_role)
SELECT function_privs_are('public', 'grant_shards', ARRAY['uuid', 'integer', 'text']::name[], 'public', ARRAY[]::name[],
    'grant_shards is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT function_privs_are('public', 'grant_shards', ARRAY['uuid', 'integer', 'text']::name[], 'service_role', ARRAY['EXECUTE'],
    'grant_shards is service_role-EXECUTABLE');
SELECT function_privs_are('public', 'grant_preshards', ARRAY['uuid', 'integer', 'text']::name[], 'public', ARRAY[]::name[],
    'grant_preshards is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT function_privs_are('public', 'grant_preshards', ARRAY['uuid', 'integer', 'text']::name[], 'service_role', ARRAY['EXECUTE'],
    'grant_preshards is service_role-EXECUTABLE');
SELECT function_privs_are('public', 'distribute_shards', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'distribute_shards is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT function_privs_are('public', 'distribute_shards', ARRAY['uuid']::name[], 'service_role', ARRAY['EXECUTE'],
    'distribute_shards is service_role-EXECUTABLE');
SELECT function_privs_are('public', 'recalculate_ranks', ARRAY['text']::name[], 'public', ARRAY[]::name[],
    'recalculate_ranks is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT function_privs_are('public', 'recalculate_ranks', ARRAY['text']::name[], 'service_role', ARRAY['EXECUTE'],
    'recalculate_ranks is service_role-EXECUTABLE');
SELECT function_privs_are('public', 'hard_delete_expired_users', ARRAY[]::text[]::name[], 'public', ARRAY[]::name[],
    'hard_delete_expired_users is not PUBLIC-EXECUTABLE (migration 20260809000002)');
SELECT function_privs_are('public', 'hard_delete_expired_users', ARRAY[]::text[]::name[], 'service_role', ARRAY['EXECUTE'],
    'hard_delete_expired_users is service_role-EXECUTABLE');

-- 39d: server-managed groups/events columns carry no column-level grants;
-- enforcement is the assert_safe_group_update/assert_safe_event_update
-- triggers (migration 20260811000001 — table-level grants from the image
-- defaults make column REVOKEs ineffective, so the triggers reject
-- changes to the server-managed columns by non-privileged roles).
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.groups'::regclass AND a.attname = 'group_shards'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*a'))),
    'groups.group_shards has no column-level INSERT grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.groups'::regclass AND a.attname = 'size_tier'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*a'))),
    'groups.size_tier has no column-level INSERT grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.groups'::regclass AND a.attname = 'frozen_at'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*a'))),
    'groups.frozen_at has no column-level INSERT grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.groups'::regclass AND a.attname = 'group_shards'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'groups.group_shards has no column-level UPDATE grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.groups'::regclass AND a.attname = 'size_tier'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'groups.size_tier has no column-level UPDATE grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.groups'::regclass AND a.attname = 'frozen_at'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'groups.frozen_at has no column-level UPDATE grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.groups'::regclass AND a.attname = 'rank_bracket'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'groups.rank_bracket has no column-level UPDATE grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.events'::regclass AND a.attname = 'preshards_distributed'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'events.preshards_distributed has no column-level UPDATE grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.events'::regclass AND a.attname = 'featured'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'events.featured has no column-level UPDATE grant');
SELECT ok(
    (SELECT NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = 'public.events'::regclass AND a.attname = 'featured_until'
          AND a.attacl IS NOT NULL
          AND EXISTS (SELECT 1 FROM unnest(a.attacl) AS c(i) WHERE c.i::text ~ '^authenticated=[A-Za-z]*w'))),
    'events.featured_until has no column-level UPDATE grant');

-- 39g: server-managed groups/events triggers (migration 20260811000001)
SELECT has_trigger('groups', 'assert_safe_group_update_trigger',
    'groups has assert_safe_group_update_trigger (migration 20260811000001)');
SELECT has_trigger('events', 'assert_safe_event_update_trigger',
    'events has assert_safe_event_update_trigger (migration 20260811000001)');

-- 39e: user_search_view is server-RPC-only (Q8: no directory enumeration)
SELECT ok(
    NOT has_table_privilege('anon', 'public.user_search_view', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.user_search_view', 'SELECT'),
    'user_search_view is not SELECT-able by anon/authenticated (Q8 RPC-only)');
SELECT ok(
    has_table_privilege('service_role', 'public.user_search_view', 'SELECT'),
    'service_role keeps SELECT on user_search_view');

-- 39f: policy sets asserted in Sections 17/18/26 (updated lists)

-- ============================================================
-- SECTION 41: E2EE prekey table + fetch RPC (migration 20260809000003,
-- agent I-38) — table, own-row RLS, FORCE RLS, index, SECURITY DEFINER
-- RPC with SET search_path = '' and authenticated-only EXECUTE.
-- ============================================================
SELECT has_table('e2ee_identity_keys',
    'e2ee_identity_keys exists (migration 20260809000003)');
SELECT has_column('e2ee_identity_keys', 'user_id');
SELECT has_column('e2ee_identity_keys', 'identity_key');
SELECT has_column('e2ee_identity_keys', 'identity_sig_key');
SELECT has_column('e2ee_identity_keys', 'signed_prekey_id');
SELECT has_column('e2ee_identity_keys', 'signed_prekey');
SELECT has_column('e2ee_identity_keys', 'signed_prekey_sig');
SELECT has_column('e2ee_identity_keys', 'signed_prekey_expires_at');
SELECT has_column('e2ee_identity_keys', 'one_time_prekeys');
SELECT has_column('e2ee_identity_keys', 'consumed_one_time_prekeys');
SELECT has_column('e2ee_identity_keys', 'updated_at');
SELECT col_is_pk('e2ee_identity_keys', 'user_id',
    'e2ee_identity_keys.user_id is the primary key');
SELECT col_type_is('e2ee_identity_keys', 'identity_key', 'text',
    'identity_key is text (base64url X25519 public)');
SELECT col_type_is('e2ee_identity_keys', 'one_time_prekeys', 'jsonb',
    'one_time_prekeys is jsonb');
SELECT col_not_null('e2ee_identity_keys', 'user_id');
SELECT col_not_null('e2ee_identity_keys', 'identity_key');
SELECT col_not_null('e2ee_identity_keys', 'identity_sig_key');
SELECT col_not_null('e2ee_identity_keys', 'signed_prekey_id');
SELECT col_not_null('e2ee_identity_keys', 'signed_prekey');
SELECT col_not_null('e2ee_identity_keys', 'signed_prekey_sig');
SELECT col_not_null('e2ee_identity_keys', 'signed_prekey_expires_at');
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'e2ee_identity_keys'::regclass),
    'e2ee_identity_keys has RLS enabled'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'e2ee_identity_keys'::regclass),
    'e2ee_identity_keys has FORCE ROW LEVEL SECURITY (migration 20260809000003)'
);
SELECT policies_are('e2ee_identity_keys', ARRAY[
    'e2ee_identity_keys_select_own',
    'e2ee_identity_keys_insert_own',
    'e2ee_identity_keys_update_own',
    'e2ee_identity_keys_delete_own'
], 'e2ee_identity_keys has own-row (user_id = auth.uid()) RLS policies');
SELECT has_index('e2ee_identity_keys', 'e2ee_identity_keys_user_id_idx',
    'e2ee_identity_keys has an index on user_id');
SELECT has_function('fetch_prekey_bundle', ARRAY['uuid'],
    'fetch_prekey_bundle(p_user_id uuid) exists (SECURITY DEFINER RPC)');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'fetch_prekey_bundle'),
    'fetch_prekey_bundle sets search_path = '''' (migration 20260809000003)'
);
SELECT function_privs_are('public', 'fetch_prekey_bundle', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'fetch_prekey_bundle is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'fetch_prekey_bundle', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'fetch_prekey_bundle is authenticated-EXECUTABLE');
SELECT is(
    (SELECT relreplident FROM pg_class WHERE oid = 'public.messages'::regclass),
    'f',
    'messages has REPLICA IDENTITY FULL (realtime full-row delivery, E2EE §9.3)'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'messages'
    ),
    'messages is in the supabase_realtime publication (E2EE §9.3)'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'friendships'
    ),
    'friendships is in the supabase_realtime publication (friendships realtime, 20260815000002)'
);

-- ============================================================
-- SECTION 43: Party Finder discovery (migration 20260809000004,
-- agent I-60) — users.interest_tags + users.discovery_opt_in (user-owned,
-- self-editable), discovery_view security-barrier view (authenticated only).
--   43a. Columns exist with the right type/default/NOT NULL.
--   43b. Trigger/REVOKE interplay (documented decision): the two columns are
--        deliberately NOT in assert_safe_user_update()'s protected set nor in
--        the I-32 column-level REVOKE UPDATE list → authenticated keeps
--        UPDATE (users_update_own, id = auth.uid()) so the opt-in toggle and
--        tags editor persist. Asserted via has_column_priv (UPDATE = true).
--   43c. discovery_view: security barrier, exact column projection
--        (id, username, avatar_url, interest_tags), authenticated SELECT
--        only (anon revoked — no pre-auth enumeration, mirrors I-32 §13).
-- ============================================================

-- 43a: columns + defaults
SELECT has_column('users', 'interest_tags',
    'users.interest_tags exists (migration 20260809000004)');
SELECT has_column('users', 'discovery_opt_in',
    'users.discovery_opt_in exists (migration 20260809000004)');
SELECT col_type_is('users', 'interest_tags', 'text[]',
    'users.interest_tags is text[]');
SELECT col_type_is('users', 'discovery_opt_in', 'boolean',
    'users.discovery_opt_in is boolean');
SELECT col_not_null('users', 'interest_tags',
    'users.interest_tags is NOT NULL');
SELECT col_not_null('users', 'discovery_opt_in',
    'users.discovery_opt_in is NOT NULL');
SELECT ok(
    (SELECT pg_get_expr(adbin, adrelid)::text = '''{}''::text[]'
     FROM pg_catalog.pg_attrdef d
     JOIN pg_catalog.pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE a.attrelid = 'users'::regclass AND a.attname = 'interest_tags'),
    'users.interest_tags defaults to the empty array (opt-in by default)');
SELECT col_default_is('users', 'discovery_opt_in', 'false',
    'users.discovery_opt_in defaults to false (discovery OFF by default)');

-- 43b: user-owned columns moved behind RPCs (2026-08-25 profile-RPC
-- lockdown): clients lost table/column UPDATE entirely — discovery_opt_in is
-- mutated through set_discovery_opt_in(), interest_tags has no client setter
-- (no writers exist). The UPDATE-able pins from the PFND era are inverted.
SELECT ok(
    NOT has_column_privilege('authenticated', 'public.users', 'interest_tags', 'UPDATE'),
    'users.interest_tags is NOT UPDATE-able by authenticated (RPC lockdown 2026-08-25)');
SELECT ok(
    NOT has_column_privilege('authenticated', 'public.users', 'discovery_opt_in', 'UPDATE'),
    'users.discovery_opt_in is NOT UPDATE-able by authenticated (mutated via set_discovery_opt_in)');

-- 43c: discovery_view
SELECT has_view('discovery_view',
    'discovery_view exists (migration 20260809000004)');
SELECT columns_are('discovery_view',
    ARRAY['id', 'username', 'avatar_url', 'interest_tags'],
    'discovery_view exposes only id, username, avatar_url, interest_tags');
SELECT ok(
    has_table_privilege('authenticated', 'public.discovery_view', 'SELECT'),
    'discovery_view is SELECT-able by authenticated');
SELECT ok(
    NOT has_table_privilege('anon', 'public.discovery_view', 'SELECT'),
    'discovery_view is not SELECT-able by anon (no pre-auth enumeration)');
SELECT ok(
    (SELECT 'security_barrier=true' = ANY (c.reloptions)
     FROM pg_class c WHERE c.oid = 'discovery_view'::regclass),
    'discovery_view is a security_barrier view (no predicate-pushdown leaks)'
);

-- ============================================================
-- SECTION 45: create_minigame_session RPC (migration 20260809000006,
-- agent I-63 + 140_minigame_invites 2026-08-26) — GMCR/GWAG foundation:
-- SECURITY DEFINER + SET search_path = '' (I-31 pattern), membership gate
-- via the I-32 is_group_member helper, atomic wager deduct + minigame_wager
-- ledger + session insert (escrow contract, GWAG), business outcomes
-- returned as jsonb statuses, PUBLIC EXECUTE revoked, authenticated-only
-- EXECUTE. The invite-aware 4-arg overload (p_invitees uuid[]) replaces the
-- 3-arg baseline: per-invitee blocked/deleted + friends-only privacy gates
-- and one minigame_invites row per invitee, all atomic.
-- ============================================================
SELECT has_function('create_minigame_session', ARRAY['uuid', 'text', 'integer', 'uuid[]', 'text', 'integer', 'integer', 'text', 'boolean', 'integer', 'timestamp with time zone'],
    'create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text, p_rounds integer, p_prize_positions integer, p_play_mode text, p_anonymous boolean, p_async_rounds_per_player integer, p_async_ends_at timestamp with time zone) exists (202_minigame_play_v2)');
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'create_minigame_session' AND pronargs = 3
    ),
    'the pre-invite 3-arg create_minigame_session overload is dropped (CREATE OR REPLACE cannot change the arg list)'
);
SELECT ok(
    (SELECT prosecdef FROM pg_proc WHERE proname = 'create_minigame_session'),
    'create_minigame_session is SECURITY DEFINER'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'create_minigame_session'),
    'create_minigame_session sets search_path = '''' (migration 20260809000006)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.is_group_member(p_group_id)%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session references is_group_member'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%minigame_wager%'
       AND pg_get_functiondef(p.oid) LIKE '%public.shard_ledger%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session writes the minigame_wager ledger'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''insufficient_shards''%'
       AND pg_get_functiondef(p.oid) LIKE '%''not_member''%'
       AND pg_get_functiondef(p.oid) LIKE '%''created''%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session returns typed jsonb statuses (I-57 contract)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.minigame_invites%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session writes one minigame_invites row per invitee (140_minigame_invites)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%minigame_invite_friends_only%'
       AND pg_get_functiondef(p.oid) LIKE '%friendships%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session enforces the friends-only invite privacy switch server-side'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''invitee_not_allowed''%'
       AND pg_get_functiondef(p.oid) LIKE '%''invitee_friends_only''%'
       AND pg_get_functiondef(p.oid) LIKE '%''too_many_invitees''%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session returns typed invitee rejection statuses'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%status = ''blocked''::public.friendship_status%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session rejects blocked invitees (either direction)'
);
SELECT function_privs_are('public', 'create_minigame_session', ARRAY['uuid', 'text', 'integer', 'uuid[]', 'text', 'integer', 'integer', 'text', 'boolean', 'integer', 'timestamp with time zone']::name[], 'public', ARRAY[]::name[],
    'create_minigame_session is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'create_minigame_session', ARRAY['uuid', 'text', 'integer', 'uuid[]', 'text', 'integer', 'integer', 'text', 'boolean', 'integer', 'timestamp with time zone']::name[], 'authenticated', ARRAY['EXECUTE'],
    'create_minigame_session is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%player_limit%'
       AND pg_get_functiondef(p.oid) LIKE '%app_config%'
       AND pg_get_functiondef(p.oid) LIKE '%array_length%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session computes the player cap from the creator subscription tier via app_config'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%minigame.free_max_players%'
       AND pg_get_functiondef(p.oid) LIKE '%minigame.pro_max_players%'
       AND pg_get_functiondef(p.oid) LIKE '%minigame.vip_max_players%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session computes the player cap from the creator subscription tier via app_config'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''player_limit_reached''%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session rejects over-cap rosters with player_limit_reached'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%player_limit%'
       AND pg_get_functiondef(p.oid) LIKE '%INSERT INTO public.minigame_sessions%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session stores the frozen player_limit on the session row'
);

-- ============================================================
-- SECTION 46: Static trigger/constraint/RPC contract (agent I-77,
-- I-76 handoff + I-31/I-32/I-38/I-57/I-63 regression net)
--   46a. Trigger→function bindings (trigger_is) for all 9 triggers from
--        migration 20260510000001 §5 (existence already asserted in
--        Section 8; binding guards against a trigger pointing at the
--        wrong function after a CREATE OR REPLACE).
--   46b. Trigger-function BODY contract (pg_get_functiondef LIKE, I-63
--        Section 45 pattern) — the static equivalent of the behavioral
--        coverage that opt-002/003/004 delegate to pgTAP: message_cap
--        reads app_config chat.message_cap with the 1000 fallback,
--        dynamic_qr derives the flag from preshards_pool in both
--        branches, likes-count recomputes from event_photo_likes.
--   46c. Constraints: check_casual_no_preshards + group_members_status_check
--        (name-anchored pg_constraint checks — pgTAP has_check() only
--        asserts "some check exists", not the name/table) and the UNIQUE
--        column pairs (col_is_unique) that opt-002/004 exercise
--        (event_photo_likes(photo_id,user_id) → 23505, group_members
--        (group_id,user_id), events.invite_token, ...).
--   46d. e2ee_identity_keys full structure (completes Section 41):
--        exact column projection + types + jsonb defaults; fetch_prekey_bundle
--        SECURITY DEFINER (is_definer — Section 41 asserts search_path +
--        grants only).
--   46e. RPC completeness: is_group_member helper
--        (20260809000002 §11.1) existence + SECURITY DEFINER + STABLE +
--        search_path hardening (used by create_minigame_session and
--        group_members_read_same). (The legacy QR-token prosecdef check that
--        lived here was removed 2026-09-08 with the static QR-token surface —
--        the code family's posture is pinned in Section 21d.)
-- ============================================================

-- 46a: trigger → function bindings
SELECT trigger_is('public', 'users', 'users_updated_at', 'extensions', 'moddatetime',
    'users_updated_at fires extensions.moddatetime');
SELECT trigger_is('public', 'groups', 'groups_updated_at', 'extensions', 'moddatetime',
    'groups_updated_at fires extensions.moddatetime');
SELECT trigger_is('public', 'events', 'events_updated_at', 'extensions', 'moddatetime',
    'events_updated_at fires extensions.moddatetime');
SELECT trigger_is('public', 'group_members', 'group_size_tier_trigger', 'public', 'update_group_size_tier',
    'group_size_tier_trigger fires update_group_size_tier');
SELECT trigger_is('public', 'events', 'dynamic_qr_enabled_trigger', 'public', 'set_dynamic_qr_enabled',
    'dynamic_qr_enabled_trigger fires set_dynamic_qr_enabled');
SELECT trigger_is('public', 'messages', 'message_cap_trigger', 'public', 'enforce_message_cap',
    'message_cap_trigger fires enforce_message_cap');
SELECT trigger_is('public', 'group_shard_contributions', 'group_shards_increment_trigger', 'public', 'increment_group_shards',
    'group_shards_increment_trigger fires increment_group_shards');
SELECT trigger_is('public', 'event_photo_likes', 'photo_likes_count_trigger', 'public', 'update_photo_likes_count',
    'photo_likes_count_trigger fires update_photo_likes_count');
SELECT trigger_is('public', 'events', 'shard_distribution_dispatch_trigger', 'public', 'dispatch_shard_distribution',
    'shard_distribution_dispatch_trigger fires dispatch_shard_distribution');

-- 46b: trigger-function bodies (static behavioral contract)
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.app_config%'
       AND pg_get_functiondef(p.oid) LIKE '%chat.message_cap%'
       AND pg_get_functiondef(p.oid) LIKE '%1000%'
     FROM pg_proc p WHERE proname = 'enforce_message_cap'),
    'enforce_message_cap reads app_config chat.message_cap with 1000 fallback (I-76 full-cap contract)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%NEW.dynamic_qr_enabled = (NEW.preshards_pool > 0)%'
     FROM pg_proc p WHERE proname = 'set_dynamic_qr_enabled'),
    'set_dynamic_qr_enabled derives dynamic_qr_enabled from preshards_pool (both INSERT and UPDATE branches)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%UPDATE public.event_photos SET likes_count = (%'
       AND pg_get_functiondef(p.oid) LIKE '%SELECT COUNT(*) FROM public.event_photo_likes WHERE photo_id = target_photo_id%'
     FROM pg_proc p WHERE proname = 'update_photo_likes_count'),
    'update_photo_likes_count recomputes likes_count from event_photo_likes (count accuracy)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%UPDATE public.groups SET size_tier = CASE%'
       AND pg_get_functiondef(p.oid) LIKE '%member_count >= 257%'
       AND pg_get_functiondef(p.oid) LIKE '%member_count >= 15%'
     FROM pg_proc p WHERE proname = 'update_group_size_tier'),
    'update_group_size_tier maps member_count to size_tier thresholds (large 257+ / small 15+)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%UPDATE public.groups SET group_shards = group_shards + NEW.shards_contributed%'
     FROM pg_proc p WHERE proname = 'increment_group_shards'),
    'increment_group_shards adds shards_contributed to groups.group_shards'
);

-- 46c: constraints
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'events'::regclass
          AND conname = 'check_casual_no_preshards'
          AND contype = 'c'
    ),
    'events has check_casual_no_preshards (casual events cannot carry a preshards pool, opt-002 TEST B)'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'group_members'::regclass
          AND conname = 'group_members_status_check'
          AND contype = 'c'
    ),
    'group_members has group_members_status_check (status IN active/invited, migration 20260512000011)'
);
SELECT col_is_unique('event_photo_likes', ARRAY['photo_id', 'user_id'],
    'event_photo_likes has UNIQUE (photo_id, user_id) — duplicate likes are 23505 (opt-004 TEST D)');
SELECT col_is_unique('group_members', ARRAY['group_id', 'user_id'],
    'group_members has UNIQUE (group_id, user_id)');
SELECT col_is_unique('event_attendances', ARRAY['event_id', 'user_id'],
    'event_attendances has UNIQUE (event_id, user_id)');
SELECT col_is_unique('user_cosmetics', ARRAY['user_id', 'cosmetic_id'],
    'user_cosmetics has UNIQUE (user_id, cosmetic_id)');
SELECT col_is_unique('event_hosts', ARRAY['event_id', 'user_id'],
    'event_hosts has UNIQUE (event_id, user_id) (opt-002 host contract)');
SELECT col_is_unique('event_invites', ARRAY['event_id', 'user_id'],
    'event_invites has UNIQUE (event_id, user_id)');
SELECT col_is_unique('chat_participants', ARRAY['chat_id', 'user_id'],
    'chat_participants has UNIQUE (chat_id, user_id)');
SELECT col_is_unique('group_cosmetics', ARRAY['group_id', 'cosmetic_id'],
    'group_cosmetics has UNIQUE (group_id, cosmetic_id)');
SELECT col_is_unique('events', 'invite_token',
    'events.invite_token is UNIQUE (invite links, opt-002 TEST A)');

-- 46d: e2ee_identity_keys structure (completes Section 41)
SELECT columns_are('e2ee_identity_keys', ARRAY[
    'user_id', 'identity_key', 'identity_sig_key', 'signed_prekey_id',
    'signed_prekey', 'signed_prekey_sig', 'signed_prekey_expires_at',
    'one_time_prekeys', 'consumed_one_time_prekeys', 'updated_at'
], 'e2ee_identity_keys exposes exactly the 10 X3DH columns (migration 20260809000003)');
SELECT col_type_is('e2ee_identity_keys', 'user_id', 'uuid',
    'e2ee_identity_keys.user_id is uuid (FK to users.id)');
SELECT col_type_is('e2ee_identity_keys', 'identity_sig_key', 'text',
    'identity_sig_key is text (base64url Ed25519)');
SELECT col_type_is('e2ee_identity_keys', 'signed_prekey_id', 'integer',
    'signed_prekey_id is integer (spk_id carried by init envelopes)');
SELECT col_type_is('e2ee_identity_keys', 'signed_prekey', 'text',
    'signed_prekey is text (base64url X25519 signed prekey)');
SELECT col_type_is('e2ee_identity_keys', 'signed_prekey_sig', 'text',
    'signed_prekey_sig is text (Ed25519 sig over signed_prekey)');
SELECT col_type_is('e2ee_identity_keys', 'signed_prekey_expires_at', 'timestamptz',
    'signed_prekey_expires_at is timestamptz');
SELECT col_type_is('e2ee_identity_keys', 'consumed_one_time_prekeys', 'jsonb',
    'consumed_one_time_prekeys is jsonb (audit trail)');
SELECT col_type_is('e2ee_identity_keys', 'updated_at', 'timestamptz',
    'updated_at is timestamptz');
SELECT ok(
    (SELECT pg_get_expr(adbin, adrelid)::text = '''[]''::jsonb'
     FROM pg_catalog.pg_attrdef d
     JOIN pg_catalog.pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE a.attrelid = 'e2ee_identity_keys'::regclass AND a.attname = 'one_time_prekeys'),
    'one_time_prekeys defaults to the empty array');
SELECT ok(
    (SELECT pg_get_expr(adbin, adrelid)::text = '''[]''::jsonb'
     FROM pg_catalog.pg_attrdef d
     JOIN pg_catalog.pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE a.attrelid = 'e2ee_identity_keys'::regclass AND a.attname = 'consumed_one_time_prekeys'),
    'consumed_one_time_prekeys defaults to the empty array');
SELECT is_definer('public', 'fetch_prekey_bundle', ARRAY['uuid'],
    'fetch_prekey_bundle is SECURITY DEFINER');

-- 46e: RPC completeness
SELECT has_function('is_group_member', ARRAY['uuid'],
    'is_group_member(p_group_id uuid) exists (migration 20260809000002 §11.1)');
SELECT is_definer('public', 'is_group_member', ARRAY['uuid'],
    'is_group_member is SECURITY DEFINER (RLS-recursion-safe helper)');
SELECT volatility_is('public', 'is_group_member', ARRAY['uuid'], 'stable',
    'is_group_member is STABLE (usable inside RLS policies)');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'is_group_member'),
    'is_group_member sets search_path = '''' (migration 20260809000002)'
);

-- ============================================================
-- SECTION 47: Storage buckets + storage.objects RLS (agent M-08,
-- migration 20260810000007 — S-09/M-track bucket-creation gap closure)
--   47a. The storage schema tables exist — storage.buckets /
--        storage.objects are created by the storage-api tenant migrations
--        (0002/0007/0008, all present in the pinned storage-api v1.60.4),
--        NOT by the app migrations; the bucket rows + objects RLS policies
--        below are what 20260810000007 adds. has_table with an explicit
--        schema also guards against the storage schema being dropped.
--   47b. Bucket rows exist with the exact public flags: avatars=true,
--        groups=true (public reads via getPublicUrl), events=false (private
--        — PHUP signed-URL retrieval only).
--   47c. storage.objects RLS is enabled (relrowsecurity) and the five
--        migration policies are present under their exact names
--        (policies_are).
-- ============================================================

-- 47a: storage schema tables
SELECT has_table('storage', 'buckets',
    'storage.buckets exists (storage-api tenant schema, asserted by M-08)');
SELECT has_table('storage', 'objects',
    'storage.objects exists (storage-api tenant schema, asserted by M-08)');

-- 47b: bucket rows + public flags (migration 20260810000007 §1)
SELECT results_eq(
    'SELECT id FROM storage.buckets WHERE id IN (''avatars'', ''groups'', ''events'') ORDER BY id',
    ARRAY['avatars', 'events', 'groups']::text[],
    'avatars/groups/events bucket rows exist (migration 20260810000007)'
);
SELECT ok(
    (SELECT public FROM storage.buckets WHERE id = 'avatars'),
    'avatars bucket is public=true (app reads avatars via getPublicUrl)'
);
SELECT ok(
    (SELECT public FROM storage.buckets WHERE id = 'groups'),
    'groups bucket is public=true (app reads group covers via getPublicUrl)'
);
SELECT ok(
    NOT (SELECT public FROM storage.buckets WHERE id = 'events'),
    'events bucket is public=false (private — PHUP signed-URL retrieval only)'
);

-- 47c: objects RLS enabled + exact policy set
SELECT ok(
    (SELECT relrowsecurity FROM pg_catalog.pg_class
     WHERE oid = 'storage.objects'::regclass),
    'storage.objects has ROW LEVEL SECURITY enabled (storage-api 0002)'
);
SELECT policies_are('storage', 'objects', ARRAY[
    'storage_objects_delete_own',
    'storage_objects_events_select_access',
    'storage_objects_insert_own',
    'storage_objects_public_read_avatars_groups',
    'storage_objects_update_own',
    'storage_objects_minigame_images_select',
    'storage_objects_minigame_images_insert'
], 'storage.objects has exactly the 7 policies (public read avatars/groups, events select-access, minigame-images select/insert, own insert/update/delete)');

-- ============================================================
-- SECTION 48: Function EXECUTE hardening (20260811000001)
-- The supabase image's default privileges granted anon EXECUTE on every
-- function created by postgres/supabase_admin in public; prior per-function
-- REVOKE ... FROM PUBLIC only removed the PUBLIC entry. Section asserts the
-- hardened posture (anon excluded everywhere except the two intended cases).
-- ============================================================

SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prosecdef
       AND has_function_privilege('anon', p.oid, 'EXECUTE')
       AND p.proname NOT IN ('check_signup_email', 'is_group_member', 'is_chat_participant', 'upsert_signup_tracker')) = 0,
    'anon cannot EXECUTE any SECURITY DEFINER function (except check_signup_email + is_group_member + is_chat_participant + upsert_signup_tracker)'
);

SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_default_acl d
     JOIN pg_roles r ON r.oid = d.defaclrole
     JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
     WHERE n.nspname = 'public'
       AND r.rolname IN ('postgres', 'supabase_admin')
       AND d.defaclobjtype = 'f'
       AND d.defaclacl::text LIKE '%anon=X%') = 0,
    'public-schema default privileges no longer grant anon EXECUTE on functions (20260811000001)'
);

SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('donate_shards_to_group', 'fetch_prekey_bundle',
                         'validate_code', 'create_minigame_session',
                         'join_minigame_session', 'abandon_minigame_game')
       AND has_function_privilege('authenticated', p.oid, 'EXECUTE')) = 6,
    'authenticated can EXECUTE the 6 client RPCs (finish is server-only; abandon is the client path)'
);

SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('grant_shards', 'grant_preshards', 'distribute_shards',
                         'recalculate_ranks', 'hard_delete_expired_users')
       AND has_function_privilege('service_role', p.oid, 'EXECUTE')) = 5,
    'service_role can EXECUTE the 5 admin RPCs'
);

SELECT ok(
    has_function_privilege('anon', 'public.check_signup_email(text)', 'EXECUTE'),
    'check_signup_email remains anon-callable (pre-auth email check, by design)'
);

SELECT ok(
    has_function_privilege('anon', 'public.is_group_member(uuid)', 'EXECUTE'),
    'is_group_member remains anon-callable (invoked from RLS policies)'
);

-- donate_shards_to_group NULL-uid guard: unauthenticated sessions have
-- auth.uid() = NULL; the old `auth.uid() != p_user_id` guard evaluated NULL
-- (not TRUE) and silently passed. Setting empty jwt claims reproduces it.
SELECT set_config('request.jwt.claims', '{}', true);
SELECT throws_ok($$SELECT public.donate_shards_to_group('00000000-0000-0000-0000-000000000000'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 50, '2026-12-31T23:59:59Z')$$,
    'P0001', 'Not authorized',
    'donate_shards_to_group NULL-uid guard raises Not authorized (20260811000001)');

-- ============================================================
-- SECTION 49: join/finish minigame session RPCs (migration
-- 20260813000001, agent R4) — closes the I-77/S-03 server RPC gap:
-- join_minigame_session (session-exists + is_group_member gate, idempotent
-- participants append, escrow deduction mirroring create_minigame_session)
-- and finish_minigame_session (winner pot credit via minigame_win ledger /
-- draw refunds via minigame_refund, status='finished' + winner_id). Both
-- are SECURITY DEFINER + SET search_path = '' (I-31 pattern), jsonb status
-- outcomes (I-57 contract), PUBLIC EXECUTE revoked, authenticated-only.
-- ============================================================

-- 49a: join_minigame_session(uuid)
SELECT has_function('join_minigame_session', ARRAY['uuid'],
    'join_minigame_session(p_session_id uuid) exists (migration 20260813000001)');
SELECT ok(
    (SELECT prosecdef FROM pg_proc WHERE proname = 'join_minigame_session'),
    'join_minigame_session is SECURITY DEFINER'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'join_minigame_session'),
    'join_minigame_session sets search_path = '''' (migration 20260813000001)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.is_group_member(v_group_id)%'
     FROM pg_proc p WHERE proname = 'join_minigame_session'),
    'join_minigame_session validates membership via is_group_member'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%minigame_wager%'
       AND pg_get_functiondef(p.oid) LIKE '%public.shard_ledger%'
       AND pg_get_functiondef(p.oid) LIKE '%participants || ARRAY[v_current_user]%'
     FROM pg_proc p WHERE proname = 'join_minigame_session'),
    'join_minigame_session deducts the wager into the minigame_wager ledger and appends the participant'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.minigame_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%''not_allowed''%'
     FROM pg_proc p WHERE proname = 'join_minigame_session'),
    'join_minigame_session gates DIRECT sessions by participant / pending-invite standing (not_allowed)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%array_length(v_participants, 1) >= v_player_limit%'
       AND pg_get_functiondef(p.oid) LIKE '%''player_limit_reached''%'
     FROM pg_proc p WHERE proname = 'join_minigame_session'),
    'join_minigame_session enforces the frozen player cap (player_limit_reached)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''joined''%'
       AND pg_get_functiondef(p.oid) LIKE '%''session_not_found''%'
       AND pg_get_functiondef(p.oid) LIKE '%''session_not_active''%'
       AND pg_get_functiondef(p.oid) LIKE '%''insufficient_shards''%'
     FROM pg_proc p WHERE proname = 'join_minigame_session'),
    'join_minigame_session returns typed jsonb statuses (I-57 contract)'
);
SELECT function_privs_are('public', 'join_minigame_session', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'join_minigame_session is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'join_minigame_session', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'join_minigame_session is authenticated-EXECUTABLE');

-- 49b: finish_minigame_session is REPLACED by finish_minigame_game
-- (201_minigame_voting) — the winner-takes-all + draw settlement seams are
-- dropped; the leaderboard settlement is the one and only path.
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'finish_minigame_session'),
    'finish_minigame_session is dropped (201_minigame_voting replaces it with finish_minigame_game)'
);

-- ============================================================
-- SECTION 49b: Minigame invites (migration 140_minigame_invites,
-- 2026-08-26) — participant select. minigame_invites table (FORCE RLS,
-- invitee+creator read), users.minigame_invite_friends_only privacy switch
-- (default OFF), the RPC family (set_*/accept/decline: SECURITY DEFINER +
-- empty search_path + PUBLIC-revoked + authenticated-EXECUTABLE), the
-- ms_read_invitee session-read policy, and the realtime memberships that
-- deliver invites live to the invitee's notification center.
-- ============================================================
SELECT has_type('mini_game_invite_status',
    'mini_game_invite_status exists (140_minigame_invites)');
SELECT has_table('minigame_invites',
    'minigame_invites exists');
SELECT col_is_unique('minigame_invites', ARRAY['session_id', 'invitee_id'],
    'minigame_invites(session_id, invitee_id) is unique (one invite per player per session)');
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.minigame_invites'::regclass),
    'minigame_invites has RLS ENABLED (140_minigame_invites)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.minigame_invites'::regclass),
    'minigame_invites has FORCE ROW LEVEL SECURITY (140_minigame_invites)'
);
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_class
        WHERE relnamespace = 'public'::regnamespace
          AND relkind = 'r'
          AND relforcerowsecurity
          AND NOT relrowsecurity
    ),
    'every public table with FORCE RLS also has RLS ENABLED (no inert-policy leak)'
);
SELECT policies_are('minigame_invites', ARRAY[
    'mi_read_own',
    'active_users_only'
], 'minigame_invites policies: invitee/creator SELECT only (every write is an RPC contract)');
SELECT has_column('users', 'minigame_invite_friends_only',
    'users.minigame_invite_friends_only exists (invite privacy switch, 140_minigame_invites)');
SELECT ok(
    (SELECT pg_get_expr(adbin, adrelid)::text = 'false'
     FROM pg_attrdef d
     JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE a.attrelid = 'users'::regclass AND a.attname = 'minigame_invite_friends_only'),
    'users.minigame_invite_friends_only defaults to false (non-friends may invite by default)'
);
SELECT has_function('set_minigame_invite_friends_only', ARRAY['boolean'],
    'set_minigame_invite_friends_only(p_value boolean) exists (profile-RPC lockdown)');
SELECT is_definer('public', 'set_minigame_invite_friends_only', ARRAY['boolean']::name[],
    'set_minigame_invite_friends_only is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'set_minigame_invite_friends_only'),
    'set_minigame_invite_friends_only sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'set_minigame_invite_friends_only', ARRAY['boolean']::name[], 'public', ARRAY[]::name[],
    'set_minigame_invite_friends_only is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'set_minigame_invite_friends_only', ARRAY['boolean']::name[], 'authenticated', ARRAY['EXECUTE'],
    'set_minigame_invite_friends_only is authenticated-EXECUTABLE');
SELECT has_function('accept_minigame_invite', ARRAY['uuid'],
    'accept_minigame_invite(p_invite_id uuid) exists');
SELECT is_definer('public', 'accept_minigame_invite', ARRAY['uuid']::name[],
    'accept_minigame_invite is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'accept_minigame_invite'),
    'accept_minigame_invite sets search_path = "" (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''session_finished''%'
       AND pg_get_functiondef(p.oid) LIKE '%participants || ARRAY[v_current_user]%'
     FROM pg_proc p WHERE proname = 'accept_minigame_invite'),
    'accept_minigame_invite rejects finished sessions and appends the participant'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%minigame_wager%'
     FROM pg_proc p WHERE proname = 'accept_minigame_invite'),
    'accept_minigame_invite mirrors the escrow deduction (GWAG)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%array_length(v_participants, 1) >= v_player_limit%'
       AND pg_get_functiondef(p.oid) LIKE '%''player_limit_reached''%'
     FROM pg_proc p WHERE proname = 'accept_minigame_invite'),
    'accept_minigame_invite enforces the frozen player cap (player_limit_reached)'
);
SELECT function_privs_are('public', 'accept_minigame_invite', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'accept_minigame_invite is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'accept_minigame_invite', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'accept_minigame_invite is authenticated-EXECUTABLE');
SELECT has_function('decline_minigame_invite', ARRAY['uuid'],
    'decline_minigame_invite(p_invite_id uuid) exists');
SELECT is_definer('public', 'decline_minigame_invite', ARRAY['uuid']::name[],
    'decline_minigame_invite is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'decline_minigame_invite'),
    'decline_minigame_invite sets search_path = "" (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%DELETE FROM public.minigame_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%invitee_id = v_current_user%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%status = ''''declined''''%'
     FROM pg_proc p WHERE proname = 'decline_minigame_invite'),
    'decline_minigame_invite DELETEs the row (a declined invite is indistinguishable from one that never existed — 2026-09-02 user directive)'
);
SELECT function_privs_are('public', 'decline_minigame_invite', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'decline_minigame_invite is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'decline_minigame_invite', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'decline_minigame_invite is authenticated-EXECUTABLE');
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'notifications'
    ),
    'notifications joins the supabase_realtime publication (GO-realtime invites land live)'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'minigame_invites'
    ),
    'minigame_invites joins the supabase_realtime publication (accept/decline streaming)'
);

-- ============================================================
-- SECTION 49c: Minigame game state (migration 150_minigame_play) —
-- the reusable play engine for all 5 game types (poke_chain, questions,
-- truth_dare, drunk_bottle, challenge). Two tables + five RPCs:
--   * minigame_game_state — one row per minigame session (state jsonb:
--     judge_index/round/phase + game-specific keys, rounds jsonb[]
--     append-only history, updated_at touch trigger), FORCE RLS with the
--     single mgs_read_participant SELECT (session-row-visible check).
--   * minigame_prompts — the generic prompt bank (game_type +
--     prompt_type + category + body), FORCE RLS, mgs_prompts_select
--     (authenticated reads active prompts), seeded es-first content.
--   * get/init/reveal/advance/complete RPCs: SECURITY DEFINER +
--     SET search_path = '' (I-31 pattern), typed jsonb statuses (I-57
--     contract), auth gate first, participant-only gates, PUBLIC EXECUTE
--     revoked + authenticated (+service_role for settle) grants.
--   * minigame_game_state joins supabase_realtime (game state streams live).
-- ============================================================

-- 49c-a: minigame_game_state table shape
SELECT has_table('minigame_game_state',
    'minigame_game_state exists (150_minigame_play)');
SELECT has_table('minigame_prompts',
    'minigame_prompts exists (150_minigame_play)');
SELECT col_is_pk('minigame_game_state', 'session_id',
    'minigame_game_state.session_id is the primary key');
SELECT col_type_is('minigame_game_state', 'session_id', 'uuid',
    'minigame_game_state.session_id is uuid');
SELECT col_type_is('minigame_game_state', 'game_type', 'public.mini_game_type',
    'minigame_game_state.game_type is the mini_game_type enum (denormalized convenience)');
SELECT col_type_is('minigame_game_state', 'state', 'jsonb',
    'minigame_game_state.state is jsonb (game-agnostic play state)');
SELECT col_type_is('minigame_game_state', 'rounds', 'jsonb[]',
    'minigame_game_state.rounds is jsonb[] (append-only round history)');
SELECT col_type_is('minigame_game_state', 'created_at', 'timestamp with time zone',
    'minigame_game_state.created_at is timestamptz');
SELECT col_type_is('minigame_game_state', 'updated_at', 'timestamp with time zone',
    'minigame_game_state.updated_at is timestamptz');
SELECT col_not_null('minigame_game_state', 'session_id',
    'minigame_game_state.session_id is NOT NULL');
SELECT col_not_null('minigame_game_state', 'game_type',
    'minigame_game_state.game_type is NOT NULL');
SELECT col_not_null('minigame_game_state', 'state',
    'minigame_game_state.state is NOT NULL');
SELECT col_not_null('minigame_game_state', 'rounds',
    'minigame_game_state.rounds is NOT NULL');
SELECT col_has_default('minigame_game_state', 'state',
    'minigame_game_state.state defaults to an empty jsonb object');
SELECT col_has_default('minigame_game_state', 'rounds',
    'minigame_game_state.rounds defaults to the empty array');
SELECT fk_ok('minigame_game_state', ARRAY['session_id'::name], 'minigame_sessions', ARRAY['id'::name],
    'minigame_game_state.session_id cascades from minigame_sessions.id (ON DELETE CASCADE)');
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.minigame_game_state'::regclass),
    'minigame_game_state has RLS enabled (150_minigame_play)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.minigame_game_state'::regclass),
    'minigame_game_state has FORCE ROW LEVEL SECURITY (150_minigame_play)'
);
SELECT policies_are('minigame_game_state', ARRAY[
    'mgs_read_participant',
    'active_users_only'
], 'minigame_game_state policies: participant/invitee/group-member SELECT only (every write is an RPC contract)');
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'minigame_game_state'
          AND policyname = 'mgs_read_participant'
          AND cmd = 'SELECT'
          AND qual LIKE '%minigame_sessions%'
          AND qual LIKE '%minigame_invites%'
    ),
    'mgs_read_participant reads the session row exactly when participant/invitee/group-member does (EXISTS over minigame_sessions + minigame_invites)'
);
SELECT has_trigger('minigame_game_state', 'minigame_game_state_touch',
    'minigame_game_state has the updated_at touch trigger');
SELECT is_definer('public', 'minigame_game_state_touch', ARRAY[]::name[],
    'minigame_game_state_touch is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'minigame_game_state_touch'),
    'minigame_game_state_touch sets search_path = '''' (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%NEW.updated_at := now()%'
       AND pg_get_functiondef(p.oid) LIKE '%NEW.updated_at%'
     FROM pg_proc p WHERE proname = 'minigame_game_state_touch'),
    'minigame_game_state_touch stamps updated_at = now() on UPDATE'
);

-- 49c-b: minigame_prompts shape + seed
SELECT col_type_is('minigame_prompts', 'id', 'uuid',
    'minigame_prompts.id is uuid');
SELECT col_type_is('minigame_prompts', 'game_type', 'public.mini_game_type',
    'minigame_prompts.game_type is the mini_game_type enum');
SELECT col_type_is('minigame_prompts', 'prompt_type', 'text',
    'minigame_prompts.prompt_type is text (verdad/reto, quick/challenge, ...)');
SELECT col_type_is('minigame_prompts', 'category', 'text',
    'minigame_prompts.category is text (amor/foto/reto/general)');
SELECT col_type_is('minigame_prompts', 'body', 'text',
    'minigame_prompts.body is text (the prompt text)');
SELECT col_not_null('minigame_prompts', 'game_type',
    'minigame_prompts.game_type is NOT NULL');
SELECT col_not_null('minigame_prompts', 'prompt_type',
    'minigame_prompts.prompt_type is NOT NULL');
SELECT col_not_null('minigame_prompts', 'category',
    'minigame_prompts.category is NOT NULL');
SELECT col_not_null('minigame_prompts', 'body',
    'minigame_prompts.body is NOT NULL');
SELECT col_not_null('minigame_prompts', 'is_active',
    'minigame_prompts.is_active is NOT NULL');
SELECT col_has_default('minigame_prompts', 'category',
    'minigame_prompts.category defaults to general');
SELECT col_has_default('minigame_prompts', 'is_active',
    'minigame_prompts.is_active defaults true');
SELECT policies_are('minigame_prompts', ARRAY[
    'mgs_prompts_select'
], 'minigame_prompts policies: active-prompt SELECT only (no client writes)');
SELECT ok(
    (SELECT count(*) >= 8 FROM public.minigame_prompts WHERE game_type = 'truth_dare'),
    'truth_dare prompt bank is seeded with at least 8 prompts (150_minigame_play seed)'
);
SELECT ok(
    EXISTS (SELECT 1 FROM public.minigame_prompts
            WHERE game_type = 'truth_dare' AND prompt_type = 'verdad'
              AND category = 'amor' AND body = '¿Cuál fue tu primer beso?'),
    'seed: "¿Cuál fue tu primer beso?" (verdad/amor) is present'
);
SELECT ok(
    EXISTS (SELECT 1 FROM public.minigame_prompts
            WHERE game_type = 'truth_dare' AND prompt_type = 'verdad'
              AND category = 'amor' AND body = '¿Quién fue tu primer amor?'),
    'seed: "¿Quién fue tu primer amor?" (verdad/amor) is present'
);
SELECT ok(
    EXISTS (SELECT 1 FROM public.minigame_prompts
            WHERE game_type = 'truth_dare' AND prompt_type = 'verdad'
              AND body = 'Di la inicial de quien te gusta'),
    'seed: "Di la inicial de quien te gusta" (verdad) is present'
);
SELECT ok(
    EXISTS (SELECT 1 FROM public.minigame_prompts
            WHERE game_type = 'truth_dare' AND prompt_type = 'reto'
              AND body = 'Envía una foto de tu perro'),
    'seed: "Envía una foto de tu perro" (reto) is present'
);
SELECT ok(
    EXISTS (SELECT 1 FROM public.minigame_prompts
            WHERE game_type = 'truth_dare' AND prompt_type = 'reto'
              AND body = 'Hazte una selfie con un objeto'),
    'seed: "Hazte una selfie con un objeto" (reto) is present'
);
SELECT ok(
    EXISTS (SELECT 1 FROM public.minigame_prompts
            WHERE game_type = 'truth_dare' AND prompt_type = 'reto'
              AND body = 'Haz un challenge'),
    'seed: "Haz un challenge" (reto) is present'
);

-- 49c-c: the 5 RPCs — signature + hardening
SELECT has_function('get_minigame_game_state', ARRAY['uuid'],
    'get_minigame_game_state(p_session_id uuid) exists (150_minigame_play)');
SELECT is_definer('public', 'get_minigame_game_state', ARRAY['uuid'],
    'get_minigame_game_state is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'get_minigame_game_state'),
    'get_minigame_game_state sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'get_minigame_game_state', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'get_minigame_game_state is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'get_minigame_game_state', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'get_minigame_game_state is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''not_started''%'
       AND pg_get_functiondef(p.oid) LIKE '%''ok''%'
       AND pg_get_functiondef(p.oid) LIKE '%''session_not_found''%'
       AND pg_get_functiondef(p.oid) LIKE '%''not_allowed''%'
     FROM pg_proc p WHERE proname = 'get_minigame_game_state'),
    'get_minigame_game_state returns typed jsonb statuses (I-57 contract)'
);

SELECT has_function('init_minigame_game_state', ARRAY['uuid'],
    'init_minigame_game_state(p_session_id uuid) exists (150_minigame_play)');
SELECT is_definer('public', 'init_minigame_game_state', ARRAY['uuid'],
    'init_minigame_game_state is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'init_minigame_game_state'),
    'init_minigame_game_state sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'init_minigame_game_state', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'init_minigame_game_state is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'init_minigame_game_state', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'init_minigame_game_state is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''already_started''%'
       AND pg_get_functiondef(p.oid) LIKE '%''started''%'
       AND pg_get_functiondef(p.oid) LIKE '%''session_not_active''%'
       AND pg_get_functiondef(p.oid) LIKE '%random()%'
     FROM pg_proc p WHERE proname = 'init_minigame_game_state'),
    'init_minigame_game_state is idempotent (already_started), active-only, and picks the subject RANDOMLY (server-random)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%jsonb_build_object(%'
       AND pg_get_functiondef(p.oid) LIKE '%judge_index%'
       AND pg_get_functiondef(p.oid) LIKE '%phase%'
       AND pg_get_functiondef(p.oid) LIKE '%subject_id%'
     FROM pg_proc p WHERE proname = 'init_minigame_game_state'),
    'init_minigame_game_state seeds judge_index/round/phase and writes subject_id into the payload'
);

SELECT has_function('reveal_minigame_prompt', ARRAY['uuid', 'text'],
    'reveal_minigame_prompt(p_session_id uuid, p_prompt_type text) exists (150_minigame_play)');
SELECT is_definer('public', 'reveal_minigame_prompt', ARRAY['uuid', 'text'],
    'reveal_minigame_prompt is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'reveal_minigame_prompt'),
    'reveal_minigame_prompt sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'reveal_minigame_prompt', ARRAY['uuid', 'text']::name[], 'public', ARRAY[]::name[],
    'reveal_minigame_prompt is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'reveal_minigame_prompt', ARRAY['uuid', 'text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'reveal_minigame_prompt is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''invalid_prompt_type''%'
       AND pg_get_functiondef(p.oid) LIKE '%''revealed''%'
       AND pg_get_functiondef(p.oid) LIKE '%public.minigame_prompts%'
       AND pg_get_functiondef(p.oid) LIKE '%ORDER BY random()%'
       AND pg_get_functiondef(p.oid) LIKE '%LIMIT 1%'
     FROM pg_proc p WHERE proname = 'reveal_minigame_prompt'),
    'reveal_minigame_prompt validates prompt_type, draws a random active prompt (ORDER BY random() LIMIT 1), and reveals'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''prompt_type''%'
       AND pg_get_functiondef(p.oid) LIKE '%''prompt''%'
       AND pg_get_functiondef(p.oid) LIKE '%state || jsonb_build_object%'
     FROM pg_proc p WHERE proname = 'reveal_minigame_prompt'),
    'reveal_minigame_prompt persists prompt_type + prompt into the state payload'
);

SELECT has_function('advance_minigame_turn', ARRAY['uuid', 'jsonb'],
    'advance_minigame_turn(p_session_id uuid, p_round jsonb) exists (150_minigame_play)');
SELECT is_definer('public', 'advance_minigame_turn', ARRAY['uuid', 'jsonb'],
    'advance_minigame_turn is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'advance_minigame_turn'),
    'advance_minigame_turn sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'advance_minigame_turn', ARRAY['uuid', 'jsonb']::name[], 'public', ARRAY[]::name[],
    'advance_minigame_turn is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'advance_minigame_turn', ARRAY['uuid', 'jsonb']::name[], 'authenticated', ARRAY['EXECUTE'],
    'advance_minigame_turn is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%rounds || ARRAY[%'
        AND pg_get_functiondef(p.oid) LIKE '%random()%'
        AND pg_get_functiondef(p.oid) LIKE '%participants%'
        AND pg_get_functiondef(p.oid) LIKE '%judge_index%'
        AND pg_get_functiondef(p.oid) LIKE '%subject_id%'
      FROM pg_proc p WHERE proname = '_minigame_advance_round'),
    '_minigame_advance_round appends the round, rotates the judge round-robin, and picks a RANDOM next subject (202)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%rounds || ARRAY[%'
        AND pg_get_functiondef(p.oid) LIKE '%prompt_type%'
        AND pg_get_functiondef(p.oid) LIKE '%''phase''%'
        AND pg_get_functiondef(p.oid) LIKE '%v_round + 1%'
       FROM pg_proc p WHERE proname = '_minigame_advance_round'),
    '_minigame_advance_round bumps the round, clears prompt_type/prompt, and keeps phase=playing (202)'
);

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'complete_minigame_game'),
    'complete_minigame_game is dropped (201_minigame_voting replaces it with finish_minigame_game)'
);

-- 49c-d: realtime publication membership
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'minigame_game_state'
    ),
    'minigame_game_state joins the supabase_realtime publication (game state streams live to participants)'
);

-- 49c-e: authenticated client-RPC inventory extends to the play RPCs
SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('get_minigame_game_state', 'init_minigame_game_state',
                         'reveal_minigame_prompt', 'advance_minigame_turn',
                         'submit_minigame_reaction', 'abandon_minigame_game')
       AND has_function_privilege('authenticated', p.oid, 'EXECUTE')) = 6,
    'authenticated can EXECUTE the 6 play-engine RPCs (finish is server-only)'
);
SELECT ok(
    (SELECT count(*) FROM pg_catalog.pg_proc p
     JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prosecdef
       AND has_function_privilege('anon', p.oid, 'EXECUTE')
       AND p.proname NOT IN ('check_signup_email', 'is_group_member', 'is_chat_participant', 'upsert_signup_tracker')) = 0,
    'anon cannot EXECUTE any SECURITY DEFINER function (play RPCs included)'
);

-- ============================================================
-- SECTION 50: create_direct_chat RPC + chat RLS (migration 20260814000001)
-- ============================================================
SELECT has_function('create_direct_chat', ARRAY['uuid'],
    'create_direct_chat(p_peer_id uuid) exists');
SELECT is((SELECT prosecdef FROM pg_proc WHERE proname = 'create_direct_chat'),
    true, 'create_direct_chat is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY(proconfig) FROM pg_proc WHERE proname = 'create_direct_chat'),
    'create_direct_chat sets search_path = '''' (I-31 pattern)'
);
SELECT has_function('is_chat_participant', ARRAY['uuid', 'uuid'],
    'is_chat_participant(p_chat_id, p_user_id) exists');
SELECT is((SELECT prosecdef FROM pg_proc WHERE proname = 'is_chat_participant'),
    true, 'is_chat_participant is SECURITY DEFINER (RLS-recursion-safe)');
SELECT function_privs_are('public', 'is_chat_participant', ARRAY['uuid', 'uuid']::name[], 'anon', ARRAY['EXECUTE'],
    'anon has EXECUTE on is_chat_participant (policy evaluation, mirrors is_group_member)');
SELECT function_privs_are('public', 'create_direct_chat', ARRAY['uuid']::name[], 'anon', ARRAY[]::name[],
    'anon has NO EXECUTE on create_direct_chat');
SELECT function_privs_are('public', 'create_direct_chat', ARRAY['uuid']::name[], 'service_role', ARRAY[]::name[],
    'service_role has NO EXECUTE on create_direct_chat (client RPC only)');
SELECT function_privs_are('public', 'create_direct_chat', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'create_direct_chat is authenticated-EXECUTABLE');

-- ============================================================
-- SECTION 51: Blocked-user view exclusion + rank_bracket INSERT
-- normalization (migration 20260814000002)
-- ============================================================
SELECT ok(
    (SELECT pg_get_viewdef('user_search_view') LIKE '%blocked%'),
    'user_search_view excludes blocked friendships (20260814000002)'
);
SELECT ok(
    (SELECT pg_get_viewdef('discovery_view') LIKE '%blocked%'),
    'discovery_view excludes blocked friendships (20260814000002)'
);
SELECT has_function('public', 'assert_safe_group_update', ARRAY[]::name[],
    'assert_safe_group_update exists (refreshed by 20260814000002)');
SELECT ok(
    (SELECT 'search_path=""' = ANY(proconfig) FROM pg_proc WHERE proname = 'assert_safe_group_update'),
    'assert_safe_group_update sets search_path = '''' (I-31 pattern)'
);

-- ============================================================
-- SECTION 52: Rank recalc decay + notifications + cron
-- (migration 20260814000003)
-- ============================================================
SELECT has_function('insert_notification',
    ARRAY['uuid', 'text', 'text', 'text', 'jsonb'],
    'insert_notification(p_user_id, p_type, p_title, p_body, p_data) exists');
SELECT is((SELECT prosecdef FROM pg_proc WHERE proname = 'insert_notification'),
    true, 'insert_notification is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY(proconfig) FROM pg_proc WHERE proname = 'insert_notification'),
    'insert_notification sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'insert_notification',
    ARRAY['uuid', 'text', 'text', 'text', 'jsonb']::name[], 'anon', ARRAY[]::name[],
    'anon has NO EXECUTE on insert_notification');
SELECT function_privs_are('public', 'insert_notification',
    ARRAY['uuid', 'text', 'text', 'text', 'jsonb']::name[], 'authenticated', ARRAY[]::name[],
    'authenticated has NO EXECUTE on insert_notification (trigger/CLI only)');
SELECT ok(
    (SELECT 'search_path=""' = ANY(proconfig) FROM pg_proc WHERE proname = 'recalculate_ranks'),
    'recalculate_ranks sets search_path = '''' (hardened by 20260814000003)'
);
SELECT ok(
    (SELECT count(*) FROM cron.job WHERE jobname = 'ranks-recalculate') = 1,
    'ranks-recalculate cron job exists (GRCK Step 0, ranks.update_cron)'
);

-- ============================================================
-- SECTION 54: Notification producer triggers (migration 20260814000005)
-- ============================================================
SELECT has_function('notify_event_invite', ARRAY[]::name[],
    'notify_event_invite exists (NTRG #1)');
SELECT has_trigger('event_invites', 'notify_event_invite_trigger',
    'event_invites has notify_event_invite_trigger');
SELECT has_function('notify_friend_request', ARRAY[]::name[],
    'notify_friend_request exists (NTRG #2)');
SELECT has_trigger('friendships', 'notify_friend_request_trigger',
    'friendships has notify_friend_request_trigger');
SELECT has_function('notify_event_live', ARRAY[]::name[],
    'notify_event_live exists (NTRG #3)');
SELECT has_trigger('events', 'notify_event_live_trigger',
    'events has notify_event_live_trigger');
SELECT has_function('notify_event_cancelled', ARRAY[]::name[],
    'notify_event_cancelled exists (NTRG #4)');
SELECT has_trigger('events', 'notify_event_cancelled_trigger',
    'events has notify_event_cancelled_trigger');
SELECT has_function('notify_attendance_confirmed', ARRAY[]::name[],
    'notify_attendance_confirmed exists (NTRG #5)');
SELECT has_trigger('event_attendances', 'notify_attendance_confirmed_trigger',
    'event_attendances has notify_attendance_confirmed_trigger');
SELECT has_function('notify_new_message', ARRAY[]::name[],
    'notify_new_message exists (NTRG #6 — generic body, E2EE-safe)');
SELECT has_trigger('messages', 'notify_new_message_trigger',
    'messages has notify_new_message_trigger');
SELECT has_function('notify_minigame_invite', ARRAY[]::name[],
    'notify_minigame_invite exists (NTRG #7)');
SELECT has_trigger('minigame_invites', 'notify_minigame_invite_trigger',
    'minigame_invites has notify_minigame_invite_trigger (140_minigame_invites — notifies the INVITEE, not the creator)');
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'notify_minigame_invite_trigger'
          AND tgrelid = 'public.minigame_sessions'::regclass
    ),
    'notify_minigame_invite_trigger no longer fires on minigame_sessions INSERT (moved to minigame_invites)'
);
SELECT has_function('notify_feature_request', ARRAY[]::name[],
    'notify_feature_request exists (NTRG #8)');
SELECT has_trigger('feature_requests', 'notify_feature_request_trigger',
    'feature_requests has notify_feature_request_trigger');

-- ============================================================
-- SECTION 54b: Device tokens + push bookkeeping (migration 223_device_tokens)
-- ============================================================
SELECT has_table('public', 'device_tokens', 'device_tokens exists (223)');
SELECT has_column('public', 'notifications', 'push_sent_at',
    'notifications.push_sent_at exists (223)');
SELECT has_function('public', 'register_device_token', ARRAY['text', 'text']::name[],
    'register_device_token(text, text) exists (223)');
SELECT is_definer('public', 'register_device_token', ARRAY['text', 'text']::name[],
    'register_device_token is SECURITY DEFINER');
SELECT function_privs_are('public', 'register_device_token',
    ARRAY['text', 'text']::name[], 'anon', ARRAY[]::name[],
    'anon has NO EXECUTE on register_device_token');
SELECT function_privs_are('public', 'register_device_token',
    ARRAY['text', 'text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'authenticated can EXECUTE register_device_token');
SELECT has_function('public', 'unregister_device_token', ARRAY['text']::name[],
    'unregister_device_token(text) exists (223)');
SELECT function_privs_are('public', 'unregister_device_token',
    ARRAY['text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'authenticated can EXECUTE unregister_device_token');
SELECT has_function('notify_minigame_turn', ARRAY[]::name[],
    'notify_minigame_turn exists (224 — generic minigame turn)');
SELECT has_trigger('minigame_game_state', 'notify_minigame_turn_trigger',
    'minigame_game_state has notify_minigame_turn_trigger (224)');


-- ============================================================
-- SECTION 55: Group chain of command (migration 20260816000001)
-- ============================================================
SELECT has_function('public', 'transfer_host', ARRAY['uuid', 'uuid']::name[],
    'transfer_host exists (OPT-009 — atomic host handover)');
SELECT is_definer('public', 'transfer_host', ARRAY['uuid', 'uuid']::name[],
    'transfer_host is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'transfer_host'),
    'transfer_host sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'transfer_host', ARRAY['uuid', 'uuid']::name[], 'public', ARRAY[]::name[],
    'transfer_host is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'transfer_host', ARRAY['uuid', 'uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'transfer_host is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%staff%'
       AND pg_get_functiondef(p.oid) LIKE '%not_host%'
       AND pg_get_functiondef(p.oid) LIKE '%role = ''host''%'
     FROM pg_proc p WHERE proname = 'transfer_host'),
    'transfer_host is host-only and demotes self + promotes successor'
);
SELECT has_function('public', 'promote_next_member', ARRAY['uuid']::name[],
    'promote_next_member exists (OPT-009 — successor pick)');
SELECT is_definer('public', 'promote_next_member', ARRAY['uuid']::name[],
    'promote_next_member is SECURITY DEFINER');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%role = ''staff''%'
       AND pg_get_functiondef(p.oid) LIKE '%random()%'
       AND pg_get_functiondef(p.oid) LIKE '%status = ''active''%'
     FROM pg_proc p WHERE proname = 'promote_next_member'),
    'promote_next_member prefers staff, random pick, active-only'
);
SELECT has_function('public', 'reassign_group_host', ARRAY[]::name[],
    'reassign_group_host exists (OPT-009 — ban/delete leadership pass)');
SELECT is_definer('public', 'reassign_group_host', ARRAY[]::name[],
    'reassign_group_host is SECURITY DEFINER');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%banned_at%'
       AND pg_get_functiondef(p.oid) LIKE '%deleted_at%'
       AND pg_get_functiondef(p.oid) LIKE '%promote_next_member%'
     FROM pg_proc p WHERE proname = 'reassign_group_host'),
    'reassign_group_host demotes banned/deleted hosts and passes leadership'
);
SELECT has_trigger('group_members', 'reassign_group_host_delete_trigger',
    'group_members has the host-reassignment delete trigger');
SELECT has_trigger('users', 'reassign_group_host_user_trigger',
    'users has the host-reassignment ban/delete trigger');

-- ============================================================
-- SECTION 56: Group chat E2EE support (migrations 20260817000001
-- through 20260817000004, ISSUE 4 — D1/D3 + the F5/F6/F7 fix round)
--   56a. 20260817000001 — group_members realtime (publication + REPLICA
--        IDENTITY FULL, mirroring the messages/friendships pattern).
--   56b. 20260817000002 — participant-sync triggers + SECURITY DEFINER
--        functions (search_path = '', not PUBLIC-executable); active-only
--        RLS gates on the group branches of the three chat policies;
--        get_chat_inbox group branch (groups.name join, peer_id NULL).
--   56c. 20260817000003 — messages.recipient_id (uuid, nullable).
--   56d. 20260817000004 — accept_friend_request RPC (addressee-only,
--        pending-only, authenticated-only) + get_chat_inbox now carries
--        last_message_recipient_id + enforce_message_cap skips
--        recipient_id (distribution) rows (behavioral, rolled back).
-- ============================================================

-- 56a: group_members realtime (20260817000001)
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'group_members'
    ),
    'group_members is in the supabase_realtime publication (20260817000001)'
);
SELECT is(
    (SELECT relreplident FROM pg_class WHERE oid = 'public.group_members'::regclass),
    'f',
    'group_members has REPLICA IDENTITY FULL (realtime full-row delivery, 20260817000001)'
);

-- 56b: participant-sync triggers + functions + active RLS gates (20260817000002)
SELECT has_trigger('group_members', 'sync_group_chat_participant_trigger',
    'group_members has the chat-participant sync trigger (D1b)');
SELECT has_trigger('chats', 'sync_group_chat_participants_on_chats_trigger',
    'chats has the participant-backfill sync trigger (D1c)');
SELECT has_function('public', 'sync_group_chat_participant', ARRAY[]::name[],
    'sync_group_chat_participant exists (D1b trigger function)');
SELECT is_definer('public', 'sync_group_chat_participant', ARRAY[]::name[],
    'sync_group_chat_participant is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'sync_group_chat_participant'),
    'sync_group_chat_participant sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'sync_group_chat_participant', ARRAY[]::name[], 'public', ARRAY[]::name[],
    'sync_group_chat_participant is not PUBLIC-EXECUTABLE (Section 48 posture)');
SELECT has_function('public', 'sync_group_chat_participants_on_chats', ARRAY[]::name[],
    'sync_group_chat_participants_on_chats exists (D1c trigger function)');
SELECT is_definer('public', 'sync_group_chat_participants_on_chats', ARRAY[]::name[],
    'sync_group_chat_participants_on_chats is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'sync_group_chat_participants_on_chats'),
    'sync_group_chat_participants_on_chats sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'sync_group_chat_participants_on_chats', ARRAY[]::name[], 'public', ARRAY[]::name[],
    'sync_group_chat_participants_on_chats is not PUBLIC-EXECUTABLE (Section 48 posture)');
-- 56b: active-only gates on the group branches (D1e) — invited users are
-- excluded from group chats until they accept.
SELECT ok(
    EXISTS (SELECT 1 FROM pg_policies p
            WHERE p.schemaname = 'public' AND p.tablename = 'messages'
              AND p.policyname = 'messages_read_participant'
              AND EXISTS (SELECT 1 FROM regexp_matches(p.qual, 'status = ''active'''))),
    'messages_read_participant group branch gates on status = ''active'' (D1e)'
);
SELECT ok(
    EXISTS (SELECT 1 FROM pg_policies p
            WHERE p.schemaname = 'public' AND p.tablename = 'messages'
              AND p.policyname = 'messages_insert_participant'
              AND EXISTS (SELECT 1 FROM regexp_matches(p.with_check, 'status = ''active'''))),
    'messages_insert_participant group branch gates on status = ''active'' (D1e)'
);
SELECT ok(
    EXISTS (SELECT 1 FROM pg_policies p
            WHERE p.schemaname = 'public' AND p.tablename = 'chats'
              AND p.policyname = 'chats_read_participant'
              AND EXISTS (SELECT 1 FROM regexp_matches(p.qual, 'status = ''active'''))),
    'chats_read_participant group branch gates on status = ''active'' (D1e)'
);
-- 56b: get_chat_inbox group branch (D1d) — groups.name join + peer_id NULL.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.groups g%'
       AND pg_get_functiondef(p.oid) LIKE '%g.name%'
       AND pg_get_functiondef(p.oid) LIKE '%THEN NULL ELSE usv.id%'
     FROM pg_proc p WHERE proname = 'get_chat_inbox'),
    'get_chat_inbox group branch joins groups.name and keeps peer_id NULL (D1d)'
);

-- 56c: distribution addressing (20260817000003)
SELECT has_column('messages', 'recipient_id',
    'messages.recipient_id exists — sender-key distribution targeting (20260817000003)');
SELECT col_type_is('messages', 'recipient_id', 'uuid',
    'messages.recipient_id is uuid (the target member id)');
SELECT col_is_null('messages', 'recipient_id',
    'messages.recipient_id is nullable — NULL on ordinary message rows');

-- 56d: fix round (20260817000004)
SELECT has_function('public', 'accept_friend_request', ARRAY['uuid']::name[],
    'accept_friend_request(p_friendship_id uuid) exists (F6 — addressee-only acceptance)');
SELECT is_definer('public', 'accept_friend_request', ARRAY['uuid']::name[],
    'accept_friend_request is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'accept_friend_request'),
    'accept_friend_request sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'accept_friend_request', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'accept_friend_request is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'accept_friend_request', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'accept_friend_request is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%last_message_recipient_id%'
     FROM pg_proc p WHERE proname = 'get_chat_inbox'),
    'get_chat_inbox returns last_message_recipient_id (F5 — preview skips non-target distribution rows)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%recipient_id IS NULL%'
     FROM pg_proc p WHERE proname = 'enforce_message_cap'),
    'enforce_message_cap rolling-window DELETE skips recipient_id rows (F7)'
);
-- 56d: behavioral cap check (rolled back with the suite): cap=3, 2 recipient
-- rows FIRST (oldest — the old trigger would prune them) + 4 ordinary rows →
-- only ordinary rows are pruned; the distribution rows survive.
SELECT lives_ok($$
    INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('88888888-8888-8888-8888-888888888801', 'pg56_cap_sender', DATE '1990-01-01');
    INSERT INTO public.chats (id, type) VALUES
        ('88888888-8888-8888-8888-888888888811', 'direct');
    INSERT INTO public.app_config (key, value) VALUES ('chat.message_cap', '3')
        ON CONFLICT (key) DO UPDATE SET value = '3';
    INSERT INTO public.messages (id, chat_id, sender_id, content, recipient_id, created_at) VALUES
        ('88888888-8888-8888-8888-888888888825', '88888888-8888-8888-8888-888888888811', '88888888-8888-8888-8888-888888888801', 'r1', '88888888-8888-8888-8888-888888888802', '2026-08-17T00:00:01Z'),
        ('88888888-8888-8888-8888-888888888826', '88888888-8888-8888-8888-888888888811', '88888888-8888-8888-8888-888888888801', 'r2', '88888888-8888-8888-8888-888888888802', '2026-08-17T00:00:02Z'),
        ('88888888-8888-8888-8888-888888888821', '88888888-8888-8888-8888-888888888811', '88888888-8888-8888-8888-888888888801', 'n1', NULL, '2026-08-17T00:00:03Z'),
        ('88888888-8888-8888-8888-888888888822', '88888888-8888-8888-8888-888888888811', '88888888-8888-8888-8888-888888888801', 'n2', NULL, '2026-08-17T00:00:04Z'),
        ('88888888-8888-8888-8888-888888888823', '88888888-8888-8888-8888-888888888811', '88888888-8888-8888-8888-888888888801', 'n3', NULL, '2026-08-17T00:00:05Z'),
        ('88888888-8888-8888-8888-888888888824', '88888888-8888-8888-8888-888888888811', '88888888-8888-8888-8888-888888888801', 'n4', NULL, '2026-08-17T00:00:06Z');
$$, 'cap behavior (F7): inserting beyond the cap with recipient_id rows succeeds');
SELECT is(
    (SELECT count(*) FROM public.messages
      WHERE chat_id = '88888888-8888-8888-8888-888888888811'
        AND recipient_id IS NOT NULL),
    2::bigint,
    'cap behavior (F7): both recipient_id rows survive beyond the cap'
);
SELECT is(
    (SELECT count(*) FROM public.messages
      WHERE chat_id = '88888888-8888-8888-8888-888888888811'),
    3::bigint,
    'cap behavior (F7): the chat holds cap + surviving distribution rows (n4 + r1 + r2)'
);
SELECT is(
    (SELECT count(*) FROM public.messages
      WHERE chat_id = '88888888-8888-8888-8888-888888888811'
        AND id IN ('88888888-8888-8888-8888-888888888821',
                   '88888888-8888-8888-8888-888888888822',
                   '88888888-8888-8888-8888-888888888823')),
    0::bigint,
    'cap behavior (F7): the three oldest ordinary rows are pruned (n1..n3 gone)'
);
SELECT is(
    (SELECT count(*) FROM public.messages
      WHERE chat_id = '88888888-8888-8888-8888-888888888811'
        AND recipient_id IS NULL),
    1::bigint,
    'cap behavior (F7): ordinary rows are pruned down to the cap (n4 survives)'
);

-- ============================================================
-- 56e: deleted_messages RLS (migration 20260817000005 — K1 re-audit:
-- the deletion audit trail was created WITHOUT RLS; it now ENABLEs +
-- FORCEs RLS and carries the admin_audit_log no-access policy, so no
-- anon/authenticated client can read or write the deletion trail. The
-- SECURITY DEFINER RPCs (delete_message_for_everyone /
-- delete_undecryptable_messages) run as the definer (superuser) and
-- bypass RLS — they keep writing the audit rows unchanged.
-- ============================================================
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.deleted_messages'::regclass),
    'deleted_messages has RLS enabled (migration 20260817000005)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.deleted_messages'::regclass),
    'deleted_messages has FORCE ROW LEVEL SECURITY (migration 20260817000005)'
);
SELECT policies_are('deleted_messages', ARRAY[
    'deleted_messages_no_access'
], 'deleted_messages is service_role only (no_access policy, migration 20260817000005)');


-- ============================================================
-- 57: group read receipts (migration 20260817000006) —
--     message_reads per-member table + mark_group_messages_read
--     (the ISSUE 2026-08-17 fix: a group sender's blue check must
--     require EVERY other member's read, so reads are tracked per
--     (message, reader) instead of the 1:1 read_at column).
-- ============================================================
SELECT has_table('message_reads',
    'message_reads exists (migration 20260817000006)');
SELECT col_type_is('message_reads', 'message_id', 'uuid',
    'message_reads.message_id is uuid');
SELECT col_type_is('message_reads', 'user_id', 'uuid',
    'message_reads.user_id is uuid');
SELECT col_type_is('message_reads', 'read_at', 'timestamp with time zone',
    'message_reads.read_at is timestamptz');
SELECT col_not_null('message_reads', 'read_at',
    'message_reads.read_at is NOT NULL');
SELECT col_default_is('message_reads', 'read_at', 'now()',
    'message_reads.read_at defaults now()');
SELECT has_pk('message_reads',
    'message_reads has a primary key (message_id, user_id)');
SELECT ok(
    (SELECT contype = 'p' AND array_length(conkey, 1) = 2
     FROM pg_constraint
     WHERE conrelid = 'public.message_reads'::regclass AND contype = 'p'),
    'message_reads PK is composite (message_id, user_id)'
);
SELECT fk_ok('message_reads', ARRAY['message_id'::name], 'messages', ARRAY['id'::name],
    'message_reads.message_id cascades from messages.id (ON DELETE CASCADE)');
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.message_reads'::regclass),
    'message_reads has RLS enabled (migration 20260817000006)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.message_reads'::regclass),
    'message_reads has FORCE ROW LEVEL SECURITY (migration 20260817000006)'
);
SELECT policies_are('message_reads', ARRAY[
    'message_reads_insert_own',
    'message_reads_select_participant',
    'active_users_only'
], 'message_reads policies: own-row INSERT (participation-gated) + participant SELECT');
SELECT ok(
    (SELECT count(*) = 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public' AND tablename = 'message_reads'),
    'message_reads joins the supabase_realtime publication (20260817000006)'
);
SELECT has_function('mark_group_messages_read', ARRAY['uuid'],
    'mark_group_messages_read(p_chat_id uuid) exists (SECURITY DEFINER RPC)');
SELECT is_definer('public', 'mark_group_messages_read', ARRAY['uuid'],
    'mark_group_messages_read is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'mark_group_messages_read'),
    'mark_group_messages_read sets search_path = empty (migration 20260817000006)'
);
SELECT function_privs_are('public', 'mark_group_messages_read', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'mark_group_messages_read is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'mark_group_messages_read', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'mark_group_messages_read is authenticated-EXECUTABLE');

-- ============================================================
-- SECTION 60: users profile-RPC lockdown (baseline 020_core/02_users.sql,
-- 2026-08-25 directive: clients may NEVER write the table directly).
--   50a. users_username_shape CHECK (name-anchored) + NFKC clause.
--   50b. Helper functions exist: sanitize_free_text / sanitize_username /
--        assert_username_shape / assert_date_of_birth.
--   50c. The 7 client-facing RPCs (create_my_profile, update_my_profile,
--        delete_my_account, set_avatar_url, set_discovery_opt_in,
--        set_read_receipts_enabled, set_profile_public): SECURITY DEFINER +
--        empty search_path + PUBLIC-revoked + authenticated-EXECUTABLE.
--   50d. Table privilege lockdown: anon/authenticated hold NO INSERT/UPDATE;
--        authenticated keeps SELECT; service_role keeps everything.
--   50e. Behavioral matrix under authenticated-style JWT claims: happy
--        create (defaults + shard_ledger grant), duplicate, username policy
--        raises, DOB rules (required/adult/set-once), bio set/clear/cap,
--        tombstone rename + re-create block, CHECK rejects raw writes even
--        from privileged roles, direct client writes denied (42501).
-- ============================================================

-- 60a: constraint
SELECT ok(
    (SELECT count(*) = 1 FROM pg_constraint
     WHERE conrelid = 'public.users'::regclass
       AND conname = 'users_username_shape'
       AND contype = 'c'),
    'users.users_username_shape CHECK exists (profile-RPC lockdown)'
);
SELECT ok(
    (SELECT pg_get_constraintdef(oid) ~* 'normalize\(.*NFKC'
     FROM pg_constraint
     WHERE conrelid = 'public.users'::regclass
       AND conname = 'users_username_shape'),
    'users_username_shape enforces NFKC stability'
);

-- 60b: helpers
SELECT has_function('sanitize_free_text', ARRAY['text', 'integer'],
    'sanitize_free_text(p_raw, p_max_length) exists');
SELECT has_function('sanitize_username', ARRAY['text'],
    'sanitize_username(p_raw) exists');
SELECT has_function('assert_username_shape', ARRAY['text'],
    'assert_username_shape(p_value) exists');
SELECT has_function('assert_date_of_birth', ARRAY['date'],
    'assert_date_of_birth(p_dob) exists');

-- 60c: the RPC family
SELECT has_function('create_my_profile', ARRAY['text', 'date'],
    'create_my_profile(p_username, p_date_of_birth) exists');
SELECT has_function('update_my_profile', ARRAY['text', 'date'],
    'update_my_profile(p_bio, p_date_of_birth) exists');
SELECT has_function('delete_my_account', ARRAY[]::name[],
    'delete_my_account() exists');
SELECT has_function('set_avatar_url', ARRAY['text'],
    'set_avatar_url(p_avatar_url) exists');
SELECT has_function('set_discovery_opt_in', ARRAY['boolean'],
    'set_discovery_opt_in(p_value) exists');
SELECT has_function('set_read_receipts_enabled', ARRAY['boolean'],
    'set_read_receipts_enabled(p_value) exists');
SELECT has_function('set_profile_public', ARRAY['boolean'],
    'set_profile_public(p_value) exists');

SELECT is_definer('public', 'create_my_profile', ARRAY['text', 'date'],
    'create_my_profile is SECURITY DEFINER');
SELECT is_definer('public', 'update_my_profile', ARRAY['text', 'date'],
    'update_my_profile is SECURITY DEFINER');
SELECT is_definer('public', 'delete_my_account', ARRAY[]::name[],
    'delete_my_account is SECURITY DEFINER');
SELECT is_definer('public', 'set_avatar_url', ARRAY['text'],
    'set_avatar_url is SECURITY DEFINER');
SELECT is_definer('public', 'set_discovery_opt_in', ARRAY['boolean'],
    'set_discovery_opt_in is SECURITY DEFINER');
SELECT is_definer('public', 'set_read_receipts_enabled', ARRAY['boolean'],
    'set_read_receipts_enabled is SECURITY DEFINER');
SELECT is_definer('public', 'set_profile_public', ARRAY['boolean'],
    'set_profile_public is SECURITY DEFINER');

SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'create_my_profile'),
    'create_my_profile sets search_path = empty');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'update_my_profile'),
    'update_my_profile sets search_path = empty');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'delete_my_account'),
    'delete_my_account sets search_path = empty');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'set_avatar_url'),
    'set_avatar_url sets search_path = empty');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'set_discovery_opt_in'),
    'set_discovery_opt_in sets search_path = empty');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'set_read_receipts_enabled'),
    'set_read_receipts_enabled sets search_path = empty');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE proname = 'set_profile_public'),
    'set_profile_public sets search_path = empty');

SELECT function_privs_are('public', 'create_my_profile', ARRAY['text','date']::name[], 'public', ARRAY[]::name[],
    'create_my_profile is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'update_my_profile', ARRAY['text','date']::name[], 'public', ARRAY[]::name[],
    'update_my_profile is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'delete_my_account', ARRAY[]::name[], 'public', ARRAY[]::name[],
    'delete_my_account is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'set_avatar_url', ARRAY['text']::name[], 'public', ARRAY[]::name[],
    'set_avatar_url is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'set_discovery_opt_in', ARRAY['boolean']::name[], 'public', ARRAY[]::name[],
    'set_discovery_opt_in is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'set_read_receipts_enabled', ARRAY['boolean']::name[], 'public', ARRAY[]::name[],
    'set_read_receipts_enabled is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'set_profile_public', ARRAY['boolean']::name[], 'public', ARRAY[]::name[],
    'set_profile_public is not PUBLIC-EXECUTABLE');

SELECT function_privs_are('public', 'create_my_profile', ARRAY['text','date']::name[], 'authenticated', ARRAY['EXECUTE'],
    'create_my_profile is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'update_my_profile', ARRAY['text','date']::name[], 'authenticated', ARRAY['EXECUTE'],
    'update_my_profile is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'delete_my_account', ARRAY[]::name[], 'authenticated', ARRAY['EXECUTE'],
    'delete_my_account is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'set_avatar_url', ARRAY['text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'set_avatar_url is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'set_discovery_opt_in', ARRAY['boolean']::name[], 'authenticated', ARRAY['EXECUTE'],
    'set_discovery_opt_in is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'set_read_receipts_enabled', ARRAY['boolean']::name[], 'authenticated', ARRAY['EXECUTE'],
    'set_read_receipts_enabled is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'set_profile_public', ARRAY['boolean']::name[], 'authenticated', ARRAY['EXECUTE'],
    'set_profile_public is authenticated-EXECUTABLE');

-- 60d: table privilege lockdown
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.users', 'INSERT')
        AND NOT has_table_privilege('authenticated', 'public.users', 'UPDATE'),
    'authenticated holds NO INSERT/UPDATE on users (RPC-mediated writes only)'
);
SELECT ok(
    NOT has_table_privilege('anon', 'public.users', 'INSERT')
        AND NOT has_table_privilege('anon', 'public.users', 'UPDATE'),
    'anon holds NO INSERT/UPDATE on users'
);
SELECT ok(
    has_table_privilege('authenticated', 'public.users', 'SELECT'),
    'authenticated keeps own-row SELECT (RLS-gated)'
);
SELECT ok(
    has_table_privilege('service_role', 'public.users', 'UPDATE')
        AND has_table_privilege('service_role', 'public.users', 'INSERT'),
    'service_role keeps full access (admin CLI / cron / seeds)'
);

-- 60e: behavioral matrix (JWT-claims style of Sections 37/44)
-- UID family unique to this section.
SELECT set_config('request.jwt.claims',
    '{"sub":"47474747-4747-4747-4747-474747474701","role":"authenticated"}', false);

SELECT lives_ok(
    $$SELECT public.create_my_profile('  Sofia  ', DATE '2000-01-15')$$,
    'create_my_profile happy path sanitizes + inserts'
);
SELECT ok(
    (SELECT username = 'Sofia'
        AND personal_shards >= 0
        AND preshards = 0
        AND subscription_tier = 'free'
        AND bio IS NULL
        AND avatar_url IS NULL
        AND banned_at IS NULL
        AND deleted_at IS NULL
     FROM public.users
     WHERE id = '47474747-4747-4747-4747-474747474701'),
    'created row carries sanitized username + economy defaults'
);
SELECT ok(
    (SELECT l.delta = COALESCE(
        (SELECT value::integer FROM public.app_config WHERE key = 'economy.user_signup_shards'), 0)
        AND l.reason = 'admin_grant'
     FROM public.shard_ledger l
     WHERE l.user_id = '47474747-4747-4747-4747-474747474701'),
    'signup shard_ledger grant written atomically by the RPC'
);
SELECT throws_ok(
    $$SELECT public.create_my_profile('other', DATE '2000-01-15')$$,
    'P0001', 'Tu perfil ya existe.',
    'duplicate profile creation raises'
);
SELECT throws_ok(
    $$SELECT public.create_my_profile('abc', DATE '2000-01-15')$$,
    'P0001', 'Debe tener al menos 5 caracteres.',
    'username below minimum raises the client-parity message'
);
SELECT throws_ok(
    $$SELECT public.create_my_profile(repeat('x', 65), DATE '2000-01-15')$$,
    'P0001', 'El nombre de usuario es demasiado largo.',
    'username above the code-point ceiling raises'
);
SELECT throws_ok(
    $$SELECT public.create_my_profile('validname', DATE '2020-01-01')$$,
    'P0001', 'Debes tener 18 años para usar Samay.',
    'underage date_of_birth raises'
);
SELECT throws_ok(
    $$SELECT public.create_my_profile(NULL, DATE '2000-01-15')$$,
    'P0001', 'El nombre de usuario es obligatorio.',
    'NULL username raises'
);

-- bio: sanitize-on-write, cap at 160 code points, '' clears
SELECT lives_ok(
    $$SELECT public.update_my_profile(E'  Hola \u200B mundo ', NULL)$$,
    'update_my_profile accepts a bio (control chars stripped server-side)'
);
SELECT is(
    (SELECT bio FROM public.users WHERE id = '47474747-4747-4747-4747-474747474701'),
    'Hola  mundo',
    'bio stored control-char-free and trimmed (inner spacing preserved — client parity)'
);
SELECT throws_ok(
    $$SELECT public.update_my_profile(repeat('b', 161), NULL)$$,
    'P0001', 'El texto no puede superar 160 caracteres.',
    'bio above 160 code points raises'
);
SELECT lives_ok(
    $$SELECT public.update_my_profile('', NULL)$$,
    'empty-string bio clears the field'
);
SELECT ok(
    (SELECT bio IS NULL FROM public.users WHERE id = '47474747-4747-4747-4747-474747474701'),
    'cleared bio persists as NULL'
);

-- Q17: DOB is NOT NULL and adult-checked on every write. Legacy rows use the
-- documented sentinel+flag path instead of NULL.
SELECT throws_ok(
    $$UPDATE public.users SET date_of_birth = NULL
      WHERE id = '47474747-4747-4747-4747-474747474701'$$,
    'P0001', 'La fecha de nacimiento es obligatoria.',
    'privileged NULL DOB is rejected by the Q17 trigger'
);
SELECT lives_ok(
    $$UPDATE public.users SET date_of_birth = DATE '1900-01-01',
             date_of_birth_backfilled = true
      WHERE id = '47474747-4747-4747-4747-474747474701'$$,
    'legacy backfill sentinel + flag written (documented validation path)'
);
SELECT lives_ok(
    $$SELECT public.update_my_profile(NULL, DATE '1999-05-05')$$,
    'backfilled account may correct its DOB once through the RPC'
);
SELECT ok(
    (SELECT date_of_birth = DATE '1999-05-05'
        AND date_of_birth_backfilled = false
     FROM public.users WHERE id = '47474747-4747-4747-4747-474747474701'),
    'corrected DOB persisted and the backfill flag cleared'
);
SELECT throws_ok(
    $$UPDATE public.users SET date_of_birth = DATE '2020-01-01'
      WHERE id = '47474747-4747-4747-4747-474747474701'$$,
    'P0001', 'Debes tener 18 años para usar Samay.',
    '18+ trigger rejects an underage raw UPDATE (all roles)'
);
SELECT lives_ok(
    $$SELECT public.update_my_profile(NULL, DATE '1999-05-05')$$,
    'identical DOB re-submission is an allowed no-op (set-once semantics)'
);
SELECT throws_ok(
    $$SELECT public.update_my_profile(NULL, DATE '1999-06-06')$$,
    'P0001', 'La fecha de nacimiento no puede modificarse.',
    'changing an existing DOB raises (age gate stays unfarmable)'
);

-- Q1 delete: immediate hard delete, no tombstone/restore
SELECT lives_ok(
    $$SELECT public.delete_my_account()$$,
    'delete_my_account hard-deletes the own row immediately'
);
SELECT is(
    (SELECT count(*) FROM public.users
      WHERE id = '47474747-4747-4747-4747-474747474701'),
    0::bigint,
    'Q1 hard delete removes the users row (no tombstone)'
);
SELECT lives_ok(
    $$SELECT public.create_my_profile('sofia2', DATE '2000-01-15')$$,
    'Q1: the freed identity can create a fresh profile (no restore row)'
);

-- CHECK constraint fires even for PRIVILEGED raw writers
SELECT throws_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('47474747-4747-4747-4747-474747474702', 'abc', DATE '1990-01-01')$$,
    '23514', 'new row for relation "users" violates check constraint "users_username_shape"',
    'users_username_shape rejects a short RAW write (any role)'
);
SELECT throws_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('47474747-4747-4747-4747-474747474703', 'ｓｏｆｉａ', DATE '1990-01-01')$$,
    '23514', 'new row for relation "users" violates check constraint "users_username_shape"',
    'users_username_shape rejects non-NFKC usernames (any role)'
);
SELECT lives_ok(
    $$INSERT INTO public.users (id, username, date_of_birth, deleted_at) VALUES
        ('47474747-4747-4747-4747-474747474704',
         'deleted_user_' || repeat('y', 70), DATE '1990-01-01', now())$$,
    'tombstone rows are exempt from the username shape CHECK'
);

-- clients cannot bypass the RPCs — the core lockdown pin
SET ROLE authenticated;
SELECT throws_ok(
    $$UPDATE public.users SET bio = 'hacked' WHERE id = auth.uid()$$,
    '42501', 'permission denied for table users',
    'authenticated direct UPDATE is DENIED (no table privilege)'
);
RESET ROLE;
SET ROLE anon;
SELECT throws_ok(
    $$INSERT INTO public.users (id, username) VALUES
        ('47474747-4747-4747-4747-474747474705', 'hacker')$$,
    '42501', 'permission denied for table users',
    'anon direct INSERT is DENIED (no table privilege)'
);
RESET ROLE;

-- setters persist through the scoped RPCs (back on the tombstone? no —
-- setters target the live row; use a second fresh identity)
SELECT set_config('request.jwt.claims',
    '{"sub":"47474747-4747-4747-4747-474747474706","role":"authenticated"}', false);
SELECT lives_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('47474747-4747-4747-4747-474747474706', 'setteruser', DATE '1990-01-01')$$,
    'second fixture inserted (privileged, CHECK-compliant)'
);
SELECT lives_ok($$SELECT public.set_avatar_url('https://cdn.example/a.png')$$,
    'set_avatar_url accepts an https URL');
SELECT throws_ok(
    $$SELECT public.set_avatar_url('http://insecure.example/a.png')$$,
    'P0001', 'La URL del avatar no es válida.',
    'set_avatar_url rejects non-https URLs'
);
SELECT lives_ok($$SELECT public.set_avatar_url(NULL)$$,
    'set_avatar_url(NULL) clears the avatar');
SELECT lives_ok($$SELECT public.set_discovery_opt_in(true)$$,
    'set_discovery_opt_in persists');
SELECT lives_ok($$SELECT public.set_read_receipts_enabled(false)$$,
    'set_read_receipts_enabled persists');
SELECT lives_ok($$SELECT public.set_profile_public(true)$$,
    'set_profile_public persists');
SELECT ok(
    (SELECT avatar_url IS NULL
        AND discovery_opt_in IS TRUE
        AND read_receipts_enabled IS FALSE
        AND profile_public IS TRUE
     FROM public.users
     WHERE id = '47474747-4747-4747-4747-474747474706'),
    'all four setter effects persisted on the own row'
);

-- helper sanity: sanitizer parity with the Dart client
SELECT is(
    public.sanitize_username(E'\uFF33\uFF4F\uFF46\uFF49\uFF41'),
    'Sofia',
    'sanitize_username NFKC-folds fullwidth forms (client parity)'
);
SELECT is(
    public.sanitize_free_text(E'line1\u000Aline2', 160),
    'line1line2',
    'sanitize_free_text strips control characters'
);
SELECT is(
    public.sanitize_free_text(NULL, 160),
    NULL,
    'sanitize_free_text(NULL) is NULL'
);

-- restore a clean claims context for any later sections
SELECT set_config('request.jwt.claims', '', true);

-- ============================================================
-- SECTION 61: search abuse protection (baseline 130_search/01_search_rpc.sql,
-- OWASP API4 hardening of the user-search endpoint).
--   61a. search_users(p_query text): SECURITY DEFINER + empty search_path +
--        PUBLIC-revoked + authenticated-EXECUTABLE.
--   61b. search_rate_limits counter table: PK/FK shape, defaults, RLS
--        enabled + FORCED, zero client privileges.
--   61c. idx_users_username_prefix uses text_pattern_ops (allowed searches
--        must be index scans).
--   61d. Behavioral matrix under JWT claims: prefix match with caller
--        exclusion, SR002 on short/long queries, SR003 for anon, SR001 once
--        the 60/rolling-minute quota is exceeded, window-expiry reset,
--        LIKE-wildcard escaping.
-- ============================================================

-- 61a: RPC shape + privileges
SELECT has_function('search_users', ARRAY['text'],
    'search_users(p_query text) exists (130_search)');
SELECT is_definer('public', 'search_users', ARRAY['text'],
    'search_users is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'search_users'),
    'search_users sets search_path = '''' (130_search)'
);
SELECT function_privs_are('public', 'search_users', ARRAY['text']::name[], 'public', ARRAY[]::name[],
    'search_users is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'search_users', ARRAY['text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'search_users is authenticated-EXECUTABLE');

-- 61b: counter table
SELECT has_table('search_rate_limits',
    'search_rate_limits exists (130_search)');
SELECT has_pk('search_rate_limits',
    'search_rate_limits has a primary key (user_id)');
SELECT col_type_is('search_rate_limits', 'user_id', 'uuid',
    'search_rate_limits.user_id is uuid');
SELECT col_not_null('search_rate_limits', 'user_id',
    'search_rate_limits.user_id is NOT NULL');
SELECT col_type_is('search_rate_limits', 'window_start', 'timestamp with time zone',
    'search_rate_limits.window_start is timestamptz');
SELECT col_not_null('search_rate_limits', 'window_start',
    'search_rate_limits.window_start is NOT NULL');
SELECT col_default_is('search_rate_limits', 'window_start', 'now()',
    'search_rate_limits.window_start defaults now()');
SELECT col_type_is('search_rate_limits', 'search_count', 'integer',
    'search_rate_limits.search_count is integer');
SELECT col_not_null('search_rate_limits', 'search_count',
    'search_rate_limits.search_count is NOT NULL');
SELECT col_default_is('search_rate_limits', 'search_count', '0',
    'search_rate_limits.search_count defaults 0');
SELECT fk_ok('search_rate_limits', ARRAY['user_id'::name], 'users', ARRAY['id'::name],
    'search_rate_limits.user_id cascades from users.id (ON DELETE CASCADE)');
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.search_rate_limits'::regclass),
    'search_rate_limits has RLS enabled'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.search_rate_limits'::regclass),
    'search_rate_limits has FORCE ROW LEVEL SECURITY'
);
SELECT ok(
    NOT has_table_privilege('anon', 'public.search_rate_limits', 'SELECT'),
    'anon holds NO privilege on search_rate_limits'
);
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.search_rate_limits', 'INSERT'),
    'authenticated holds NO write privilege on search_rate_limits'
);

-- 61c: prefix index
SELECT ok(
    (SELECT count(*) = 1 FROM pg_indexes
     WHERE indexname = 'idx_users_username_prefix'
       AND indexdef ILIKE '%text_pattern_ops%'),
    'idx_users_username_prefix uses text_pattern_ops (ILIKE-prefix index scans)'
);

-- 61d: behavior under JWT claims
SELECT lives_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('88888888-8888-8888-8888-888888881101', 'pgtapsearcha', DATE '1990-06-01')$$,
    'search fixture A inserted (privileged, CHECK-compliant)'
);
SELECT lives_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('88888888-8888-8888-8888-888888881102', 'pgtapsearchb', DATE '1990-06-02')$$,
    'search fixture B inserted'
);
SELECT set_config('request.jwt.claims',
    '{"sub":"88888888-8888-8888-8888-888888881101","role":"authenticated"}', false);
-- Q8: set B public for the prefix test; keep A private for the exact test.
UPDATE public.users SET profile_public = true
 WHERE id = '88888888-8888-8888-8888-888888881102';
SELECT is(
    (SELECT count(*) FROM public.search_users('pgtapsea')),
    1::bigint,
    'prefix match returns only the OTHER opted-in user (caller excluded)'
);
UPDATE public.users SET profile_public = false
 WHERE id = '88888888-8888-8888-8888-888888881102';
SELECT is(
    (SELECT count(*) FROM public.search_users('pgtapsea')),
    0::bigint,
    'private profile is NOT returned by a prefix (Q8)'
);
SELECT is(
    (SELECT count(*) FROM public.search_users('PGTAPSEARCHB')),
    1::bigint,
    'private profile is found by exact username, case-insensitively (Q8)'
);
SELECT throws_ok($$SELECT public.search_users('pgta')$$,
    'SR002', 'invalid_query_length',
    'sub-5-char query rejected (SR002)');
SELECT throws_ok(
    $$SELECT public.search_users('pgtapsearchapgtapsearchapgtapsearchapgtapsearchapgtapsea')$$,
    'SR002', 'invalid_query_length',
    '51-char query rejected (SR002)'
);
SELECT set_config('request.jwt.claims', '', false);
SELECT throws_ok($$SELECT public.search_users('pgtapsea')$$,
    'SR003', 'not_authenticated',
    'anon caller rejected (SR003)');
SELECT set_config('request.jwt.claims',
    '{"sub":"88888888-8888-8888-8888-888888881101","role":"authenticated"}', false);
SELECT lives_ok(
    $$INSERT INTO public.search_rate_limits (user_id, window_start, search_count)
      VALUES ('88888888-8888-8888-8888-888888881101', now(), 60)
      ON CONFLICT (user_id) DO UPDATE SET search_count = 60, window_start = now()$$,
    'quota counter seeded to 60 (service-side, mirrors opt-015)'
);
SELECT throws_ok($$SELECT public.search_users('pgtapsea')$$,
    'SR001', 'search_rate_limit_exceeded',
    '61st search inside the window raises SR001');
UPDATE public.search_rate_limits
   SET window_start = now() - interval '2 minutes'
 WHERE user_id = '88888888-8888-8888-8888-888888881101';
SELECT lives_ok($$SELECT public.search_users('pgtapsea')$$,
    'expired window resets the quota (call succeeds again)');
SELECT is(
    (SELECT count(*) FROM public.search_users('pgtapsea_%')),
    0::bigint,
    'LIKE wildcards in the query are escaped (no %/_ expansion)'
);
SELECT set_config('request.jwt.claims', '', true);

-- ============================================================
-- SECTION 61e: event discovery search (baseline 131_events_search) —
-- search_events(p_query, p_lat, p_lng, p_radius_km, p_limit) SECURITY
-- DEFINER + public.haversine_km helper. Same SR001/SR002/SR003 hardening as
-- search_users, plus server-side radius filtering HARD-CAPPED at 100 km and
-- the accepted-friend activity signal (friends_going + 0.5 * friends_pending).
-- ============================================================
SELECT has_function('search_events',
    ARRAY['text', 'double precision', 'double precision', 'double precision', 'integer'],
    'search_events(p_query text, p_lat float8, p_lng float8, p_radius_km float8, p_limit int) exists (131_events_search)');
SELECT is_definer('public', 'search_events',
    ARRAY['text', 'double precision', 'double precision', 'double precision', 'integer'],
    'search_events is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
       FROM pg_proc WHERE proname = 'search_events'),
    'search_events sets search_path = '''' (131_events_search)'
);
SELECT function_privs_are('public', 'search_events',
    ARRAY['text', 'double precision', 'double precision', 'double precision', 'integer']::name[],
    'public', ARRAY[]::name[],
    'search_events is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'search_events',
    ARRAY['text', 'double precision', 'double precision', 'double precision', 'integer']::name[],
    'authenticated', ARRAY['EXECUTE'],
    'search_events is authenticated-EXECUTABLE');
SELECT has_function('haversine_km',
    ARRAY['double precision', 'double precision', 'double precision', 'double precision'],
    'haversine_km(lat1, lng1, lat2, lng2) exists (131_events_search)');
SELECT ok(
    public.haversine_km(-16.4090, -71.5375, -16.4090, -71.5375) < 0.001,
    'haversine_km is 0 for identical points'
);
SELECT ok(
    public.haversine_km(-16.4090, -71.5375, -12.0464, -77.0428) BETWEEN 700 AND 800,
    'haversine_km Arequipa-Lima is ~766 km'
);

-- 61e fixtures: caller + 2 accepted friends + 2 public events (near / ~167 km far)
SELECT lives_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('88888888-8888-8888-8888-888888882101', 'pgtapeventsa', DATE '1990-07-01'),
        ('88888888-8888-8888-8888-888888882102', 'pgtapeventsb', DATE '1990-07-02'),
        ('88888888-8888-8888-8888-888888882103', 'pgtapeventsc', DATE '1990-07-03')$$,
    'event-search fixture users inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.friendships (requester_id, addressee_id, status) VALUES
        ('88888888-8888-8888-8888-888888882101', '88888888-8888-8888-8888-888888882102', 'accepted'),
        ('88888888-8888-8888-8888-888888882101', '88888888-8888-8888-8888-888888882103', 'accepted')$$,
    'event-search fixture friendships inserted (2 accepted)'
);
SELECT lives_ok(
    $$INSERT INTO public.events
        (id, name, type, created_by_user_id, location_name, location_lat, location_lng,
         starts_at, ends_at, capacity, status)
      VALUES
        ('88888888-8888-8888-8888-888888882201', 'pgtap near event', 'casual',
         '88888888-8888-8888-8888-888888882101', 'Arequipa', -16.4090, -71.5375,
         now() + interval '2 days', now() + interval '2 days 4 hours', 5, 'upcoming'),
        ('88888888-8888-8888-8888-888888882202', 'pgtap far event', 'casual',
         '88888888-8888-8888-8888-888888882101', 'Far', -15.0000, -71.0000,
         now() + interval '3 days', now() + interval '3 days 4 hours', 5, 'upcoming')$$,
    'event-search fixture events inserted (near + ~167 km far)'
);
SELECT lives_ok(
    $$INSERT INTO public.event_invites (event_id, user_id, invited_by_user_id, status) VALUES
        ('88888888-8888-8888-8888-888888882201', '88888888-8888-8888-8888-888888882102', '88888888-8888-8888-8888-888888882101', 'accepted'),
        ('88888888-8888-8888-8888-888888882201', '88888888-8888-8888-8888-888888882103', '88888888-8888-8888-8888-888888882101', 'pending')$$,
    'event-search fixture invites inserted (friend going + friend pending)'
);

SELECT set_config('request.jwt.claims', '', true);
SELECT throws_ok($$SELECT public.search_events('abc')$$,
    'SR003', 'not_authenticated',
    'search_events anon caller rejected (SR003)');
SELECT set_config('request.jwt.claims',
    '{"sub":"88888888-8888-8888-8888-888888882101","role":"authenticated"}', false);
SELECT throws_ok($$SELECT public.search_events('a')$$,
    'SR002', 'invalid_query_length',
    'search_events 1-char query rejected (SR002)');
SELECT throws_ok(
    $$SELECT public.search_events('pgtapsearchapgtapsearchapgtapsearchapgtapsearchapgtapsea')$$,
    'SR002', 'invalid_query_length',
    'search_events 51-char query rejected (SR002)'
);
SELECT is(
    (SELECT count(*) FROM public.search_events(p_query => 'pgtap near')
      WHERE name = 'pgtap near event'),
    1::bigint,
    'text search matches the near event by name'
);
SELECT is(
    (SELECT count(*) FROM public.search_events(p_query => 'zzz no match zzz')),
    0::bigint,
    'text search with no match returns 0 rows'
);
SELECT is(
    (SELECT count(*) FROM public.search_events(
        p_query => 'pgtap', p_lat => -16.4090, p_lng => -71.5375, p_radius_km => 50)
      WHERE name LIKE 'pgtap%'),
    1::bigint,
    '50 km radius returns only the near fixture event'
);
SELECT is(
    (SELECT count(*) FROM public.search_events(
        p_query => 'pgtap', p_lat => -16.4090, p_lng => -71.5375, p_radius_km => 1000)
      WHERE name LIKE 'pgtap%'),
    1::bigint,
    'radius is hard-capped at 100 km (a 1000 km request still excludes the far event)'
);
SELECT is(
    (SELECT friends_going FROM public.search_events(p_query => 'pgtap near')
      WHERE name = 'pgtap near event'),
    1,
    'friends_going counts the accepted friend invite'
);
SELECT is(
    (SELECT friends_pending FROM public.search_events(p_query => 'pgtap near')
      WHERE name = 'pgtap near event'),
    1,
    'friends_pending counts the pending friend invite'
);
SELECT is(
    (SELECT score::numeric FROM public.search_events(p_query => 'pgtap near')
      WHERE name = 'pgtap near event'),
    1.5::numeric,
    'discovery score weights pending invites at half (1 + 0.5)'
);
SELECT set_config('request.jwt.claims', '', true);

-- ============================================================
-- SECTION 49d: Minigame partida names (migration 160_minigame_names) —
-- the per-game page flow lets a player name their partida (or fall back to
-- the auto "partida-XX" display): minigame_sessions.name carries the
-- optional user-supplied title, and create_minigame_session gains the
-- nullable p_name text argument (the 4-arg overload is dropped — CREATE OR
-- REPLACE cannot change the argument list).
-- ============================================================
SELECT has_column('minigame_sessions', 'name',
    'minigame_sessions.name exists (160_minigame_names)');
SELECT col_is_null('minigame_sessions', 'name',
    'minigame_sessions.name is NULLABLE (null/empty = auto "partida-XX" display, 160_minigame_names)');
SELECT has_function('create_minigame_session', ARRAY['uuid', 'text', 'integer', 'uuid[]', 'text', 'integer', 'integer', 'text', 'boolean', 'integer', 'timestamp with time zone'],
    'create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text, p_rounds integer, p_prize_positions integer, p_play_mode text, p_anonymous boolean, p_async_rounds_per_player integer, p_async_ends_at timestamp with time zone) exists (202_minigame_play_v2)');
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'create_minigame_session'
          AND pronargs = 4
          AND pg_get_function_arguments(pg_proc.oid) LIKE '%uuid[], text%'
    ),
    'the pre-name 4-arg create_minigame_session overload is dropped (CREATE OR REPLACE cannot change the arg list)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%INSERT INTO public.minigame_sessions%'
       AND pg_get_functiondef(p.oid) LIKE '%name%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session stores p_name on the session row (160_minigame_names)'
);
SELECT function_privs_are('public', 'create_minigame_session', ARRAY['uuid', 'text', 'integer', 'uuid[]', 'text', 'integer', 'integer', 'text', 'boolean', 'integer', 'timestamp with time zone']::name[], 'public', ARRAY[]::name[],
    'create_minigame_session is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'create_minigame_session', ARRAY['uuid', 'text', 'integer', 'uuid[]', 'text', 'integer', 'integer', 'text', 'boolean', 'integer', 'timestamp with time zone']::name[], 'authenticated', ARRAY['EXECUTE'],
    'create_minigame_session is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT prosecdef FROM pg_proc
     WHERE proname = 'create_minigame_session'
       AND pg_get_function_arguments(pg_proc.oid) LIKE '%p_rounds integer%'),
    'create_minigame_session is SECURITY DEFINER'
);
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc
     WHERE proname = 'create_minigame_session'
       AND pg_get_function_arguments(pg_proc.oid) LIKE '%p_rounds integer%'),
    'create_minigame_session sets search_path = '''' (I-31 pattern)'
);

-- ============================================================
-- SECTION 49e: get_friend_profiles(uuid[]) — batched accepted-friend profile
-- resolution for the on-device friends cache (130_search/02_get_friend_profiles,
-- 2026-08-30). SECURITY DEFINER + empty search_path + PUBLIC-revoked +
-- authenticated-EXECUTABLE, scoped to auth.uid()'s accepted friendships only.
-- ============================================================
SELECT has_function('get_friend_profiles', ARRAY['uuid[]'],
    'get_friend_profiles(uuid[]) exists (130_search/02_get_friend_profiles)');
SELECT is_definer('public', 'get_friend_profiles', ARRAY['uuid[]'],
    'get_friend_profiles is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'get_friend_profiles'),
    'get_friend_profiles sets search_path = '''' '
);
SELECT function_privs_are('public', 'get_friend_profiles', ARRAY['uuid[]']::name[], 'public', ARRAY[]::name[],
    'get_friend_profiles is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'get_friend_profiles', ARRAY['uuid[]']::name[], 'authenticated', ARRAY['EXECUTE'],
    'get_friend_profiles is authenticated-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%user_search_view%'
       AND pg_get_functiondef(p.oid) LIKE '%auth.uid()%'
     FROM pg_proc p WHERE proname = 'get_friend_profiles'),
    'get_friend_profiles reads user_search_view scoped by auth.uid() (accepted friends only)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%status = ''accepted''%'
     FROM pg_proc p WHERE proname = 'get_friend_profiles'),
    'get_friend_profiles returns only ACCEPTED friendships'
);

-- ============================================================
-- SECTION 49f: Minigame invite badges (migration 170_minigame_invite_badges,
-- 2026-08-30) — invitee-side "partida-N" + per-game feed badges:
--   * minigame_sessions.auto_name — the server-computed partida-N running
--     number per game_type among ACTIVE sessions, stored so creator AND
--     invitee resolve the SAME canonical name from the row in isolation
--     (160 kept the auto-name client-side from a list index, which is not
--     resolvable for a session shown alone). Duplicates allowed.
--   * create_minigame_session (same 5-arg signature as 160, CREATE OR
--     REPLACE) computes + stores auto_name at creation.
--   * notify_minigame_invite now fires for BOTH direct and group sessions
--     (the 140 early-return for group_id IS NULL is gone) and carries
--     gameType + sessionName in the notification data so the client groups
--     the per-game badge without an extra query.
-- ============================================================
SELECT has_column('minigame_sessions', 'auto_name',
    'minigame_sessions.auto_name exists (170_minigame_invite_badges)');
SELECT col_is_null('minigame_sessions', 'auto_name',
    'minigame_sessions.auto_name is NULLABLE (fallback when no auto name was computed)');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%auto_name%'
       AND pg_get_functiondef(p.oid) LIKE '%partida-''%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session computes and stores the server-side partida-N auto_name (170_minigame_invite_badges)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%INSERT INTO public.minigame_sessions%'
       AND pg_get_functiondef(p.oid) LIKE '%auto_name%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session inserts the auto_name column (170_minigame_invite_badges)'
);
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'notify_minigame_invite_trigger'
          AND tgrelid = 'public.minigame_sessions'::regclass
    ),
    'notify_minigame_invite_trigger stays on minigame_invites (170 keeps the 140 placement)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%gameType%'
       AND pg_get_functiondef(p.oid) LIKE '%sessionName%'
     FROM pg_proc p WHERE proname = 'notify_minigame_invite'),
    'notify_minigame_invite payload carries gameType + sessionName (170_minigame_invite_badges)'
);
SELECT ok(
    NOT (SELECT pg_get_functiondef(p.oid) LIKE '%v_group_id IS NULL THEN%'
             AND pg_get_functiondef(p.oid) LIKE '%RETURN NEW;%'
         FROM pg_proc p WHERE proname = 'notify_minigame_invite'),
    'notify_minigame_invite no longer early-returns for DIRECT sessions (170 fires for both scopes)'
);

-- ============================================================
-- SECTION 49g: Minigame partida lobby (migration
-- 180_minigame_lobby, 2026-08-30) — realtime participant list, per-player
-- Ready, creator-only Start, creator removal:
--   * minigame_game_state.ready — the authoritative jsonb ready map
--     ({participant_id: bool}), written ONLY through set_minigame_ready and
--     streamed live via the existing minigame_game_state realtime
--     subscription.
--   * set_minigame_ready(uuid, boolean) — SECURITY DEFINER intent handler:
--     standing gate (participant/invitee/group-member) + active-session
--     gate, then upserts the caller's flag into the ready map.
--   * get_minigame_participants(uuid) — SECURITY DEFINER roster resolution
--     (id/username/avatar_url) through user_search_view, works for
--     NON-friends, I-57 typed-jsonb-status contract.
--   * remove_minigame_participant(uuid, uuid) — SECURITY DEFINER
--     CREATOR-ONLY removal: refunds the wager escrow (minigame_refund),
--     drops the participant, deletes their invite, clears their ready flag.
--   * init_minigame_game_state — CREATE OR REPLACE with a SERVER-SIDE
--     creator gate (participants[0] only → not_creator) so Start is
--     backend-enforced, never just a UI rule; ready map clears on init.
--   * minigame_sessions JOINS supabase_realtime so participant join/remove
--     UPDATEs stream LIVE to the lobby.
-- ============================================================
SELECT has_column('minigame_game_state', 'ready',
    'minigame_game_state.ready exists (180_minigame_lobby)');
SELECT col_is_null('minigame_game_state', 'ready',
    'minigame_game_state.ready is NULLABLE (absent = nobody ready)');

SELECT has_function('set_minigame_ready', ARRAY['uuid', 'boolean'],
    'set_minigame_ready(p_session_id uuid, p_ready boolean) exists (180_minigame_lobby)');
SELECT is_definer('public', 'set_minigame_ready', ARRAY['uuid', 'boolean'],
    'set_minigame_ready is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'set_minigame_ready'),
    'set_minigame_ready sets search_path = '''' (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%jsonb_build_object(auth.uid()::text, p_ready)%'
       AND pg_get_functiondef(p.oid) LIKE '%ready%'
     FROM pg_proc p WHERE proname = 'set_minigame_ready'),
    'set_minigame_ready upserts the caller''s flag into the ready map keyed by auth.uid()'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''not_allowed''%'
       AND pg_get_functiondef(p.oid) LIKE '%public.minigame_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%public.group_members%'
     FROM pg_proc p WHERE proname = 'set_minigame_ready'),
    'set_minigame_ready gates by participant / invitee / group-member standing (not_allowed)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''session_not_active''%'
     FROM pg_proc p WHERE proname = 'set_minigame_ready'),
    'set_minigame_ready rejects toggles on finished sessions (session_not_active)'
);
SELECT function_privs_are('public', 'set_minigame_ready', ARRAY['uuid', 'boolean']::name[], 'public', ARRAY[]::name[],
    'set_minigame_ready is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'set_minigame_ready', ARRAY['uuid', 'boolean']::name[], 'authenticated', ARRAY['EXECUTE'],
    'set_minigame_ready is authenticated-EXECUTABLE');

SELECT has_function('get_minigame_participants', ARRAY['uuid'],
    'get_minigame_participants(p_session_id uuid) exists (180_minigame_lobby)');
SELECT is_definer('public', 'get_minigame_participants', ARRAY['uuid'],
    'get_minigame_participants is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'get_minigame_participants'),
    'get_minigame_participants sets search_path = '''' (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.user_search_view%'
     FROM pg_proc p WHERE proname = 'get_minigame_participants'),
    'get_minigame_participants resolves the roster through user_search_view (works for non-friends)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%jsonb_build_object(%''id'', usv.id%'
       AND pg_get_functiondef(p.oid) LIKE '%jsonb_agg%'
     FROM pg_proc p WHERE proname = 'get_minigame_participants'),
    'get_minigame_participants returns the I-57 typed jsonb roster (id/username/avatar_url)'
);
SELECT function_privs_are('public', 'get_minigame_participants', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'get_minigame_participants is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'get_minigame_participants', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'get_minigame_participants is authenticated-EXECUTABLE');

SELECT has_function('remove_minigame_participant', ARRAY['uuid', 'uuid'],
    'remove_minigame_participant(p_session_id uuid, p_user_id uuid) exists (180_minigame_lobby)');
SELECT is_definer('public', 'remove_minigame_participant', ARRAY['uuid', 'uuid'],
    'remove_minigame_participant is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'remove_minigame_participant'),
    'remove_minigame_participant sets search_path = '''' (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%v_participants[1] <> auth.uid()%'
       AND pg_get_functiondef(p.oid) LIKE '%''not_creator''%'
     FROM pg_proc p WHERE proname = 'remove_minigame_participant'),
    'remove_minigame_participant is CREATOR-ONLY, backend-enforced via participants[0] (not_creator)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%minigame_refund%'
       AND pg_get_functiondef(p.oid) LIKE '%personal_shards + v_wager%'
     FROM pg_proc p WHERE proname = 'remove_minigame_participant'),
    'remove_minigame_participant refunds the removed player''s wager escrow (GWAG minigame_refund)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%DELETE FROM public.minigame_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%ready - p_user_id::text%'
     FROM pg_proc p WHERE proname = 'remove_minigame_participant'),
    'remove_minigame_participant closes the invite and clears the ready flag'
);
SELECT function_privs_are('public', 'remove_minigame_participant', ARRAY['uuid', 'uuid']::name[], 'public', ARRAY[]::name[],
    'remove_minigame_participant is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'remove_minigame_participant', ARRAY['uuid', 'uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'remove_minigame_participant is authenticated-EXECUTABLE');

SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''not_creator''%'
       AND pg_get_functiondef(p.oid) LIKE '%v_participants[1] <> auth.uid()%'
     FROM pg_proc p WHERE proname = 'init_minigame_game_state'),
    'init_minigame_game_state is CREATOR-ONLY, backend-enforced via participants[0] (not_creator, 180_minigame_lobby)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%ready%'
       AND pg_get_functiondef(p.oid) LIKE '%''{}''::jsonb%'
     FROM pg_proc p WHERE proname = 'init_minigame_game_state'),
    'init_minigame_game_state seeds an empty ready map on start (lobby roster resets)'
);
SELECT ok(
    EXISTS (SELECT 1 FROM pg_publication_tables
            WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_sessions'),
    'minigame_sessions joins supabase_realtime (participant join/remove streams live to the lobby, 180_minigame_lobby)'
);
SELECT ok(
    (SELECT relreplident = 'f' FROM pg_class WHERE oid = 'public.minigame_sessions'::regclass),
    'minigame_sessions has REPLICA IDENTITY FULL (full-row realtime UPDATE payloads — the roster diff always has the authoritative participants array, 2026-09-02)'
);

-- SECTION 49h: Minigame game-state at creation (migration
-- 191_minigame_game_state_at_creation, 2026-08-30) — the minigame_game_state
-- row exists FROM session creation so every ready toggle is an UPDATE
-- (streamed by the update-only realtime subscription from the first one).
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%INSERT INTO public.minigame_game_state (session_id, game_type, state, ready)%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session seeds the minigame_game_state row at creation (191)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%UPDATE public.minigame_game_state%'
       AND NOT pg_get_functiondef(p.oid) LIKE '%ON CONFLICT (session_id) DO UPDATE%'
     FROM pg_proc p WHERE proname = 'set_minigame_ready'),
    'set_minigame_ready is a plain UPDATE (row exists at creation, 191)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%jsonb_build_object(auth.uid()::text, p_ready)%'
     FROM pg_proc p WHERE proname = 'set_minigame_ready'),
    'set_minigame_ready still upserts the caller''s ready flag keyed by auth.uid()'
);

-- SECTION 49i: Minigame invite notice (migration 200_minigame_invite_notice,
-- 2026-08-30) — the invite notification must state the wager explicitly (the
-- amount taken from each participant until the game ends or is cancelled; a
-- player without the funds cannot participate — accept enforces
-- insufficient_shards server-side) AND identify the inviter (the username for
-- a DIRECT session, or the group name for a GROUP session):
--   * notify_minigame_invite reads shard_wager from the session.
--   * The body states the cost: "{N} shards." when wagered, "FREE" for a
--     free (0-wager) game.
--   * The data payload carries "wager" so clients render the cost without a
--     re-query, plus "inviterName" (user_search_view) and "groupName" (the
--     group row, null for direct) — the RLS-invisible who-invited context the
--     accept surfaces must show. gameType + sessionName + sessionId + inviteId
--     stay intact.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%shard_wager%'
     FROM pg_proc p WHERE proname = 'notify_minigame_invite'),
    'notify_minigame_invite reads shard_wager from the session (200_minigame_invite_notice)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%shards.%'
       AND pg_get_functiondef(p.oid) LIKE '%FREE%'
     FROM pg_proc p WHERE proname = 'notify_minigame_invite'),
    'notify_minigame_invite body states the cost explicitly: "{N} shards." or "FREE" for free games'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''wager'', v_wager%'
     FROM pg_proc p WHERE proname = 'notify_minigame_invite'),
    'notify_minigame_invite data payload carries the wager amount (200_minigame_invite_notice)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%inviterName%'
       AND pg_get_functiondef(p.oid) LIKE '%user_search_view%'
     FROM pg_proc p WHERE proname = 'notify_minigame_invite'),
    'notify_minigame_invite resolves the inviter username via user_search_view (200_minigame_invite_notice)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%groupName%'
       AND pg_get_functiondef(p.oid) LIKE '%public.groups%'
     FROM pg_proc p WHERE proname = 'notify_minigame_invite'),
    'notify_minigame_invite resolves the group name for group sessions (200_minigame_invite_notice)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%gameType%'
       AND pg_get_functiondef(p.oid) LIKE '%sessionName%'
     FROM pg_proc p WHERE proname = 'notify_minigame_invite'),
    'notify_minigame_invite keeps gameType + sessionName in the payload (170 stays intact)'
);

-- SECTION 49j: Minigame rounds + reaction voting + leaderboard (migration
-- 201_minigame_voting, 2026-08-30) — the round target, the paid-position
-- count N, the realtime emoji voting, and the harmonic leaderboard payout:
--   * minigame_sessions.round_target (int) + prize_positions (int, default 3)
--     frozen at creation by the 7-arg create_minigame_session
--     (+ p_rounds, p_prize_positions).
--   * minigame_reactions — one vote per (session, round, voter), FORCE RLS,
--     reads by participants/invitees/group members, writes ONLY through
--     submit_minigame_reaction.
--   * minigame_results — the settle-once leaderboard row, FORCE RLS, written
--     ONLY by finish_minigame_game.
--   * submit_minigame_reaction(uuid, text) — SECURITY DEFINER, idempotent
--     upsert + realtime mirror into state.reactions.
--   * finish_minigame_game(uuid) — SECURITY DEFINER settlement replacing
--     finish_minigame_session + complete_minigame_game: HARMONIC prize split
--     (1/rank weights, integer-exact, sum == pot).
--   * advance_minigame_turn (CREATE OR REPLACE) scores the round server-side
--     and AUTO-FINISHES at round_target.
SELECT has_column('minigame_sessions', 'round_target',
    'minigame_sessions.round_target exists (201_minigame_voting)');
SELECT col_is_null('minigame_sessions', 'round_target',
    'minigame_sessions.round_target is NULLABLE (legacy open-ended games)');
SELECT has_column('minigame_sessions', 'prize_positions',
    'minigame_sessions.prize_positions exists (201_minigame_voting)');
SELECT col_not_null('minigame_sessions', 'prize_positions',
    'minigame_sessions.prize_positions is NOT NULL (default 3)');
SELECT col_has_default('minigame_sessions', 'prize_positions',
    'minigame_sessions.prize_positions defaults to 3');

SELECT has_table('minigame_reactions',
    'minigame_reactions exists (201_minigame_voting)');
SELECT col_not_null('minigame_reactions', 'voter_id',
    'minigame_reactions.voter_id is NOT NULL (one vote per voter per round)');
SELECT has_table('minigame_results',
    'minigame_results exists (201_minigame_voting)');

SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'minigame_reactions'::regclass),
    'minigame_reactions has FORCE ROW LEVEL SECURITY (201_minigame_voting)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'minigame_results'::regclass),
    'minigame_results has FORCE ROW LEVEL SECURITY (201_minigame_voting)'
);
SELECT policies_are('minigame_reactions', ARRAY['mgs_reactions_read', 'active_users_only'
],
    'minigame_reactions has exactly the participant-read policy (201_minigame_voting)');
SELECT policies_are('minigame_results', ARRAY['mgs_results_read', 'active_users_only'
],
    'minigame_results has exactly the participant-read policy (201_minigame_voting)');

SELECT has_function('submit_minigame_reaction', ARRAY['uuid', 'text'],
    'submit_minigame_reaction(p_session_id uuid, p_reaction text) exists (201_minigame_voting)');
SELECT is_definer('public', 'submit_minigame_reaction', ARRAY['uuid', 'text'],
    'submit_minigame_reaction is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction sets search_path = '''' (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.minigame_reactions%'
       AND pg_get_functiondef(p.oid) LIKE '%ON CONFLICT (session_id, round, voter_id) DO UPDATE%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction upserts one vote per (session, round, voter)'
);

SELECT function_privs_are('public', 'submit_minigame_reaction', ARRAY['uuid', 'text']::name[], 'public', ARRAY[]::name[],
    'submit_minigame_reaction is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'submit_minigame_reaction', ARRAY['uuid', 'text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'submit_minigame_reaction is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'finish_minigame_game', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'finish_minigame_game is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'finish_minigame_game', ARRAY['uuid']::name[], 'authenticated', ARRAY[]::name[],
    'finish_minigame_game is server-only (authenticated cannot settle)');
SELECT function_privs_are('public', 'finish_minigame_game', ARRAY['uuid']::name[], 'service_role', ARRAY['EXECUTE'],
    'finish_minigame_game is service_role-EXECUTABLE');

SELECT has_function('finish_minigame_game', ARRAY['uuid'],
    'finish_minigame_game(p_session_id uuid) exists (201_minigame_voting)');
SELECT is_definer('public', 'finish_minigame_game', ARRAY['uuid'],
    'finish_minigame_game is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'finish_minigame_game'),
    'finish_minigame_game sets search_path = '''' (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.minigame_results%'
       AND pg_get_functiondef(p.oid) LIKE '%gcd%'
     FROM pg_proc p WHERE proname = 'finish_minigame_game'),
    'finish_minigame_game writes minigame_results with harmonic (gcd) weights'
);

-- SECTION 49u: Full leaderboard ranking (migration 218_minigame_full_ranking,
-- 2026-09-20) — the settle-once leaderboard now carries EVERY participant with
-- their row_number() rank + real score; only the top N = prize_positions are
-- PAID (rank > N writes prize 0):
--   * the two per-branch `WHERE sc.rank <= v_prize_positions` filters are GONE,
--     so the result set is the FULL ranked roster.
--   * the harmonic weights still cap the PAID ranks at prize_positions.
--   * minigame_sessions has NO column `n`: the app's session select + pool
--     breakdown must read `prize_positions` (a client selecting `n` 400s the
--     whole session read — regression guard for the 2026-09-20 breakage).
SELECT ok(
    (SELECT position('sc.rank <= v_prize_positions' IN pg_get_functiondef(p.oid)) = 0
       AND pg_get_functiondef(p.oid) LIKE '%row_number() OVER%'
     FROM pg_proc p WHERE proname = 'finish_minigame_game'),
    'finish_minigame_game ranks ALL participants (no prize-position WHERE filter, 218_minigame_full_ranking)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%LEAST(COALESCE(v_prize_positions, 3), v_player_count)%'
       AND pg_get_functiondef(p.oid) LIKE '%public.minigame_results%'
     FROM pg_proc p WHERE proname = 'finish_minigame_game'),
    'finish_minigame_game still caps the PAID ranks at prize_positions (218_minigame_full_ranking)'
);
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'minigame_sessions'
          AND column_name = 'n'
    ),
    'minigame_sessions has no column "n" — clients must read prize_positions (2026-09-20 regression guard)'
);

-- The legacy settlement seams are REPLACED (201 user directive): the only
-- settlement RPC left is finish_minigame_game.
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'finish_minigame_session'),
    'finish_minigame_session is dropped (201 replaces the winner-takes-all seam)'
);
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'complete_minigame_game'),
    'complete_minigame_game is dropped (201 replaces the draw-only seam)'
);

-- The auto-finish at the total-turn target lives in the round-advance helper
-- (202 moved the advance out of advance_minigame_turn into _minigame_advance_round).
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%round_target%'
       AND pg_get_functiondef(p.oid) LIKE '%finish_minigame_game%'
     FROM pg_proc p WHERE proname = '_minigame_advance_round'),
    '_minigame_advance_round auto-finishes via finish_minigame_game at round_target (202)'
);

-- Realtime membership for the live votes + settled leaderboard.
SELECT ok(
    EXISTS (SELECT 1 FROM pg_publication_tables
            WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_reactions'),
    'minigame_reactions joins supabase_realtime (votes stream live, 201_minigame_voting)'
);
SELECT ok(
    EXISTS (SELECT 1 FROM pg_publication_tables
            WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_results'),
    'minigame_results joins supabase_realtime (leaderboard streams live, 201_minigame_voting)'
);

-- SECTION 49k: Minigame play engine v2 (migration 202_minigame_play_v2,
-- 2026-08-30) — answer-first, modes, anonymous, E2EE answers:
--   * minigame_sessions + play_mode (by_turns|async), + anonymous bool,
--     + async_rounds_per_player (default 1), + async_ends_at (settable at
--     creation, no override).
--   * minigame_aliases — (session, participant) temp nickname, FORCE RLS,
--     read by participants, written ONLY through set_minigame_alias.
--   * minigame_answers — E2EE answer store (ciphertext only), FORCE RLS,
--     written ONLY through submit_minigame_answer / submit_minigame_pasar /
--     submit_minigame_async_answer.
--   * minigame_e2ee_bundles — sender-key distribution delivery rows (own-row
--     INSERT + recipient-read SELECT policies).
--   * submit_minigame_answer(uuid, text, text) / submit_minigame_pasar(uuid) /
--     submit_minigame_async_answer(uuid, text, text, text) /
--     react_minigame_round(uuid, integer, text) / set_minigame_alias(uuid,
--     text) — SECURITY DEFINER, authenticated-only EXECUTE.
SELECT has_column('minigame_sessions', 'play_mode',
    'minigame_sessions.play_mode exists (202_minigame_play_v2)');
SELECT col_has_check('minigame_sessions', 'play_mode',
    'minigame_sessions.play_mode has a CHECK (by_turns|async)');
SELECT has_column('minigame_sessions', 'anonymous',
    'minigame_sessions.anonymous exists (202_minigame_play_v2)');
SELECT col_not_null('minigame_sessions', 'anonymous',
    'minigame_sessions.anonymous is NOT NULL (default false)');
SELECT has_column('minigame_sessions', 'async_rounds_per_player',
    'minigame_sessions.async_rounds_per_player exists (202_minigame_play_v2)');
SELECT has_column('minigame_sessions', 'async_ends_at',
    'minigame_sessions.async_ends_at exists (202_minigame_play_v2)');
SELECT col_is_null('minigame_sessions', 'async_ends_at',
    'minigame_sessions.async_ends_at is NULLABLE (NULL for by_turns)');

SELECT has_table('minigame_aliases',
    'minigame_aliases exists (202_minigame_play_v2)');
SELECT has_table('minigame_answers',
    'minigame_answers exists (202_minigame_play_v2)');
SELECT has_table('minigame_e2ee_bundles',
    'minigame_e2ee_bundles exists (202_minigame_play_v2)');

SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'minigame_aliases'::regclass),
    'minigame_aliases has FORCE ROW LEVEL SECURITY (202_minigame_play_v2)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'minigame_answers'::regclass),
    'minigame_answers has FORCE ROW LEVEL SECURITY (202_minigame_play_v2)'
);
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'minigame_e2ee_bundles'::regclass),
    'minigame_e2ee_bundles has FORCE ROW LEVEL SECURITY (202_minigame_play_v2)'
);
SELECT policies_are('minigame_aliases', ARRAY['mgs_aliases_read', 'active_users_only'
],
    'minigame_aliases has exactly the participant-read policy (202_minigame_play_v2)');
SELECT policies_are('minigame_answers', ARRAY['mgs_answers_read', 'active_users_only'
],
    'minigame_answers has exactly the participant-read policy (202_minigame_play_v2)');
SELECT policies_are('minigame_e2ee_bundles', ARRAY['mgs_bundles_insert_own', 'mgs_bundles_update_own', 'mgs_bundles_read_recipient', 'active_users_only'
],
    'minigame_e2ee_bundles has the own-insert + own-update + recipient-read policies (202_minigame_play_v2)');
-- The upsert-conflict leg of putE2eeBundle needs UPDATE privilege + policy
-- (2026-08-31 on-device 42501 fix). DELETE stays withheld — bundles are
-- additive/retained (no-wipe directive).
SELECT ok(
    (SELECT bool_and(privilege_type IN ('SELECT', 'INSERT', 'UPDATE'))
     FROM information_schema.role_table_grants
     WHERE table_schema = 'public' AND table_name = 'minigame_e2ee_bundles'
       AND grantee = 'authenticated'),
    'authenticated has exactly SELECT/INSERT/UPDATE on minigame_e2ee_bundles (no DELETE, 202)'
);
-- Supabase RLS rule "UPDATE requires a SELECT policy": the sender must be able
-- to SELECT its own outbound row for the upsert-conflict UPDATE (and for the
-- host's self-heal of its own minted keys). recipient-only read silently
-- no-oped every re-delivery (2026-08-31 on-device fix).
SELECT ok(
    (SELECT qual
       FROM pg_policies
      WHERE tablename = 'minigame_e2ee_bundles' AND policyname = 'mgs_bundles_read_recipient') LIKE '%sender_id = auth.uid()%',
    'mgs_bundles_read_recipient lets the SENDER read own outbound rows (UPDATE pre-SELECT + self-heal)'
);

SELECT has_function('submit_minigame_answer', ARRAY['uuid', 'text', 'text'],
    'submit_minigame_answer(p_session_id uuid, p_answer_ciphertext text, p_image_storage_path text) exists (202_minigame_play_v2)');
SELECT is_definer('public', 'submit_minigame_answer', ARRAY['uuid', 'text', 'text'],
    'submit_minigame_answer is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'submit_minigame_answer'),
    'submit_minigame_answer sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'submit_minigame_answer', ARRAY['uuid', 'text', 'text']::name[], 'public', ARRAY[]::name[],
    'submit_minigame_answer is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'submit_minigame_answer', ARRAY['uuid', 'text', 'text']::name[], 'authenticated', ARRAY['EXECUTE'],
    'submit_minigame_answer is authenticated-EXECUTABLE');

SELECT has_function('submit_minigame_pasar', ARRAY['uuid'],
    'submit_minigame_pasar(p_session_id uuid) exists (202_minigame_play_v2)');
SELECT is_definer('public', 'submit_minigame_pasar', ARRAY['uuid'],
    'submit_minigame_pasar is SECURITY DEFINER');

SELECT has_function('submit_minigame_async_answer', ARRAY['uuid', 'text', 'text', 'text'],
    'submit_minigame_async_answer(p_session_id uuid, p_prompt_type text, p_answer_ciphertext text, p_image_storage_path text) exists (202_minigame_play_v2)');
SELECT is_definer('public', 'submit_minigame_async_answer', ARRAY['uuid', 'text', 'text', 'text'],
    'submit_minigame_async_answer is SECURITY DEFINER');

SELECT has_function('react_minigame_round', ARRAY['uuid', 'integer', 'text'],
    'react_minigame_round(p_session_id uuid, p_round integer, p_reaction text) exists (202_minigame_play_v2)');
SELECT is_definer('public', 'react_minigame_round', ARRAY['uuid', 'integer', 'text'],
    'react_minigame_round is SECURITY DEFINER');

SELECT has_function('set_minigame_alias', ARRAY['uuid', 'text'],
    'set_minigame_alias(p_session_id uuid, p_alias text) exists (202_minigame_play_v2)');
SELECT is_definer('public', 'set_minigame_alias', ARRAY['uuid', 'text'],
    'set_minigame_alias is SECURITY DEFINER');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.minigame_aliases%'
       AND pg_get_functiondef(p.oid) LIKE '%ON CONFLICT (session_id, participant_id) DO UPDATE%'
     FROM pg_proc p WHERE proname = 'set_minigame_alias'),
    'set_minigame_alias upserts one temp nickname per (session, participant)'
);
-- 214_minigame_alias_unique: session-unique, case-insensitive nicknames.
SELECT ok(
    to_regclass('public.minigame_aliases_session_alias_uniq') IS NOT NULL,
    'minigame_aliases has a session+alias index (214_minigame_alias_unique)');
SELECT ok(
    (SELECT indisunique FROM pg_index
      WHERE indexrelid = 'minigame_aliases_session_alias_uniq'::regclass),
    'the nickname index is UNIQUE (session_id, lower(btrim(alias))) (214_minigame_alias_unique)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%alias_taken%'
       AND pg_get_functiondef(p.oid) LIKE '%lower(btrim(alias))%'
     FROM pg_proc p WHERE proname = 'set_minigame_alias'),
    'set_minigame_alias rejects a taken nickname (case-insensitive, 214_minigame_alias_unique)'
);

-- The answer-first reaction gate (202): the subject cannot react to their own
-- round and reactions open only after the answer (ciphertext) is submitted.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%own_round%'
       AND pg_get_functiondef(p.oid) LIKE '%answer_pending%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction enforces the own-round + answer-first gates (202_minigame_play_v2)'
);

-- The by_turns advance waits for every non-subject participant to react
-- (all-reacted contract) and lets the creator force-advance.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%waiting_reactions%'
       AND pg_get_functiondef(p.oid) LIKE '%v_required_count%'
       AND pg_get_functiondef(p.oid) LIKE '%distinct%'
       AND pg_get_functiondef(p.oid) LIKE '%_minigame_advance_round%'
     FROM pg_proc p WHERE proname = 'advance_minigame_turn'),
    'advance_minigame_turn waits for all reactions unless the creator forces (202_minigame_play_v2)'
);

-- The async timer auto-finish: pg_cron job + the lazy read flip.
SELECT ok(
    EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'minigames-async-finish'),
    'minigames-async-finish pg_cron job settles async sessions past their deadline (202_minigame_play_v2)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%async_ends_at%'
       AND pg_get_functiondef(p.oid) LIKE '%finish_minigame_game%'
     FROM pg_proc p WHERE proname = 'get_minigame_game_state'),
    'get_minigame_game_state lazy-flips an expired async timer to finished (202_minigame_play_v2)'
);

-- ======================================================================
-- SECTION 49m: host-device-confirmed countdown (203_minigame_host_start,
-- 2026-08-31) — start_minigame_match flips countdown → playing, creator-only.
-- ======================================================================
SELECT has_function('start_minigame_match', ARRAY['uuid'],
    'start_minigame_match(p_session_id uuid) exists (203_minigame_host_start)');
SELECT is_definer('public', 'start_minigame_match', ARRAY['uuid'],
    'start_minigame_match is SECURITY DEFINER');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%not_creator%'
       AND pg_get_functiondef(p.oid) LIKE '%''playing''%'
       AND pg_get_functiondef(p.oid) LIKE '%''countdown''%'
     FROM pg_proc p WHERE proname = 'start_minigame_match'),
    'start_minigame_match is creator-only (not_creator) and flips countdown → playing'
);
SELECT function_privs_are('public', 'start_minigame_match', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'start_minigame_match is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'start_minigame_match', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'start_minigame_match is authenticated-EXECUTABLE');

-- There is NO countdown_ends_at deadline (the countdown is host-device based):
-- init must not seed it and get must not lazy-flip on it.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) NOT LIKE '%countdown_ends_at%'
     FROM pg_proc p WHERE proname = 'init_minigame_game_state'),
    'init_minigame_game_state does NOT seed countdown_ends_at (host-device countdown, 203)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) NOT LIKE '%countdown_ends_at%'
     FROM pg_proc p WHERE proname = 'get_minigame_game_state'),
    'get_minigame_game_state has NO countdown lazy-flip (host confirms via start_minigame_match, 203)'
);

-- Realtime membership for the live aliases + answers.
SELECT ok(
    EXISTS (SELECT 1 FROM pg_publication_tables
            WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_aliases'),
    'minigame_aliases joins supabase_realtime (nicknames stream live, 202_minigame_play_v2)'
);
SELECT ok(
    EXISTS (SELECT 1 FROM pg_publication_tables
            WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_answers'),
    'minigame_answers joins supabase_realtime (answers stream live, 202_minigame_play_v2)'
);

-- ======================================================================
-- SECTION 49k (cont.): play-engine security hardening (2026-08-31) —
-- active-only group members, participant-only writers/bundles, distinct-
-- voter reaction counts (TODO.md §3.7 findings A–E).
-- ======================================================================

-- Finding A: the RLS read policies require gm.status='active' + not-deleted
-- (the ms_read_group_member / mgs_*_read status-less EXISTS was the hole).
SELECT ok(
    (SELECT pg_get_expr(polqual, polrelid) LIKE '%gm.status = ''active''%'
     FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
     WHERE p.polname = 'ms_read_group_member'),
    'ms_read_group_member requires gm.status = ''active'' (2026-08-31 hardening)'
);
SELECT ok(
    (SELECT pg_get_expr(polqual, polrelid) LIKE '%gm.status = ''active''%'
     FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
     WHERE p.polname = 'mgs_answers_read'),
    'mgs_answers_read requires gm.status = ''active'' (2026-08-31 hardening)'
);

-- Finding B: the play RPC group-member gates carry gm.status = 'active'.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%gm.status = ''active''%'
     FROM pg_proc p WHERE proname = 'get_minigame_game_state'),
    'get_minigame_game_state group-member gate requires gm.status = ''active'' (2026-08-31 hardening)'
);

-- Finding C: the reaction WRITER is participant-only.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%auth.uid() = ANY (v_participants)%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%minigame_invites mi%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction is participant-only (no invitee/group-member union) (2026-08-31 hardening)'
);

-- Finding D: mgs_bundles_insert_own dropped the invitee clause.
SELECT ok(
    NOT (SELECT pg_get_expr(polwithcheck, polrelid) LIKE '%minigame_invites%'
         FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
         WHERE p.polname = 'mgs_bundles_insert_own'),
    'mgs_bundles_insert_own no longer references minigame_invites (participant-only, 2026-08-31 hardening)'
);
SELECT ok(
    (SELECT pg_get_expr(polwithcheck, polrelid) LIKE '%recipient_id = ANY (s.participants)%'
     FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
     WHERE p.polname = 'mgs_bundles_insert_own'),
    'mgs_bundles_insert_own requires sender AND recipient to be participants (2026-08-31 hardening)'
);

-- Finding E + mirror shape: distinct-voter count + {"list","count"} mirror.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%count(distinct voter_id)%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction counts DISTINCT voters for the auto-advance gate (2026-08-31 hardening)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''list''%'
       AND pg_get_functiondef(p.oid) LIKE '%''count''%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction mirrors {"list": [...], "count": N} (2026-08-31 hardening)'
);

-- ======================================================================
-- SECTION 49l: encrypted image storage (2026-08-31) — TODO.md §4.6
-- Minigame image answers move from a DB column to a PRIVATE storage bucket:
--   * minigame_answers drops image_ciphertext and gains image_storage_path
--     (nullable; the bucket object path of the ENCRYPTED image bytes — the
--     server never sees plaintext or keys).
--   * submit_minigame_answer / submit_minigame_async_answer accept
--     p_image_storage_path text DEFAULT NULL and store that path (both on the
--     row and in the state mirror key 'image_storage_path').
--   * storage: private 'minigame_images' bucket + participant-gated SELECT
--     (storage_objects_minigame_images_select) + participant-only INSERT
--     (storage_objects_minigame_images_insert, session from path[1]).
-- ======================================================================

-- Column contract: image_storage_path replaces image_ciphertext.
SELECT ok(
    (SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
     WHERE c.relname = 'minigame_answers' AND a.attname = 'image_storage_path') = 1,
    'minigame_answers has image_storage_path (nullable bucket path, 2026-08-31)'
);
SELECT ok(
    (SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
     WHERE c.relname = 'minigame_answers' AND a.attname = 'image_ciphertext') = 0,
    'minigame_answers no longer has image_ciphertext (moved to storage, 2026-08-31)'
);
SELECT col_is_null('minigame_answers', 'image_storage_path',
    'minigame_answers.image_storage_path is NULLABLE (optional image answer, 2026-08-31)');

-- The by_turns answer RPC stores the storage path.
SELECT has_function('submit_minigame_answer', ARRAY['uuid', 'text', 'text'],
    'submit_minigame_answer(p_session_id uuid, p_answer_ciphertext text, p_image_storage_path text) exists (2026-08-31)');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%image_storage_path%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%image_ciphertext%'
     FROM pg_proc p WHERE proname = 'submit_minigame_answer'),
    'submit_minigame_answer stores image_storage_path and no longer references image_ciphertext (2026-08-31)'
);

-- The async answer RPC stores the storage path too.
SELECT has_function('submit_minigame_async_answer', ARRAY['uuid', 'text', 'text', 'text'],
    'submit_minigame_async_answer(p_session_id uuid, p_prompt_type text, p_answer_ciphertext text, p_image_storage_path text) exists (2026-08-31)');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%image_storage_path%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%image_ciphertext%'
     FROM pg_proc p WHERE proname = 'submit_minigame_async_answer'),
    'submit_minigame_async_answer stores image_storage_path and no longer references image_ciphertext (2026-08-31)'
);

-- The storage bucket is private + participant-gated object access.
SELECT ok(
    EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'minigame_images'),
    'minigame_images bucket exists (private encrypted-image storage, 2026-08-31)'
);
SELECT ok(
    NOT (SELECT public FROM storage.buckets WHERE id = 'minigame_images'),
    'minigame_images bucket is private (public=false, signed-URL retrieval only, 2026-08-31)'
);
SELECT policies_are('storage', 'objects',
    ARRAY['storage_objects_delete_own',
          'storage_objects_events_select_access',
          'storage_objects_insert_own',
          'storage_objects_minigame_images_insert',
          'storage_objects_minigame_images_select',
          'storage_objects_public_read_avatars_groups',
          'storage_objects_update_own'],
    'storage.objects carries the minigame_images select + insert policies (2026-08-31)');

-- The insert policy must read the object PATH (storage.objects.name), NOT the
-- correlated minigame_sessions.name column (partida name — NULL/empty for most
-- sessions). The 2026-09-01 column-shadow bug made foldername(name) resolve to
-- the session name → ''::uuid cast fails → every dare-with-image upload 403'd.
SELECT ok(
    (SELECT with_check FROM pg_policies
      WHERE schemaname = 'storage'
        AND tablename = 'objects'
        AND policyname = 'storage_objects_minigame_images_insert')
        ~ 'storage\.foldername\((storage\.)?objects\.name\)',
    'storage_objects_minigame_images_insert qualifies objects.name in the path foldername (2026-09-01)'
);

-- ======================================================================
-- SECTION 49o: lobby invite RPC (migration 205_minigame_invite_lobby,
-- 2026-09-01) — invite_minigame_players(p_session_id, p_invitees) invites
-- players into an ALREADY-CREATED session from the partida lobby (the
-- 2026-09-01 flow: create with zero invitees, then the HOST invites while
-- waiting). Mirrors the create-time validation block (blocked/deleted +
-- friends-only privacy, player-cap re-check) but is CREATOR-ONLY
-- (`participants[1]` gate, like Start/Remove) and idempotent (skips
-- self / already-participant / already-pending invitees — the
-- (session_id, invitee_id) UNIQUE keeps the table clean). The existing
-- notify_minigame_invite AFTER-INSERT trigger fires for each new row, so
-- notifications work unchanged.
-- ======================================================================
SELECT has_function('invite_minigame_players', ARRAY['uuid', 'uuid[]'],
    'invite_minigame_players(p_session_id uuid, p_invitees uuid[]) exists (205_minigame_invite_lobby)');
SELECT is_definer('public', 'invite_minigame_players', ARRAY['uuid', 'uuid[]']::name[],
    'invite_minigame_players is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'invite_minigame_players'),
    'invite_minigame_players sets search_path = "" (I-31 pattern)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''not_authenticated''%'
       AND pg_get_functiondef(p.oid) LIKE '%''session_not_found''%'
       AND pg_get_functiondef(p.oid) LIKE '%''session_not_active''%'
     FROM pg_proc p WHERE proname = 'invite_minigame_players'),
    'invite_minigame_players returns typed lifecycle statuses (I-57 contract)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''not_creator''%'
       AND pg_get_functiondef(p.oid) LIKE '%participants[1] <> v_current_user%'
     FROM pg_proc p WHERE proname = 'invite_minigame_players'),
    'invite_minigame_players is CREATOR-ONLY via participants[1] (not_creator)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.friendships%'
       AND pg_get_functiondef(p.oid) LIKE '%minigame_invite_friends_only%'
       AND pg_get_functiondef(p.oid) LIKE '%''invitee_friends_only''%'
     FROM pg_proc p WHERE proname = 'invite_minigame_players'),
    'invite_minigame_players enforces blocked + friends-only invite privacy server-side'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%v_player_limit%'
       AND pg_get_functiondef(p.oid) LIKE '%''player_limit_reached''%'
     FROM pg_proc p WHERE proname = 'invite_minigame_players'),
    'invite_minigame_players re-checks the frozen player cap (player_limit_reached)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%public.minigame_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%t.v <> ALL (v_participants)%'
       AND pg_get_functiondef(p.oid) LIKE '%t.v <> ALL (v_pending)%'
     FROM pg_proc p WHERE proname = 'invite_minigame_players'),
    'invite_minigame_players inserts pending rows and skips self / already-participant / already-pending invitees idempotently'
);
SELECT function_privs_are('public', 'invite_minigame_players', ARRAY['uuid', 'uuid[]']::name[], 'public', ARRAY[]::name[],
    'invite_minigame_players is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'invite_minigame_players', ARRAY['uuid', 'uuid[]']::name[], 'authenticated', ARRAY['EXECUTE'],
    'invite_minigame_players is authenticated-EXECUTABLE');

-- ======================================================================
-- SECTION 49n: reactor-side Pasar (migration 204_minigame_pasar,
-- 2026-09-01) — a NON-subject passes instead of emoji-reacting:
--   * minigame_reactions.reaction is NULLABLE (NULL = the pass marker) with a
--     CHECK keeping the six emoji values or NULL; the (session, round, voter)
--     PK still guarantees one action per voter per round.
--   * submit_minigame_reaction / react_minigame_round accept 'pasar' (upsert
--     a NULL-reaction row) and mirror a `pass` count into state.reactions.
--   * _minigame_advance_round scores emoji_count - pass_count/2 (integer-
--     normalized when integral; -1 when the round had ZERO emojis).
--   * finish_minigame_game settles fractional by_turns + async scores.
SELECT ok(
    (SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
     WHERE c.relname = 'minigame_reactions' AND a.attname = 'reaction' AND a.attnotnull) = 0,
    'minigame_reactions.reaction is NULLABLE (NULL = reactor Pasar, 204_minigame_pasar)'
);
SELECT col_has_check('minigame_reactions', 'reaction',
    'minigame_reactions.reaction has a CHECK (NULL or six emojis, 204_minigame_pasar)');
SELECT has_column('minigame_reactions', 'last_tap_at',
    'minigame_reactions.last_tap_at drives the server reaction spam gate (207, 2026-09-09)');
SELECT ok(
    (SELECT convalidated
       FROM pg_constraint
      WHERE conrelid = 'minigame_reactions'::regclass
        AND conname = 'mgs_reaction_value_check') = true,
    'mgs_reaction_value_check is validated (204_minigame_pasar)'
);
SELECT ok(
    (SELECT pg_get_constraintdef(oid) LIKE '%reaction IS NULL%'
       AND pg_get_constraintdef(oid) LIKE '%''disgust''%'
       AND pg_get_constraintdef(oid) LIKE '%''heart''%'
     FROM pg_constraint
     WHERE conrelid = 'minigame_reactions'::regclass
       AND conname = 'mgs_reaction_value_check'),
    'mgs_reaction_value_check allows NULL + the six emoji wire values (204_minigame_pasar)'
);

-- submit_minigame_reaction accepts 'pasar' and stores a NULL-reaction row.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''pasar''%'
       AND pg_get_functiondef(p.oid) LIKE '%NULLIF(p_reaction, ''pasar'')%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction accepts ''pasar'' and stores a NULL pass marker (204_minigame_pasar)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''pass''%'
       AND pg_get_functiondef(p.oid) LIKE '%r.reaction IS NULL%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction mirrors a ''pass'' count (reaction IS NULL) into state.reactions (204_minigame_pasar)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''pass''%'
       AND pg_get_functiondef(p.oid) LIKE '%r.reaction IS NULL%'
     FROM pg_proc p WHERE proname = 'react_minigame_round'),
    'react_minigame_round mirrors a ''pass'' count (async reactable rounds, 204_minigame_pasar)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''pasar''%'
       AND pg_get_functiondef(p.oid) LIKE '%NULLIF(p_reaction, ''pasar'')%'
     FROM pg_proc p WHERE proname = 'react_minigame_round'),
    'react_minigame_round accepts ''pasar'' (async reactable rounds, 204_minigame_pasar)'
);

-- The scoring math: emoji_count - pass_count/2, integer-normalized when
-- integral, with the -1 no-reactions penalty retained.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%FILTER (WHERE reaction IS NULL)%'
       AND pg_get_functiondef(p.oid) LIKE '%pass_count::numeric / 2%'
       AND pg_get_functiondef(p.oid) LIKE '%trunc(v_score)%'
     FROM pg_proc p WHERE proname = '_minigame_advance_round'),
    '_minigame_advance_round scores emoji_count - pass_count/2 (integer-normalized, 204_minigame_pasar)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%v_reaction_count = 0%'
       AND pg_get_functiondef(p.oid) LIKE '%v_score := -1%'
     FROM pg_proc p WHERE proname = '_minigame_advance_round'),
    '_minigame_advance_round keeps the -1 no-reactions penalty (204_minigame_pasar)'
);

-- finish_minigame_game settles fractional scores (numeric, not ::int).
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%(rr ->> ''score'')::numeric%'
     FROM pg_proc p WHERE proname = 'finish_minigame_game'),
    'finish_minigame_game reads by_turns round scores as numeric (fractional allowed, 204_minigame_pasar)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%pass_count%'
       OR pg_get_functiondef(p.oid) LIKE '%r.reaction IS NULL%'
     FROM pg_proc p WHERE proname = 'finish_minigame_game'),
    'finish_minigame_game async settlement accounts for reactor passers (204_minigame_pasar)'
);

-- ======================================================================
-- SECTION 49q: round-key request ring (migration 206_minigame_key_request,
-- 2026-09-03) — a participant whose device-local E2EE state was WIPED
-- (reinstall / data clear regenerated the identity) flags itself in
-- `state.key_requests` (jsonb uuid[] INSIDE the game-state payload), and ANY
-- other participant who still holds the key history re-wraps `K_0..K_<latest>`
-- to its CURRENT identity via the existing bundle seam, then clears the flag.
-- The server only brokers the marker — it never sees a round key.
--   * request_minigame_round_keys(uuid) — participant-only, active session;
--     appends the caller to state.key_requests (dedup).
--   * resolve_minigame_key_request(uuid, uuid) — participant-only, never
--     self-clear; removes p_requester from state.key_requests (idempotent).
-- ======================================================================
SELECT has_function('request_minigame_round_keys', ARRAY['uuid'],
    'request_minigame_round_keys(p_session_id uuid) exists (206_minigame_key_request)');
SELECT is_definer('public', 'request_minigame_round_keys', ARRAY['uuid']::name[],
    'request_minigame_round_keys is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'request_minigame_round_keys'),
    'request_minigame_round_keys sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'request_minigame_round_keys', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'request_minigame_round_keys is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'request_minigame_round_keys', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'request_minigame_round_keys is authenticated-EXECUTABLE');
SELECT has_function('resolve_minigame_key_request', ARRAY['uuid', 'uuid'],
    'resolve_minigame_key_request(p_session_id uuid, p_requester uuid) exists (206_minigame_key_request)');
SELECT is_definer('public', 'resolve_minigame_key_request', ARRAY['uuid', 'uuid']::name[],
    'resolve_minigame_key_request is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'resolve_minigame_key_request'),
    'resolve_minigame_key_request sets search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'resolve_minigame_key_request', ARRAY['uuid', 'uuid']::name[], 'public', ARRAY[]::name[],
    'resolve_minigame_key_request is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'resolve_minigame_key_request', ARRAY['uuid', 'uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'resolve_minigame_key_request is authenticated-EXECUTABLE');

-- The request RPC appends to the state payload's key_requests marker and is
-- participant-only on the WRITE path (an invitee / group member never flags).
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%key_requests%'
       AND pg_get_functiondef(p.oid) LIKE '%auth.uid() = ANY (v_participants)%'
       AND pg_get_functiondef(p.oid) LIKE '%''not_allowed''%'
     FROM pg_proc p WHERE proname = 'request_minigame_round_keys'),
    'request_minigame_round_keys appends to state.key_requests with a participant-only gate (206)'
);
-- The resolve RPC never lets a requester clear its own flag and removes only
-- the served peer from the marker (idempotent array rebuild).
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%self_resolve%'
       AND pg_get_functiondef(p.oid) LIKE '%jsonb_array_elements%'
       AND pg_get_functiondef(p.oid) LIKE '%auth.uid() = p_requester%'
     FROM pg_proc p WHERE proname = 'resolve_minigame_key_request'),
    'resolve_minigame_key_request is never self-clearing and rebuilds the marker without the served peer (206)'
);

-- ======================================================================
-- SECTION 49p: decline-deletes + re-invite + roster realtime hardening
-- (2026-09-02 user directive).
--   * decline_minigame_invite DELETEs the invite row — a declined invite is
--     indistinguishable from one that never existed, so the (session_id,
--     invitee_id) UNIQUE is free for a fresh re-invite and
--     invite_minigame_players fires the INSERT-time notification unchanged.
--   * invite_minigame_players therefore needs NO re-open logic: a declined
--     (or kicked, row deleted by remove_minigame_participant) invitee is a
--     plain fresh INSERT on re-invite; only a still-PENDING row is skipped
--     idempotently (205 idempotency preserved).
--   * minigame_sessions carries REPLICA IDENTITY FULL so participant
--     join/remove UPDATE payloads ship the whole row — the roster diff has
--     the authoritative participants array even on a fresh match.
-- ======================================================================
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%DELETE FROM public.minigame_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%''declined''%'
       AND pg_get_functiondef(p.oid) LIKE '%invitee_id = v_current_user%'
     FROM pg_proc p WHERE proname = 'decline_minigame_invite'),
    'decline_minigame_invite deletes the row and stays invitee-only (49p)'
);
SELECT ok(
    (SELECT NOT pg_get_functiondef(p.oid) LIKE '%UPDATE public.minigame_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%DELETE FROM public.minigame_invites%'
     FROM pg_proc p WHERE proname = 'decline_minigame_invite'),
    'decline_minigame_invite never UPDATEs a row (only DELETE — no lingering declined state, 49p)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%t.v <> ALL (v_pending)%'
       AND pg_get_functiondef(p.oid) LIKE '%INSERT INTO public.minigame_invites%'
       AND NOT pg_get_functiondef(p.oid) LIKE '%ON CONFLICT%'
       AND NOT pg_get_functiondef(p.oid) LIKE '%UPDATE public.minigame_invites%'
     FROM pg_proc p WHERE proname = 'invite_minigame_players'),
    'invite_minigame_players stays pure-INSERT idempotent (skips only pending; a deleted row is re-insertable, 49p)'
);
SELECT ok(
    (SELECT relreplident = 'f' FROM pg_class WHERE oid = 'public.minigame_sessions'::regclass),
    'minigame_sessions has REPLICA IDENTITY FULL (realtime roster reliability, 49p)'
);

-- ======================================================================
-- SECTION 49r: per-tap reaction event (migration 207_minigame_reaction_event,
-- 2026-09-03) — a same-emoji RE-TAP leaves state.reactions byte-identical
-- (the upsert keeps created_at), so the realtime mirror cannot signal "tapped
-- again" on its own. Both reaction RPCs therefore bump a monotonic
-- state.reactions_seq and record the last tap as state.reactions_event
-- {seq, round, reaction, voter_id} in the SAME atomic UPDATE that rewrites
-- the mirror — every device gets the exact tapped emoji per tap even when the
-- tally content is unchanged. The seq is session-global (never reset on round
-- advance); a round change is carried by the event's own `round` field.
-- ======================================================================
-- submit_minigame_reaction (current by_turns round): writes the seq path.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''{reactions_seq}''%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction bumps state.reactions_seq (207_minigame_reaction_event)'
);
-- …and records reactions_event with a seq key.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''{reactions_event}''%'
       AND pg_get_functiondef(p.oid) LIKE '%''seq''%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction records state.reactions_event.seq (207_minigame_reaction_event)'
);
-- …and the event carries the tapped emoji + voter (NULL for a reactor Pasar).
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''voter_id''%'
       AND pg_get_functiondef(p.oid) LIKE '%NULLIF(p_reaction, ''pasar'')%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction records the tapped emoji + voter in reactions_event (NULL on Pasar, 207_minigame_reaction_event)'
);
-- The seq bumps monotonically on EVERY write (a same-emoji re-tap included):
-- the inline formula is (old seq) + 1 evaluated against the pre-UPDATE row.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%COALESCE((state ->> ''reactions_seq'')::bigint, 0)) + 1%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction increments reactions_seq monotonically on every write (207_minigame_reaction_event)'
);

-- react_minigame_round (async reactable round): the same seq + event writes.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''{reactions_seq}''%'
       AND pg_get_functiondef(p.oid) LIKE '%COALESCE((state ->> ''reactions_seq'')::bigint, 0)) + 1%'
     FROM pg_proc p WHERE proname = 'react_minigame_round'),
    'react_minigame_round bumps state.reactions_seq monotonically (async reactable rounds, 207_minigame_reaction_event)'
);
-- …records reactions_event carrying the TARGET round (p_round — the async
-- round may differ from the session''s current round).
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''{reactions_event}''%'
       AND pg_get_functiondef(p.oid) LIKE '%''round'', p_round%'
       AND pg_get_functiondef(p.oid) LIKE '%''voter_id''%'
     FROM pg_proc p WHERE proname = 'react_minigame_round'),
    'react_minigame_round records reactions_event with the target round + voter (207_minigame_reaction_event)'
);

-- _minigame_advance_round does NOT reset the sequence: it clears only the
-- round-scoped reactions/answer fields, leaving reactions_seq monotonic and
-- the last event in place (a stale round-N event is ignored client-side by
-- its own `round` field). Asserting the advance never touches the counter.
SELECT ok(
    (SELECT NOT pg_get_functiondef(p.oid) LIKE '%reactions_seq%'
     FROM pg_proc p WHERE proname = '_minigame_advance_round'),
    '_minigame_advance_round never resets reactions_seq (session-global counter, 207_minigame_reaction_event)'
);

-- The reaction RPC bodies keep their exact 204 gates (the 207 change is
-- additive — the seq/event fold into the existing mirror UPDATE). Spot-check
-- that submit_minigame_reaction still gates on the subject answer.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%answer_pending%'
       AND pg_get_functiondef(p.oid) LIKE '%own_round%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction keeps the 202 answer-first + own-round gates (207 is additive)'
);

-- Emoji ↔ Pasar exclusivity (2026-09-04, corrected 2026-09-09): once a voter
-- has acted they cannot switch to the OTHER mode. A Pasar row stores a NULL
-- reaction, so cross-mode is detected by ROW EXISTENCE — submit_minigame_reaction
-- rejects a Pasar when the voter already holds an EMOJI row (already_reacted)
-- and rejects an emoji when the voter holds a PASS row (reaction IS NULL,
-- already_passed); fresh voters and same-mode re-votes stay allowed. The
-- per-voter last_tap_at + 250 ms `too_fast` gate bounds spam server-side.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%already_reacted%'
       AND pg_get_functiondef(p.oid) LIKE '%already_passed%'
       AND pg_get_functiondef(p.oid) LIKE '%reaction IS NULL%'
       AND pg_get_functiondef(p.oid) LIKE '%reaction IS NOT NULL%'
       AND pg_get_functiondef(p.oid) LIKE '%too_fast%'
       AND pg_get_functiondef(p.oid) LIKE '%last_tap_at%'
       AND pg_get_functiondef(p.oid) LIKE '%p_reaction = ''pasar''%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction enforces emoji ↔ Pasar exclusivity by row existence + the 250 ms spam gate (207, fixed 2026-09-09)'
);
-- The mirror carries the per-voter action map (voter_id → emoji wire or null
-- for a pass) inside state.reactions.<subject>, so clients grey out the OTHER
-- mode once a voter has acted.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''voters''%'
       AND pg_get_functiondef(p.oid) LIKE '%jsonb_object_agg(r.voter_id::text, r.reaction)%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction mirrors the per-voter action map under state.reactions.<subject>.voters (207, 2026-09-04)'
);

-- react_minigame_round (async reactable round): the SAME corrected
-- row-existence exclusivity + spam gate + per-voter voters mirror.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%already_reacted%'
       AND pg_get_functiondef(p.oid) LIKE '%already_passed%'
       AND pg_get_functiondef(p.oid) LIKE '%reaction IS NULL%'
       AND pg_get_functiondef(p.oid) LIKE '%reaction IS NOT NULL%'
       AND pg_get_functiondef(p.oid) LIKE '%too_fast%'
       AND pg_get_functiondef(p.oid) LIKE '%last_tap_at%'
     FROM pg_proc p WHERE proname = 'react_minigame_round'),
    'react_minigame_round enforces emoji ↔ Pasar exclusivity by row existence + the 250 ms spam gate (async reactable rounds, 207, fixed 2026-09-09)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%''voters''%'
       AND pg_get_functiondef(p.oid) LIKE '%jsonb_object_agg(r.voter_id::text, r.reaction)%'
     FROM pg_proc p WHERE proname = 'react_minigame_round'),
    'react_minigame_round mirrors the per-voter action map (async reactable rounds, 207, 2026-09-04)'
);
-- Emoji → emoji re-votes remain possible (the upsert replaces): assert the RPC
-- still upserts rather than rejecting a same-mode change.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%ON CONFLICT (session_id, round, voter_id) DO UPDATE%'
       AND pg_get_functiondef(p.oid) LIKE '%SET reaction = EXCLUDED.reaction%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction still allows emoji → emoji re-votes (upsert replaces, 207 exclusivity is cross-mode only)'
);

-- ======================================================================
-- SECTION 49s: Two Lies One Truth (migration 208_minigame_two_lies_one_truth)
-- ======================================================================
SELECT ok(
    (SELECT count(*) = 1 FROM pg_enum WHERE enumtypid = 'public.mini_game_type'::regtype AND enumlabel = 'two_lies_one_truth'),
    'mini_game_type enum contains two_lies_one_truth (208_minigame_two_lies_one_truth)'
);
SELECT ok(
    (SELECT pg_get_constraintdef(oid) LIKE '%vote_0%'
        AND pg_get_constraintdef(oid) LIKE '%vote_1%'
        AND pg_get_constraintdef(oid) LIKE '%vote_2%'
     FROM pg_constraint
     WHERE conrelid = 'minigame_reactions'::regclass
       AND conname = 'mgs_reaction_value_check'),
    'mgs_reaction_value_check allows vote_0, vote_1, vote_2 (208_minigame_two_lies_one_truth)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%vote_0%'
        AND pg_get_functiondef(p.oid) LIKE '%vote_1%'
        AND pg_get_functiondef(p.oid) LIKE '%vote_2%'
     FROM pg_proc p WHERE proname = 'submit_minigame_reaction'),
    'submit_minigame_reaction accepts vote_0..2 (208_minigame_two_lies_one_truth)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%vote_0%'
        AND pg_get_functiondef(p.oid) LIKE '%vote_1%'
        AND pg_get_functiondef(p.oid) LIKE '%vote_2%'
     FROM pg_proc p WHERE proname = 'react_minigame_round'),
    'react_minigame_round accepts vote_0..2 (208_minigame_two_lies_one_truth)'
);
SELECT ok(
    (SELECT count(*) >= 6 FROM public.minigame_prompts WHERE game_type = 'two_lies_one_truth'),
    'minigame_prompts has seeded topic prompts for two_lies_one_truth (208_minigame_two_lies_one_truth)'
);

-- ======================================================================
-- SECTION 49t: merged PR — extra games + public partidas (2026-09-14):
--   209_minigame_drunk_bottle, 210_minigame_bottle_pizza,
--   211_minigame_public, 212_minigame_charades, 213_charades_no_repeats.
-- Cover the new PUBLIC READ surface (ms_read_public widens minigame_sessions
-- read to any signed-in user on a published, open, direct partida) and the
-- new SECURITY DEFINER RPC posture.
-- ======================================================================
SELECT ok(
    (SELECT count(*) = 1 FROM pg_enum
      WHERE enumtypid = 'public.mini_game_type'::regtype AND enumlabel = 'charades'),
    'mini_game_type enum contains charades (212_minigame_charades)'
);

-- Drunk-bottle spin RPC family: DEFINER, search_path='', authenticated-only.
-- 209's `set_drunk_bottle_spin(uuid,boolean,uuid)` was DROPPED by
-- 210_minigame_bottle_pizza; the live family is spin/stop_drunk_bottle(uuid).
SELECT has_function('spin_drunk_bottle', ARRAY['uuid'],
    'spin_drunk_bottle(uuid) exists (210_minigame_bottle_pizza)');
SELECT has_function('stop_drunk_bottle', ARRAY['uuid'],
    'stop_drunk_bottle(uuid) exists (210_minigame_bottle_pizza)');
SELECT is_definer('public', 'spin_drunk_bottle', ARRAY['uuid']::name[],
    'spin_drunk_bottle is SECURITY DEFINER');
SELECT is_definer('public', 'stop_drunk_bottle', ARRAY['uuid']::name[],
    'stop_drunk_bottle is SECURITY DEFINER');
SELECT ok(
    (SELECT bool_and('search_path=""' = ANY (proconfig))
     FROM pg_proc WHERE proname IN ('spin_drunk_bottle', 'stop_drunk_bottle')),
    'spin/stop_drunk_bottle set search_path = '''' (I-31 pattern)'
);
SELECT function_privs_are('public', 'spin_drunk_bottle', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'spin_drunk_bottle is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'spin_drunk_bottle', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'spin_drunk_bottle is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'stop_drunk_bottle', ARRAY['uuid']::name[], 'public', ARRAY[]::name[],
    'stop_drunk_bottle is not PUBLIC-EXECUTABLE');
SELECT function_privs_are('public', 'stop_drunk_bottle', ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'stop_drunk_bottle is authenticated-EXECUTABLE');

-- Public partidas (211_minigame_public): additive column + partial index +
-- the ms_read_public SELECT policy, scoped to published/open/direct sessions.
SELECT has_column('minigame_sessions', 'is_public',
    'minigame_sessions has is_public (211_minigame_public)');
SELECT has_index('public', 'minigame_sessions', 'idx_minigame_sessions_public',
    'idx_minigame_sessions_public partial index exists (211_minigame_public)');
SELECT ok(
    (SELECT count(*)::int FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'minigame_sessions'
        AND policyname = 'ms_read_public') = 1,
    'minigame_sessions has the ms_read_public policy (211_minigame_public)'
);
SELECT ok(
    (SELECT qual LIKE '%is_public%'
        AND qual LIKE '%group_id IS NULL%'
        AND qual LIKE '%active%'
        AND qual LIKE '%auth.uid() IS NOT NULL%'
      FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'minigame_sessions'
        AND policyname = 'ms_read_public'),
    'ms_read_public gates on is_public + direct + active + signed-in (211_minigame_public)'
);
SELECT has_function('set_minigame_public', ARRAY['uuid','boolean'],
    'set_minigame_public(uuid,boolean) exists (211_minigame_public)');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%not_creator%'
        AND pg_get_functiondef(p.oid) LIKE '%group_session%'
      FROM pg_proc p WHERE proname = 'set_minigame_public'),
    'set_minigame_public is host-only and rejects group sessions (211_minigame_public)'
);
SELECT has_function('list_public_minigames', ARRAY['text'],
    'list_public_minigames(text) exists (211_minigame_public)');
SELECT is_definer('public', 'list_public_minigames', ARRAY['text']::name[],
    'list_public_minigames is SECURITY DEFINER');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%COALESCE(v_is_public, false)%'
      FROM pg_proc p WHERE proname = 'join_minigame_session'),
    'join_minigame_session admits published direct joins (211_minigame_public)'
);

-- Charadas turn engine (212/213).
SELECT has_function('start_charades_turn', ARRAY['uuid','text','integer'],
    'start_charades_turn(uuid,text,int) exists (212_minigame_charades)');
SELECT has_function('charades_answer', ARRAY['uuid','boolean'],
    'charades_answer(uuid,boolean) exists (212_minigame_charades)');
SELECT has_function('end_charades_turn', ARRAY['uuid'],
    'end_charades_turn(uuid) exists (212_minigame_charades)');
SELECT ok(
    (SELECT count(*) > 0 FROM public.minigame_prompts WHERE game_type = 'charades'),
    'minigame_prompts has seeded charades words (212_minigame_charades)'
);

-- SECTION 62: get_minigame_invite_context (215_minigame_invite_context,
-- 2026-09-11) — the pending-invite lobby shows ONLY the inviter
-- ("INVITADO POR" + avatar), never the participant roster, so the invitee's
-- accept surface cannot flash the player list before accepting.
--   * SECURITY DEFINER + locked search_path + invitee-scoped
--     (`invitee_id = auth.uid()`); non-invitees get `invite_not_found`.
--   * Resolves the inviter through the security-barrier `user_search_view`
--     by `created_by`; the function never reads `participants` (no roster
--     leak by construction).
-- ======================================================================
SELECT has_function('get_minigame_invite_context', ARRAY['uuid'],
    'get_minigame_invite_context(uuid) exists (215_minigame_invite_context)');

SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%SECURITY DEFINER%'
       AND pg_get_functiondef(p.oid) LIKE '%SET search_path TO ''''%'
       AND pg_get_functiondef(p.oid) LIKE '%invitee_id = auth.uid()%'
       AND pg_get_functiondef(p.oid) LIKE '%invite_not_found%'
     FROM pg_proc p WHERE proname = 'get_minigame_invite_context'),
    'get_minigame_invite_context is SECURITY DEFINER, invitee-scoped, invite_not_found on miss (215)'
);

SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%user_search_view%'
       AND pg_get_functiondef(p.oid) LIKE '%created_by%'
       AND NOT pg_get_functiondef(p.oid) LIKE '%participants%'
     FROM pg_proc p WHERE proname = 'get_minigame_invite_context'),
    'get_minigame_invite_context resolves ONLY the inviter (never the participants roster, 215)'
);

SELECT ok(
    (SELECT NOT has_function_privilege('anon', p.oid, 'EXECUTE')
       AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
     FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'get_minigame_invite_context'),
    'get_minigame_invite_context is authenticated-only (PUBLIC/anon revoked, 215)'
);

-- ======================================================================
-- SECTION 63: minigame group message + member fan-out
-- (216_minigame_group_message, 2026-09-15)
--   * 2a — create_minigame_session fans out an invite to EVERY active group
--     member (creator excluded) for a group session.
--   * 2b — a group session insert drops a notice in the group chat via the
--     `minigame_group_messages` table (E2EE messages cannot carry it), readable
--     by active group members only and streamed realtime.
-- ======================================================================
SELECT has_table('minigame_group_messages',
    'minigame_group_messages exists (216_minigame_group_message)');

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'minigame_group_messages'
          AND policyname = 'mgm_read_group_member'
    ),
    'minigame_group_messages has mgm_read_group_member (group members read, 216)'
);

SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%group_members%'
       AND pg_get_functiondef(p.oid) LIKE '%status = ''active''%'
     FROM pg_proc p WHERE proname = 'create_minigame_session'),
    'create_minigame_session fans out to every active group member (2a, 216)'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = 'minigame_sessions'
          AND t.tgname = 'minigame_group_message_trigger'
    ),
    'minigame_sessions has the group-message trigger (2b, 216)'
);

SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%SECURITY DEFINER%'
       AND pg_get_functiondef(p.oid) LIKE '%minigame_group_messages%'
     FROM pg_proc p WHERE proname = 'notify_minigame_group_message'),
    'notify_minigame_group_message is SECURITY DEFINER and writes the notice (2b, 216)'
);

-- ======================================================================
-- SECTION 64: group-chat guarantee + inbox notice activity
-- (216/P1, 2026-09-15)
--   * one group chat per group (partial unique index) + backfilled all groups
--   * the notice trigger creates a missing group chat (server guarantee)
--   * get_chat_inbox counts a minigame notice as chat activity
-- ======================================================================
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = 'chats'
          AND indexname = 'chats_group_reference_uniq'
    ),
    'chats has chats_group_reference_uniq (one group chat per group, 216/P1)'
);

SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%INSERT INTO public.chats%'
     FROM pg_proc p WHERE proname = 'notify_minigame_group_message'),
    'notify_minigame_group_message creates the group chat if missing (216/P1)'
);

SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%last_activity_kind%'
       AND pg_get_functiondef(p.oid) LIKE '%minigame_group_messages%'
     FROM pg_proc p WHERE proname = 'get_chat_inbox'),
    'get_chat_inbox counts minigame notices as chat activity (216/P1)'
);

-- ======================================================================
-- SECTION 65: chat moderation — block enforcement + message report
-- (226_chat_moderation) and the sober bottle bank (227_bottle_sober)
--   * message_reports snapshot table (moderator-only)
--   * is_blocked_between helper
--   * report_message RPC (SECURITY DEFINER, writes the snapshot)
--   * create_direct_chat block gate + the direct-message block trigger
--   * no drinking dares left in the drunk_bottle prompt bank
-- ======================================================================
SELECT has_table('message_reports',
    'message_reports exists (226_chat_moderation)');

SELECT has_function('is_blocked_between', ARRAY['uuid', 'uuid'],
    'is_blocked_between exists (226)');

SELECT has_function('report_message', ARRAY['uuid', 'text', 'text'],
    'report_message exists (226)');

SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%is_blocked_between%'
     FROM pg_proc p WHERE proname = 'create_direct_chat'),
    'create_direct_chat enforces the block gate (226)'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = 'messages'
          AND t.tgname = 'assert_message_not_blocked_trigger'
    ),
    'messages has the block-enforcement trigger (226)'
);

SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%SECURITY DEFINER%'
       AND pg_get_functiondef(p.oid) LIKE '%message_reports%'
     FROM pg_proc p WHERE proname = 'report_message'),
    'report_message is SECURITY DEFINER and writes the snapshot (226)'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM public.minigame_prompts
        WHERE game_type = 'drunk_bottle'
          AND (body ILIKE '%tomas%' OR body ILIKE '%toman%')
    ),
    'drinking dares rephrased out of the bottle bank (227)'
);

-- ============================================================
-- SECTION 66: Wave 0 trust boundary (229_wave0_trust_boundary)
-- Minimal invariants: the critical abuse paths are closed.
-- ============================================================
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.user_search_view', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.user_search_view', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.user_search_view', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.user_search_view', 'DELETE')
    AND NOT has_table_privilege('anon', 'public.user_search_view', 'SELECT'),
    'SEC-001/Q8 user_search_view is RPC-only (no client SELECT/enumeration)'
);
SELECT ok(
    has_table_privilege('authenticated', 'public.discovery_view', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.discovery_view', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.discovery_view', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.discovery_view', 'DELETE')
    AND NOT has_table_privilege('anon', 'public.discovery_view', 'SELECT'),
    'SEC-001 discovery_view is SELECT-only for authenticated and closed to anon'
);
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.shard_ledger', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.preshard_ledger', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.group_shard_contributions', 'INSERT'),
    'SEC-002 clients cannot mint shard/group ledger rows'
);
SELECT has_function('purchase_cosmetic', ARRAY['uuid'],
    'SEC-003 purchase_cosmetic(uuid) exists');
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.user_cosmetics', 'INSERT')
    AND has_column_privilege('authenticated', 'public.user_cosmetics', 'equipped', 'UPDATE'),
    'SEC-003 user_cosmetics is purchase-RPC-only; clients may only equip'
);
SELECT ok(
    NOT has_function_privilege('authenticated', 'public.finish_minigame_game(uuid)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.abandon_minigame_game(uuid)', 'EXECUTE'),
    'SEC-004 settlement is server-only; abandonment is the client path'
);
SELECT ok(
    NOT has_function_privilege('anon', 'public.refund_event_pool_on_cancel()', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.refund_event_pool_on_cancel()', 'EXECUTE'),
    'SEC-007 pool-refund trigger function is not client-callable'
);
SELECT ok(
    (SELECT pg_get_expr(polqual, polrelid) FROM pg_policy
      WHERE polname = 'events_read_access' AND polrelid = 'public.events'::regclass)
        NOT LIKE '%group_id IS NULL%'
    AND (SELECT pg_get_expr(polqual, polrelid) FROM pg_policy
          WHERE polname = 'events_read_access' AND polrelid = 'public.events'::regclass)
        LIKE '%accepted%',
    'SEC-005 events_read_access requires host/staff or accepted invitee'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%NULL::numeric%'
       AND pg_get_functiondef(p.oid) LIKE '%upcoming%'
     FROM pg_proc p WHERE proname = 'search_events'),
    'SEC-005 search_events returns a safe projection and hides non-live rows'
);
SELECT ok(
    (SELECT pg_get_expr(polwithcheck, polrelid) FROM pg_policy
      WHERE polname = 'friendships_insert_own' AND polrelid = 'public.friendships'::regclass)
        LIKE '%pending%'
    AND (SELECT pg_get_expr(polwithcheck, polrelid) FROM pg_policy
          WHERE polname = 'friendships_insert_own' AND polrelid = 'public.friendships'::regclass)
        LIKE '%blocked%',
    'SEC-006 friendship insert cannot forge an accepted row'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%not_a_group_member%'
       AND pg_get_functiondef(p.oid) LIKE '%event_pool_set%'
     FROM pg_proc p WHERE proname = 'create_event'),
    'SEC-007 create_event validates membership and escrows the pool'
);
SELECT ok(
    (SELECT pg_get_expr(polwithcheck, polrelid) FROM pg_policy
      WHERE polname = 'eph_insert_own' AND polrelid = 'public.event_photos'::regclass)
        LIKE '%event_attendances%'
    AND (SELECT pg_get_expr(polwithcheck, polrelid) FROM pg_policy
          WHERE polname = 'eph_insert_own' AND polrelid = 'public.event_photos'::regclass)
        LIKE '%/photos/%',
    'SEC-010 photo upload requires attendance and an event-bound path'
);

-- ============================================================
-- SECTION 67: Wave 0 safety (230_wave0_safety)
-- ============================================================
SELECT has_function('is_active_user', ARRAY['uuid'],
    'SEC-008 is_active_user(uuid) exists');
SELECT ok(
    (SELECT prosecdef FROM pg_proc WHERE proname = 'is_active_user')
    AND has_function_privilege('authenticated', 'public.is_active_user(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.is_active_user(uuid)', 'EXECUTE'),
    'SEC-008 is_active_user is SECURITY DEFINER, authenticated-only'
);
SELECT has_function('moderate_report', ARRAY['uuid', 'text', 'uuid'],
    'SEC-009 moderate_report(uuid,text,uuid) exists');
SELECT has_table('moderation_evidence',
    'SEC-009 moderation_evidence table exists');
SELECT ok(
    (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='moderation_evidence') = 0
    AND EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        WHERE c.relname = 'messages' AND t.tgname = 'active_actor_guard'
    ),
    'SEC-008/009 evidence is service-only and messages carry the active-actor guard'
);

-- ============================================================
-- SECTION 68: Wave 1 DB hardening (231_wave1_hardening)
-- ============================================================
SELECT ok(
    (SELECT pg_get_expr(polqual, polrelid) LIKE '%event_hosts%'
       AND pg_get_expr(polqual, polrelid) LIKE '%host%'
     FROM pg_policy
      WHERE polname = 'events_update_host'
        AND polrelid = 'public.events'::regclass),
    'SEC-014 events_update_host requires the host role (231)'
);
SELECT ok(
    (SELECT polwithcheck IS NOT NULL
       AND pg_get_expr(polwithcheck, polrelid) LIKE '%created_by_user_id%'
     FROM pg_policy
      WHERE polname = 'events_update_host'
        AND polrelid = 'public.events'::regclass),
    'SEC-014 events_update_host has an owner-pinning WITH CHECK (231)'
);
SELECT ok(
    (SELECT pg_get_expr(polqual, polrelid) LIKE '%event_invites%'
       AND pg_get_expr(polqual, polrelid) LIKE '%accepted%'
       AND pg_get_expr(polqual, polrelid) LIKE '%attended%'
     FROM pg_policy
      WHERE polname = 'chats_read_participant'
        AND polrelid = 'public.chats'::regclass),
    'SEC-018 event chat read requires accepted/attended (231)'
);
SELECT ok(
    (SELECT pg_get_expr(polqual, polrelid) LIKE '%event_invites%'
       AND pg_get_expr(polqual, polrelid) LIKE '%accepted%'
       AND pg_get_expr(polqual, polrelid) LIKE '%attended%'
     FROM pg_policy
      WHERE polname = 'messages_read_participant'
        AND polrelid = 'public.messages'::regclass),
    'SEC-018 event message read requires accepted/attended (231)'
);
SELECT ok(
    (SELECT pg_get_expr(polwithcheck, polrelid) LIKE '%event_invites%'
       AND pg_get_expr(polwithcheck, polrelid) LIKE '%accepted%'
       AND pg_get_expr(polwithcheck, polrelid) LIKE '%attended%'
     FROM pg_policy
      WHERE polname = 'messages_insert_participant'
        AND polrelid = 'public.messages'::regclass),
    'SEC-018 event message write requires accepted/attended (231)'
);
SELECT ok(
    (SELECT count(*) = 2
       AND bool_and(pg_get_expr(
               CASE WHEN polcmd = 'a' THEN polwithcheck ELSE polqual END,
               polrelid) LIKE '%accepted%')
     FROM pg_policy
      WHERE polrelid = 'public.message_reads'::regclass
        AND polname IN ('message_reads_insert_own', 'message_reads_select_participant')),
    'SEC-018 read receipts require accepted/attended event membership (231)'
);
SELECT ok(
    (SELECT pg_get_expr(polqual, polrelid) LIKE '%status = ''active''%'
     FROM pg_policy
      WHERE polname = 'groups_read_member'
        AND polrelid = 'public.groups'::regclass),
    'SEC-018 group read requires active membership (231)'
);
SELECT ok(
    (SELECT pg_get_expr(polqual, polrelid) LIKE '%status = ''active''%'
       AND pg_get_expr(polwithcheck, polrelid) LIKE '%status = ''active''%'
     FROM pg_policy
      WHERE polname = 'groups_update_host'
        AND polrelid = 'public.groups'::regclass),
    'SEC-018 group update requires active host/staff (231)'
);
SELECT ok(
    (SELECT pg_get_expr(polqual, polrelid) LIKE '%status = ''active''%'
     FROM pg_policy
      WHERE polname = 'gsc_read_member'
        AND polrelid = 'public.group_shard_contributions'::regclass),
    'SEC-018 group contributions require active membership (231)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%event_invites%'
       AND pg_get_functiondef(p.oid) LIKE '%accepted%'
       AND pg_get_functiondef(p.oid) LIKE '%attended%'
     FROM pg_proc p WHERE proname = 'report_message'),
    'SEC-018 report_message requires accepted/attended event membership (231)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%sender_id = v_me%'
     FROM pg_proc p WHERE proname = 'delete_undecryptable_messages'),
    'SEC-015 undecryptable cleanup deletes only the caller''s messages (231)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%BATCH_TOO_LARGE%'
       AND pg_get_functiondef(p.oid) LIKE '%> 50%'
     FROM pg_proc p WHERE proname = 'delete_undecryptable_messages'),
    'SEC-015 undecryptable cleanup caps the batch at 50 (231)'
);
SELECT ok(
    NOT has_table_privilege('authenticated', 'public.deleted_messages', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.deleted_messages', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.deleted_messages', 'DELETE')
    AND NOT has_table_privilege('anon', 'public.deleted_messages', 'INSERT')
    AND has_table_privilege('service_role', 'public.deleted_messages', 'INSERT'),
    'SEC-015 deleted_messages direct client writes are revoked (231)'
);
SELECT ok(
    has_column_privilege('authenticated', 'public.notifications', 'read', 'UPDATE')
    AND NOT has_column_privilege('authenticated', 'public.notifications', 'title', 'UPDATE')
    AND NOT has_column_privilege('authenticated', 'public.notifications', 'push_sent_at', 'UPDATE'),
    'SEC-019 owners may update only notifications.read (231)'
);
SELECT ok(
    NOT has_column_privilege('anon', 'public.notifications', 'read', 'UPDATE')
    AND has_column_privilege('service_role', 'public.notifications', 'push_sent_at', 'UPDATE'),
    'SEC-019 anon cannot update notifications; push_sent_at stays service-only (231)'
);
SELECT ok(
    (SELECT count(*) = 2
     FROM pg_constraint
      WHERE conrelid = 'public.device_tokens'::regclass
        AND conname IN ('device_tokens_token_length', 'device_tokens_token_charset')),
    'SEC-020 device tokens carry length + charset constraints (231)'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%token_owned_by_another_user%'
       AND pg_get_functiondef(p.oid) LIKE '%token_limit_reached%'
     FROM pg_proc p WHERE proname = 'register_device_token'),
    'SEC-020 token registration blocks re-homing and caps at 10 (231)'
);
SELECT ok(
    has_table_privilege('authenticated', 'public.device_tokens', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.device_tokens', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.device_tokens', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.device_tokens', 'DELETE'),
    'SEC-020 device tokens stay RPC-write-only (231)'
);
SELECT ok(
    (SELECT bool_and(allowed_mime_types @> ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]
                     AND NOT (allowed_mime_types && ARRAY['text/html', 'image/svg+xml']::text[])
                     AND file_size_limit IS NOT NULL)
     FROM storage.buckets
      WHERE id IN ('avatars', 'groups', 'events')),
    'SEC-030 image buckets allow only raster image MIME types with a size cap (231)'
);
SELECT ok(
    (SELECT allowed_mime_types = ARRAY['application/octet-stream']::text[]
            AND file_size_limit IS NOT NULL
     FROM storage.buckets
      WHERE id = 'minigame_images'),
    'SEC-030 minigame_images accepts only encrypted octets with a size cap (231)'
);
SELECT ok(
    (SELECT pg_get_expr(polwithcheck, polrelid) LIKE '%event_hosts%'
       AND pg_get_expr(polwithcheck, polrelid) LIKE '%event_invites%'
       AND pg_get_expr(polwithcheck, polrelid) LIKE '%accepted%'
     FROM pg_policy
      WHERE polname = 'storage_objects_insert_own'
        AND polrelid = 'storage.objects'::regclass),
    'SEC-030 event uploads are bound to an accessible event path (231)'
);
SELECT ok(
    (SELECT pg_get_expr(polwithcheck, polrelid) LIKE '%event_hosts%'
       AND pg_get_expr(polwithcheck, polrelid) LIKE '%event_invites%'
     FROM pg_policy
      WHERE polname = 'storage_objects_update_own'
        AND polrelid = 'storage.objects'::regclass),
    'SEC-030 event object relocation re-checks the event path (231)'
);


-- ============================================================
-- SECTION 63: Identity, privacy and age assurance (233_identity_privacy)
--   Q17: DOB NOT NULL + 18+ trigger on every writer, legacy sentinel path.
--   Q8: private profiles exact-username only; no bio/avatar; no ranking;
--       direct view SELECT revoked (no directory enumeration).
--   Q1: immediate hard delete, pseudonymized ledger/attendance retention,
--       restricted report evidence, no restore path, complete export.
-- ============================================================

-- 62a: Q17
SELECT ok(
    (SELECT is_nullable = 'NO' FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'users'
        AND column_name = 'date_of_birth'),
    'Q17 users.date_of_birth is NOT NULL'
);
SELECT has_column('users', 'date_of_birth_backfilled',
    'Q17 users.date_of_birth_backfilled exists');
SELECT col_not_null('users', 'date_of_birth_backfilled',
    'Q17 date_of_birth_backfilled is NOT NULL');
SELECT has_trigger('users', 'users_adult_dob_trigger',
    'Q17 adult-DOB trigger exists on users');
SELECT has_function('assert_adult_dob', ARRAY[]::name[],
    'Q17 assert_adult_dob() exists');
SELECT ok(
    (SELECT pg_get_constraintdef(oid) LIKE '%1900-01-01%'
       FROM pg_constraint
      WHERE conrelid = 'public.users'::regclass
        AND conname = 'users_date_of_birth_range'),
    'Q17 users_date_of_birth_range CHECK exists'
);

-- 62b: Q8
SELECT columns_are('user_search_view',
    ARRAY['id', 'username', 'avatar_url', 'bio', 'profile_public'],
    'Q8 user_search_view exposes profile_public for the server-side filter');
SELECT has_function('get_public_profiles', ARRAY['uuid[]'],
    'Q8 get_public_profiles(uuid[]) exists');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%profile_public = true%'
       FROM pg_proc p WHERE proname = 'get_user_ranking'),
    'Q8 get_user_ranking filters profile_public = true'
);
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%NOT usv.profile_public%'
            AND pg_get_functiondef(p.oid) LIKE '%lower(usv.username) = lower(v_trimmed)%'
       FROM pg_proc p WHERE proname = 'search_users'),
    'Q8 search_users uses exact username for private rows'
);

-- 62c: Q1 schema + RPC shape
SELECT hasnt_function('restore_my_account',
    'Q1 restore_my_account is removed (no 30-day restore)');
SELECT hasnt_function('account_deletion_grace_days',
    'Q1 grace-period helper is removed');
SELECT has_table('retention_matrix',
    'Q1 retention_matrix exists');
SELECT has_table('account_deletion_audit',
    'Q1/SEC-049 account_deletion_audit exists');
SELECT has_table('auth_cleanup_queue',
    'Q1/SEC-049 auth_cleanup_queue exists');
SELECT has_column('reports', 'reporter_pseudonym',
    'Q1 reports.reporter_pseudonym exists');
SELECT has_column('reports', 'retention_until',
    'Q1 reports.retention_until exists');
SELECT ok(
    (SELECT is_nullable = 'YES' FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'reports'
        AND column_name = 'reporter_id'),
    'Q1 reports.reporter_id is nullable for pseudonymized evidence'
);
SELECT ok(
    (SELECT confdeltype = 'n' FROM pg_constraint
      WHERE conname = 'reports_reporter_id_fkey'),
    'Q1 reports.reporter_id uses ON DELETE SET NULL'
);
SELECT has_column('event_attendances', 'retention_until',
    'Q1 attendance carries a retention clock');
SELECT ok(
    (SELECT confdeltype = 'n' FROM pg_constraint
      WHERE conname = 'event_attendances_user_id_fkey'),
    'Q1 attendance uses ON DELETE SET NULL (pseudonymized, not cascaded)'
);
SELECT has_function('purge_expired_retention', ARRAY[]::name[],
    'Q1 purge_expired_retention() exists');
SELECT has_function('retry_auth_cleanup', ARRAY[]::name[],
    'Q1 retry_auth_cleanup() exists');

-- 62d: ranking excludes private rows, includes opted-in rows
SELECT lives_ok(
    $$INSERT INTO public.users
        (id, username, date_of_birth, personal_shards, profile_public)
      VALUES
        ('62626262-6262-4262-8262-626262626201', 'pgtapprivate',
         DATE '1990-08-01', 999999, false)$$,
    'Q8 private ranking fixture inserted'
);
SELECT is(
    (SELECT count(*) FROM public.get_user_ranking(100)
      WHERE user_id = '62626262-6262-4262-8262-626262626201'),
    0::bigint,
    'Q8 private profile has no ranking entry'
);
UPDATE public.users SET profile_public = true
 WHERE id = '62626262-6262-4262-8262-626262626201';
SELECT is(
    (SELECT count(*) FROM public.get_user_ranking(100)
      WHERE user_id = '62626262-6262-4262-8262-626262626201'),
    1::bigint,
    'Q8 opted-in profile enters the ranking'
);

-- 62e: Q1 hard delete keeps only pseudonymized facts / restricted evidence
SELECT lives_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('62626262-6262-4262-8262-626262626210', 'pgtapowner',
         DATE '1990-09-01'),
        ('62626262-6262-4262-8262-626262626211', 'pgtapdeleted',
         DATE '1990-09-02')$$,
    'Q1 deletion fixtures inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.events
        (id, name, type, created_by_user_id, starts_at, ends_at, capacity, status)
      VALUES
        ('62626262-6262-4262-8262-626262626220', 'pgtap retained event',
         'casual', '62626262-6262-4262-8262-626262626210',
         now() + interval '2 days', now() + interval '2 days 2 hours',
         5, 'upcoming')$$,
    'Q1 retention event inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.event_attendances (event_id, user_id) VALUES
        ('62626262-6262-4262-8262-626262626220',
         '62626262-6262-4262-8262-626262626211')$$,
    'Q1 attendance fixture inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.shard_ledger (user_id, delta, reason) VALUES
        ('62626262-6262-4262-8262-626262626211', 7, 'admin_grant')$$,
    'Q1 ledger fixture inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.reports (reporter_id, target_type, target_id, reason)
      VALUES ('62626262-6262-4262-8262-626262626211', 'user',
              '62626262-6262-4262-8262-626262626210', 'pgtap evidence')$$,
    'Q1 report evidence fixture inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.chats (id, type) VALUES
        ('62626262-6262-4262-8262-626262626230', 'direct')$$,
    'Q1 chat fixture inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.chat_participants (chat_id, user_id) VALUES
        ('62626262-6262-4262-8262-626262626230',
         '62626262-6262-4262-8262-626262626210'),
        ('62626262-6262-4262-8262-626262626230',
         '62626262-6262-4262-8262-626262626211')$$,
    'Q1 chat participants inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.messages (chat_id, sender_id, content) VALUES
        ('62626262-6262-4262-8262-626262626230',
         '62626262-6262-4262-8262-626262626211', 'ciphertext-pgtap')$$,
    'Q1 sent message fixture inserted'
);
SELECT set_config('request.jwt.claims',
    '{"sub":"62626262-6262-4262-8262-626262626211","role":"authenticated"}', false);
SELECT lives_ok($$SELECT public.delete_my_account()$$,
    'Q1 delete_my_account purges immediately');
SELECT set_config('request.jwt.claims', '', false);
SELECT is(
    (SELECT count(*) FROM public.users
      WHERE id = '62626262-6262-4262-8262-626262626211'),
    0::bigint,
    'Q1 users row is hard-deleted'
);
SELECT is(
    (SELECT count(*) FROM public.reports
      WHERE reporter_id IS NULL
        AND reporter_pseudonym LIKE 'deleted:%'),
    1::bigint,
    'Q1 report evidence survives with a pseudonym'
);
SELECT ok(
    (SELECT user_id IS NULL AND retention_until > now()
       FROM public.shard_ledger
      WHERE id IN (SELECT id FROM public.shard_ledger
                    WHERE pseudonymized_at IS NOT NULL)
      ORDER BY id DESC LIMIT 1),
    'Q1 ledger retained pseudonymized with a 5-year clock'
);
SELECT ok(
    (SELECT user_id IS NULL AND retention_until > now()
       FROM public.event_attendances
      WHERE pseudonymized_at IS NOT NULL
      ORDER BY id DESC LIMIT 1),
    'Q1 attendance retained pseudonymized with a 5-year clock'
);
SELECT is(
    (SELECT count(*) FROM public.messages
      WHERE sender_id = '62626262-6262-4262-8262-626262626211'),
    0::bigint,
    'Q1 sent messages are hard-deleted'
);

-- 62f: SEC-050 export completeness
SELECT lives_ok(
    $$INSERT INTO public.users (id, username, date_of_birth) VALUES
        ('62626262-6262-4262-8262-626262626240', 'pgtapexporter',
         DATE '1990-10-01'),
        ('62626262-6262-4262-8262-626262626241', 'pgtapsender',
         DATE '1990-10-02')$$,
    'SEC-050 export fixtures inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.chats (id, type) VALUES
        ('62626262-6262-4262-8262-626262626250', 'direct')$$,
    'SEC-050 export chat inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.chat_participants (chat_id, user_id) VALUES
        ('62626262-6262-4262-8262-626262626250',
         '62626262-6262-4262-8262-626262626240'),
        ('62626262-6262-4262-8262-626262626250',
         '62626262-6262-4262-8262-626262626241')$$,
    'SEC-050 export participants inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.messages (chat_id, sender_id, content, recipient_id)
      VALUES ('62626262-6262-4262-8262-626262626250',
              '62626262-6262-4262-8262-626262626241',
              'ciphertext-received',
              '62626262-6262-4262-8262-626262626240')$$,
    'SEC-050 received message inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.device_tokens (user_id, token, platform) VALUES
        ('62626262-6262-4262-8262-626262626240',
         'pgtap_device_token_1234567890', 'ios')$$,
    'SEC-050 device token inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.minigame_sessions
        (id, game_type, status, shard_wager, player_limit, participants)
      VALUES ('62626262-6262-4262-8262-626262626260',
              'two_lies_one_truth', 'active', 0, 8,
              ARRAY['62626262-6262-4262-8262-626262626240',
                    '62626262-6262-4262-8262-626262626241']::uuid[])$$,
    'SEC-050 minigame session inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.minigame_answers
        (session_id, round, subject_id, prompt_type, answer_ciphertext)
      VALUES ('62626262-6262-4262-8262-626262626260', 1,
              '62626262-6262-4262-8262-626262626240',
              'text', 'ciphertext-answer')$$,
    'SEC-050 minigame answer inserted'
);
SELECT lives_ok(
    $$INSERT INTO public.reports (reporter_id, target_type, target_id, reason)
      VALUES ('62626262-6262-4262-8262-626262626240', 'user',
              '62626262-6262-4262-8262-626262626241', 'export evidence')$$,
    'SEC-050 report fixture inserted'
);
SELECT set_config('request.jwt.claims',
    '{"sub":"62626262-6262-4262-8262-626262626240","role":"authenticated"}', false);
SELECT ok(jsonb_exists(public.export_my_data(), 'messages_received'),
    'SEC-050 export includes received messages');
SELECT ok(jsonb_exists(public.export_my_data(), 'minigame_answers'),
    'SEC-050 export includes minigame answers');
SELECT ok(jsonb_exists(public.export_my_data(), 'device_tokens'),
    'SEC-050 export includes device tokens');
SELECT ok(jsonb_exists(public.export_my_data(), 'reports'),
    'SEC-050 export includes submitted reports');
SELECT ok(jsonb_exists(public.export_my_data(), 'exclusions'),
    'SEC-050 export discloses its exclusions');
SELECT ok(jsonb_exists(public.export_my_data(), 'retention'),
    'Q1 export carries the retention matrix');
SELECT is(public.export_my_data() ->> 'schema', 'samay.export.v2',
    'SEC-050 export schema is v2');
SELECT set_config('request.jwt.claims', '', true);

SELECT * FROM finish();
ROLLBACK;