-- ============================================================================
-- 300_slim/05_revoke_removed.sql — close every removed-feature relation
--
-- Slim-prod ships games, auth, profile, settings, notifications/push,
-- friends, groups and prompt packs only. The tables below still exist (their
-- data is retained and the migration history is immutable), but NO client
-- role may touch them. Progressive re-add is literally a GRANT away:
-- re-granting SELECT(/INSERT/...) to `authenticated` (plus the feature's RPCs)
-- restores the surface — nothing is dropped here.
--
-- SECURITY-DEFINER note: every server path that still resolves a revoked
-- relation runs as the function owner (SECURITY DEFINER), so revoking the
-- client grants is safe:
--   * user_search_view — search_users(), get_chat_inbox(),
--     get_minigame_participants(), notify_minigame_invite() and
--     notify_minigame_group_message() are all SECURITY DEFINER.
--   * shard_ledger / preshard_ledger — export_my_data(), purge_user(),
--     the retention job and finish_minigame_game() are SECURITY DEFINER.
--   * messages / chats — get_chat_inbox() and every moderation trigger run
--     SECURITY DEFINER.
--   * minigame_group_messages — the group-notice trigger is SECURITY DEFINER
--     (and reveal/draw paths do not read it).
--
-- Rollback: forward-fix (re-grant) only.
-- ============================================================================

BEGIN;

DO $$
DECLARE
    v_rel text;
    v_rels text[] := ARRAY[
        -- events + event sub-tables
        'events', 'event_hosts', 'event_invites', 'event_attendances',
        'event_photos', 'event_photo_likes', 'event_scan_nonces',
        'event_code_keys', 'event_join_requests',
        -- share links
        'share_links',
        -- E2EE chat
        'chats', 'chat_participants', 'messages', 'message_reads',
        'deleted_messages', 'message_reports', 'e2ee_identity_keys',
        -- cosmetics
        'cosmetics', 'user_cosmetics', 'group_cosmetics',
        -- shards / wagers / rankings ledgers
        'shard_ledger', 'preshard_ledger', 'group_shard_contributions',
        'group_rank_snapshots',
        -- discovery / search surfaces
        'discovery_view', 'user_search_view', 'search_rate_limits',
        -- group match notices
        'minigame_group_messages'
    ];
BEGIN
    FOREACH v_rel IN ARRAY v_rels LOOP
        -- Guard by to_regclass: a forward-fix must survive any relation that
        -- a later slim layer already dropped.
        IF to_regclass('public.' || v_rel) IS NOT NULL THEN
            EXECUTE format(
                'REVOKE ALL ON TABLE public.%I FROM anon, authenticated',
                v_rel);
        END IF;
    END LOOP;
END;
$$;

-- The ledger of applied migrations stays server-only too (defense in depth).
DO $$
BEGIN
    IF to_regclass('public._qallariy_migrations') IS NOT NULL THEN
        REVOKE ALL ON TABLE public._qallariy_migrations FROM anon, authenticated;
    END IF;
END;
$$;

COMMIT;
