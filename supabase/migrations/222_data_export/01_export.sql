-- Samay — 222_data_export/01_export.sql (2026-10-04)
--
-- export_my_data(): returns the caller's own data as a single versioned JSON
-- document (Ley N° 29733 portability + the org's transparency ethos).
--
-- Deliberately EXCLUDED (never exported): E2EE private/key material
-- (e2ee_identity_keys, minigame_e2ee_bundles), event_code_keys.secret,
-- reports/admin_audit_log/search_rate_limits/processed_webhooks/
-- subscription_overrides. Chat is E2EE: the server can only return ciphertext;
-- readable chat history lives on-device and is exported by the Flutter client.
--
-- Run on supabase-testing first; mirrored byte-identical into
-- supabase-testing/migrations/.

CREATE OR REPLACE FUNCTION public.export_my_data() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    STABLE
    AS $$
DECLARE
    v_uid uuid;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = 'P0001';
    END IF;

    RETURN jsonb_build_object(
        'schema', 'samay.export.v1',
        'generated_at', now(),
        'user', (
            SELECT to_jsonb(u) FROM public.users u WHERE u.id = v_uid
        ),
        'friendships', COALESCE((
            SELECT jsonb_agg(to_jsonb(f)) FROM public.friendships f
             WHERE f.requester_id = v_uid OR f.addressee_id = v_uid
        ), '[]'::jsonb),
        'groups', COALESCE((
            SELECT jsonb_agg(to_jsonb(g)) FROM public.groups g
             WHERE g.created_by_user_id = v_uid
                OR EXISTS (SELECT 1 FROM public.group_members m
                            WHERE m.group_id = g.id AND m.user_id = v_uid)
        ), '[]'::jsonb),
        'group_members', COALESCE((
            SELECT jsonb_agg(to_jsonb(m)) FROM public.group_members m
             WHERE m.user_id = v_uid
        ), '[]'::jsonb),
        'group_shard_contributions', COALESCE((
            SELECT jsonb_agg(to_jsonb(c)) FROM public.group_shard_contributions c
             WHERE c.user_id = v_uid
        ), '[]'::jsonb),
        'events', COALESCE((
            SELECT jsonb_agg(to_jsonb(e)) FROM public.events e
             WHERE e.created_by_user_id = v_uid
                OR EXISTS (SELECT 1 FROM public.event_hosts h
                            WHERE h.event_id = e.id AND h.user_id = v_uid)
                OR EXISTS (SELECT 1 FROM public.event_attendances a
                            WHERE a.event_id = e.id AND a.user_id = v_uid)
                OR EXISTS (SELECT 1 FROM public.event_invites i
                            WHERE i.event_id = e.id AND i.user_id = v_uid)
        ), '[]'::jsonb),
        'event_hosts', COALESCE((
            SELECT jsonb_agg(to_jsonb(h)) FROM public.event_hosts h
             WHERE h.user_id = v_uid
        ), '[]'::jsonb),
        'event_invites', COALESCE((
            SELECT jsonb_agg(to_jsonb(i)) FROM public.event_invites i
             WHERE i.user_id = v_uid
        ), '[]'::jsonb),
        'event_attendances', COALESCE((
            SELECT jsonb_agg(to_jsonb(a)) FROM public.event_attendances a
             WHERE a.user_id = v_uid
        ), '[]'::jsonb),
        'event_photos', COALESCE((
            SELECT jsonb_agg(to_jsonb(p)) FROM public.event_photos p
             WHERE p.uploaded_by_user_id = v_uid
        ), '[]'::jsonb),
        'event_photo_likes', COALESCE((
            SELECT jsonb_agg(to_jsonb(l)) FROM public.event_photo_likes l
             WHERE l.user_id = v_uid
        ), '[]'::jsonb),
        'chats', COALESCE((
            SELECT jsonb_agg(to_jsonb(c)) FROM public.chats c
             WHERE c.id IN (SELECT cp.chat_id FROM public.chat_participants cp
                             WHERE cp.user_id = v_uid)
        ), '[]'::jsonb),
        'chat_participants', COALESCE((
            SELECT jsonb_agg(to_jsonb(cp)) FROM public.chat_participants cp
             WHERE cp.user_id = v_uid
        ), '[]'::jsonb),
        'messages', COALESCE((
            SELECT jsonb_agg(to_jsonb(m)) FROM public.messages m
             WHERE m.sender_id = v_uid
        ), '[]'::jsonb),
        'message_reads', COALESCE((
            SELECT jsonb_agg(to_jsonb(r)) FROM public.message_reads r
             WHERE r.user_id = v_uid
        ), '[]'::jsonb),
        'shard_ledger', COALESCE((
            SELECT jsonb_agg(to_jsonb(s)) FROM public.shard_ledger s
             WHERE s.user_id = v_uid
        ), '[]'::jsonb),
        'preshard_ledger', COALESCE((
            SELECT jsonb_agg(to_jsonb(s)) FROM public.preshard_ledger s
             WHERE s.user_id = v_uid
        ), '[]'::jsonb),
        'notifications', COALESCE((
            SELECT jsonb_agg(to_jsonb(n)) FROM public.notifications n
             WHERE n.user_id = v_uid
        ), '[]'::jsonb),
        'user_cosmetics', COALESCE((
            SELECT jsonb_agg(to_jsonb(uc)) FROM public.user_cosmetics uc
             WHERE uc.user_id = v_uid
        ), '[]'::jsonb),
        'minigame_sessions', COALESCE((
            SELECT jsonb_agg(to_jsonb(ms)) FROM public.minigame_sessions ms
             WHERE v_uid = ANY(ms.participants) OR ms.winner_id = v_uid
        ), '[]'::jsonb),
        'minigame_invites', COALESCE((
            SELECT jsonb_agg(to_jsonb(mi)) FROM public.minigame_invites mi
             WHERE mi.invitee_id = v_uid OR mi.created_by = v_uid
        ), '[]'::jsonb),
        'feature_requests', COALESCE((
            SELECT jsonb_agg(to_jsonb(fr)) FROM public.feature_requests fr
             WHERE fr.requested_by_user_id = v_uid
        ), '[]'::jsonb)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.export_my_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.export_my_data() TO authenticated;
