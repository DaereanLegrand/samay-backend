-- 210_minigame_group_message — group match creation fans out to every active
-- member AND posts a chat notice in the group thread.
--
-- WHY (2026-09-15):
--   * 2a — a group partida must automatically mark EVERY active group member
--     as invited (the creator excluded), not only the explicitly picked ones.
--     The explicit-invitee cap + privacy gates above stay for picked users;
--     the group fan-out bypasses them (members are siblings and may be
--     non-friends) and the accept path still enforces the player limit.
--   * 2b — creating the group partida must also drop a message in the group
--     chat that is a DIRECT ACCESS to the match. `messages.content` is E2EE
--     ciphertext, so a server-visible notice cannot live there; it gets its
--     own table `minigame_group_messages`, written by a SECURITY DEFINER
--     trigger on session insert and rendered as a special bubble client-side.

-- ======================================================================
-- 1. create_minigame_session — group fan-out (2a)
--    (drop/recreate of the live 202 11-argument signature; only section 6d is
--    new)
-- ======================================================================
DROP FUNCTION IF EXISTS public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text, p_rounds integer, p_prize_positions integer, p_play_mode text, p_anonymous boolean, p_async_rounds_per_player integer, p_async_ends_at timestamp with time zone);

CREATE FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[] DEFAULT '{}'::uuid[], p_name text DEFAULT NULL, p_rounds integer DEFAULT 5, p_prize_positions integer DEFAULT 3, p_play_mode text DEFAULT 'by_turns', p_anonymous boolean DEFAULT false, p_async_rounds_per_player integer DEFAULT 1, p_async_ends_at timestamp with time zone DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_session_id uuid;
    v_game_type public.mini_game_type;
    v_current_user uuid;
    v_invitee uuid;
    v_clean_invitees uuid[] := '{}'::uuid[];
    v_tier public.subscription_tier;
    v_player_limit integer;
    v_name text;
    v_auto_name text;
    v_rounds integer;
    v_prize_positions integer;
    v_play_mode text;
    v_anonymous boolean;
    v_async_rounds integer;
    v_async_ends_at timestamp with time zone;
BEGIN
    -- 1. Authentication gate.
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 1b. Player cap frozen at creation (direct-minigames 2026-08-27).
    SELECT subscription_tier INTO v_tier
    FROM public.users WHERE id = v_current_user;
    v_player_limit := COALESCE((
        SELECT value::integer FROM public.app_config
        WHERE key = CASE v_tier
            WHEN 'vip'::public.subscription_tier THEN 'minigame.vip_max_players'
            WHEN 'pro'::public.subscription_tier THEN 'minigame.pro_max_players'
            ELSE 'minigame.free_max_players'
        END
    ), 8);

    -- 2. Group-membership gate (direct-minigames 2026-08-27).
    IF p_group_id IS NOT NULL AND NOT public.is_group_member(p_group_id) THEN
        RETURN jsonb_build_object('status', 'not_member');
    END IF;

    -- 3. Wager validation.
    IF p_wager < 0 THEN
        RETURN jsonb_build_object('status', 'invalid_wager');
    END IF;

    -- 4. Game-type validation.
    BEGIN
        v_game_type := p_game_type::public.mini_game_type;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('status', 'invalid_game_type');
    END;

    -- 4b. Round-target validation (201).
    v_rounds := COALESCE(p_rounds, 5);
    IF v_rounds < 1 THEN
        RETURN jsonb_build_object('status', 'invalid_rounds');
    END IF;

    -- 4c. Prize-position validation (201).
    v_prize_positions := COALESCE(p_prize_positions, 3);
    IF v_prize_positions < 1 THEN
        RETURN jsonb_build_object('status', 'invalid_prize_positions');
    END IF;

    -- 4d. Play-mode validation (202).
    v_play_mode := COALESCE(p_play_mode, 'by_turns');
    IF v_play_mode NOT IN ('by_turns', 'async') THEN
        RETURN jsonb_build_object('status', 'invalid_play_mode');
    END IF;

    -- 4e. Async validation: rounds-per-player >= 1; async requires a
    --     deadline; by_turns rejects an async deadline.
    v_anonymous := COALESCE(p_anonymous, false);
    v_async_rounds := COALESCE(p_async_rounds_per_player, 1);
    IF v_async_rounds < 1 THEN
        RETURN jsonb_build_object('status', 'invalid_async_rounds');
    END IF;
    IF v_play_mode = 'async' THEN
        v_async_ends_at := p_async_ends_at;
        IF v_async_ends_at IS NULL OR v_async_ends_at <= now() THEN
            RETURN jsonb_build_object('status', 'invalid_async_ends_at');
        END IF;
    ELSE
        v_async_ends_at := NULL;
    END IF;

    -- 5. Invitee cleaning + per-invitee gates (unchanged from 201).
    IF p_invitees IS NOT NULL AND array_length(p_invitees, 1) > 0 THEN
        FOR v_invitee IN
            SELECT DISTINCT unnest(p_invitees)
        LOOP
            IF v_invitee = v_current_user THEN
                CONTINUE;
            END IF;
            IF array_length(v_clean_invitees, 1) >= 20 THEN
                RETURN jsonb_build_object('status', 'too_many_invitees');
            END IF;

            IF NOT EXISTS (
                SELECT 1 FROM public.users
                WHERE id = v_invitee AND deleted_at IS NULL
            ) THEN
                RETURN jsonb_build_object('status', 'invitee_not_allowed');
            END IF;
            IF EXISTS (
                SELECT 1 FROM public.friendships
                WHERE status = 'blocked'::public.friendship_status
                  AND ((requester_id = v_current_user AND addressee_id = v_invitee)
                    OR (requester_id = v_invitee AND addressee_id = v_current_user))
            ) THEN
                RETURN jsonb_build_object('status', 'invitee_not_allowed');
            END IF;

            IF EXISTS (
                SELECT 1 FROM public.users
                WHERE id = v_invitee AND minigame_invite_friends_only = true
            ) AND NOT EXISTS (
                SELECT 1 FROM public.friendships
                WHERE status = 'accepted'::public.friendship_status
                  AND ((requester_id = v_current_user AND addressee_id = v_invitee)
                    OR (requester_id = v_invitee AND addressee_id = v_current_user))
            ) THEN
                RETURN jsonb_build_object('status', 'invitee_friends_only');
            END IF;

            v_clean_invitees := v_clean_invitees || v_invitee;
        END LOOP;
    END IF;

    -- 6. Player-cap gate (explicit invitees only — the group fan-out below is
    --    intentionally not capped; accept enforces the limit).
    IF (1 + COALESCE(array_length(v_clean_invitees, 1), 0)) > v_player_limit THEN
        RETURN jsonb_build_object('status', 'player_limit_reached');
    END IF;

    -- 6b. Partida name.
    v_name := NULLIF(btrim(p_name), '');

    -- 6c. Auto partida name.
    v_auto_name := 'partida-' || (
        SELECT count(*) + 1
        FROM public.minigame_sessions
        WHERE game_type = v_game_type AND status = 'active'
    );

    -- 6d. Group fan-out (210, 2026-09-15): a group partida automatically marks
    --     EVERY active member as invited (creator excluded, explicit invitees
    --     deduped). Deliberately bypasses the explicit cap/privacy gates —
    --     members are siblings and may be non-friends; accept still enforces
    --     the player limit. Runs after the cap gate above so a large group
    --     never blocks creation.
    IF p_group_id IS NOT NULL THEN
        FOR v_invitee IN
            SELECT gm.user_id
            FROM public.group_members AS gm
            JOIN public.users AS u
              ON u.id = gm.user_id AND u.deleted_at IS NULL
            WHERE gm.group_id = p_group_id
              AND gm.status = 'active'
              AND gm.user_id <> v_current_user
              AND NOT (gm.user_id = ANY (v_clean_invitees))
        LOOP
            v_clean_invitees := v_clean_invitees || v_invitee;
        END LOOP;
    END IF;

    -- 7. Wager escrow.
    IF p_wager > 0 THEN
        UPDATE public.users
        SET personal_shards = personal_shards - p_wager
        WHERE id = v_current_user AND personal_shards >= p_wager;

        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'insufficient_shards');
        END IF;
    END IF;

    -- 8. Session insert (new 202 options frozen on the row).
    INSERT INTO public.minigame_sessions
        (group_id, game_type, status, shard_wager, player_limit, participants, name, auto_name, round_target, prize_positions, play_mode, anonymous, async_rounds_per_player, async_ends_at)
    VALUES
        (p_group_id, v_game_type, 'active', p_wager, v_player_limit,
         ARRAY[v_current_user], v_name, v_auto_name, v_rounds, v_prize_positions,
         v_play_mode, v_anonymous, v_async_rounds, v_async_ends_at)
    RETURNING id INTO v_session_id;

    -- 9. Ledger entry.
    IF p_wager > 0 THEN
        INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
        VALUES (v_current_user, -p_wager, 'minigame_wager', v_session_id);
    END IF;

    -- 9b. Seed the game-state row (191/201) with the mode fields pre-loaded.
    INSERT INTO public.minigame_game_state (session_id, game_type, state, ready)
    VALUES (v_session_id, v_game_type,
            jsonb_build_object(
                'round', 0,
                'round_target', v_rounds,
                'prize_positions', v_prize_positions,
                'reactions', '{}'::jsonb,
                'play_mode', v_play_mode,
                'anonymous', v_anonymous,
                'async_rounds_per_player', v_async_rounds,
                'async_ends_at', v_async_ends_at,
                'round_map', '{}'::jsonb,
                'answers', '[]'::jsonb
            ),
            '{}'::jsonb);

    -- 10. Invite rows.
    IF array_length(v_clean_invitees, 1) > 0 THEN
        FOREACH v_invitee IN ARRAY v_clean_invitees
        LOOP
            INSERT INTO public.minigame_invites (session_id, invitee_id, created_by)
            VALUES (v_session_id, v_invitee, v_current_user)
            ON CONFLICT (session_id, invitee_id) DO NOTHING;
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'status', 'created',
        'sessionId', v_session_id,
        'invited', COALESCE(array_length(v_clean_invitees, 1), 0)
    );
END;
$$;

-- ACL — the redefined create_minigame_session keeps the 202 grants; re-assert.
REVOKE ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text, p_rounds integer, p_prize_positions integer, p_play_mode text, p_anonymous boolean, p_async_rounds_per_player integer, p_async_ends_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text, p_rounds integer, p_prize_positions integer, p_play_mode text, p_anonymous boolean, p_async_rounds_per_player integer, p_async_ends_at timestamp with time zone) TO authenticated;
GRANT ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text, p_rounds integer, p_prize_positions integer, p_play_mode text, p_anonymous boolean, p_async_rounds_per_player integer, p_async_ends_at timestamp with time zone) TO service_role;

-- ======================================================================
-- 2. minigame_group_messages — the group-chat "match created" notice (2b)
-- ======================================================================
CREATE TABLE public.minigame_group_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chat_id uuid NOT NULL,
    group_id uuid NOT NULL,
    session_id uuid NOT NULL,
    actor_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT minigame_group_messages_pkey PRIMARY KEY (id),
    CONSTRAINT minigame_group_messages_session_id_key UNIQUE (session_id),
    CONSTRAINT minigame_group_messages_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE,
    CONSTRAINT minigame_group_messages_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.groups(id) ON DELETE CASCADE,
    CONSTRAINT minigame_group_messages_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.minigame_sessions(id) ON DELETE CASCADE,
    CONSTRAINT minigame_group_messages_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.users(id) ON DELETE CASCADE
);

ALTER TABLE ONLY public.minigame_group_messages REPLICA IDENTITY FULL;
ALTER TABLE public.minigame_group_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.minigame_group_messages FORCE ROW LEVEL SECURITY;

-- Group members read the notice; only the SECURITY DEFINER trigger writes it.
CREATE POLICY mgm_read_group_member ON public.minigame_group_messages
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.group_members AS gm
            WHERE gm.group_id = minigame_group_messages.group_id
              AND gm.user_id = auth.uid()
              AND gm.status = 'active'
        )
    );

REVOKE ALL ON TABLE public.minigame_group_messages FROM anon;
REVOKE ALL ON TABLE public.minigame_group_messages FROM authenticated;
GRANT SELECT ON TABLE public.minigame_group_messages TO authenticated;
GRANT ALL ON TABLE public.minigame_group_messages TO service_role;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'minigame_group_messages'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.minigame_group_messages;
    END IF;
END;
$$;

-- Trigger: on a GROUP session insert, drop the notice into the group chat.
CREATE FUNCTION public.notify_minigame_group_message() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_chat_id uuid;
    v_actor uuid;
BEGIN
    IF NEW.group_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT id INTO v_chat_id
    FROM public.chats
    WHERE type = 'group'::public.chat_type
      AND reference_id = NEW.group_id
    LIMIT 1;
    IF v_chat_id IS NULL THEN
        -- P1 (2026-09-15): the group chat is server-guaranteed. A group
        -- created outside the app (seed/backfill/REST) may lack one; create it
        -- here (idempotent under the partial unique index) so the notice
        -- always lands somewhere. The AFTER INSERT trigger on chats then
        -- populates chat_participants for the active members.
        BEGIN
            INSERT INTO public.chats (type, reference_id)
            VALUES ('group'::public.chat_type, NEW.group_id)
            RETURNING id INTO v_chat_id;
        EXCEPTION WHEN unique_violation THEN
            SELECT id INTO v_chat_id
            FROM public.chats
            WHERE type = 'group'::public.chat_type
              AND reference_id = NEW.group_id
            LIMIT 1;
        END;
    END IF;
    IF v_chat_id IS NULL THEN
        RETURN NEW;
    END IF;

    v_actor := COALESCE(NEW.participants[1], auth.uid());
    IF v_actor IS NULL THEN
        RETURN NEW;
    END IF;

    INSERT INTO public.minigame_group_messages
        (chat_id, group_id, session_id, actor_id)
    VALUES (v_chat_id, NEW.group_id, NEW.id, v_actor)
    ON CONFLICT (session_id) DO NOTHING;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS minigame_group_message_trigger ON public.minigame_sessions;
CREATE TRIGGER minigame_group_message_trigger
    AFTER INSERT ON public.minigame_sessions
    FOR EACH ROW EXECUTE FUNCTION public.notify_minigame_group_message();

-- ACL — trigger-only function: never callable by anon/authenticated (the
-- trigger fires as its owner). service_role keeps EXECUTE for completeness.
REVOKE ALL ON FUNCTION public.notify_minigame_group_message() FROM PUBLIC;
GRANT ALL ON FUNCTION public.notify_minigame_group_message() TO service_role;

-- ======================================================================
-- 3. Server-side group-chat guarantee + backfill (P1, 2026-09-15)
-- ======================================================================
-- One group chat per group. The partial index leaves direct (NULL ref) and
-- event chats untouched; it also makes the notice-trigger's create-some
-- idempotent under a race.
CREATE UNIQUE INDEX IF NOT EXISTS chats_group_reference_uniq
    ON public.chats (reference_id)
    WHERE type = 'group'::public.chat_type;

-- Backfill: every group owns a chat (a group created outside the app — the
-- seeded "Cowboy Bebopers" etc. — otherwise had none). The AFTER INSERT
-- trigger on chats populates chat_participants for the active members, so the
-- group chat appears in everyone's inbox too.
INSERT INTO public.chats (type, reference_id)
SELECT 'group'::public.chat_type, g.id
FROM public.groups AS g
WHERE NOT EXISTS (
    SELECT 1 FROM public.chats AS c
    WHERE c.type = 'group'::public.chat_type AND c.reference_id = g.id
);

-- Backfill notices for existing ACTIVE group sessions that predate the
-- chat-creation fix, so already-created matches surface in the thread/inbox.
INSERT INTO public.minigame_group_messages
    (chat_id, group_id, session_id, actor_id, created_at)
SELECT c.id, ms.group_id, ms.id, ms.participants[1], ms.created_at
FROM public.minigame_sessions AS ms
JOIN public.chats AS c
  ON c.type = 'group'::public.chat_type AND c.reference_id = ms.group_id
WHERE ms.group_id IS NOT NULL
  AND ms.status = 'active'
  AND ms.participants[1] IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM public.minigame_group_messages AS m
      WHERE m.session_id = ms.id
  )
ON CONFLICT (session_id) DO NOTHING;

-- ======================================================================
-- 4. get_chat_inbox — a minigame notice counts as chat activity (P1)
--    Adds last_activity_* + last_notice_* so the client can preview
--    "Nueva partida de {game}", bump the chat to the top and show unread.
-- ======================================================================
DROP FUNCTION IF EXISTS public.get_chat_inbox();

CREATE FUNCTION public.get_chat_inbox() RETURNS TABLE(chat_id uuid, type public.chat_type, reference_id uuid, peer_id uuid, peer_username text, peer_avatar_url text, last_message_id uuid, last_message_sender_id uuid, last_message_recipient_id uuid, last_message_content text, last_message_created_at timestamp with time zone, unread_count bigint, last_activity_at timestamp with time zone, last_activity_kind text, last_notice_session_id uuid, last_notice_game_type text, last_notice_status text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
BEGIN
    IF v_me IS NULL THEN
        RAISE EXCEPTION 'Not authorized';
    END IF;

    RETURN QUERY
    SELECT
        c.id,
        c.type,
        c.reference_id,
        CASE WHEN c.type = 'group' THEN NULL ELSE usv.id END,
        CASE WHEN c.type = 'group' THEN g.name ELSE usv.username END,
        CASE WHEN c.type = 'group' THEN g.cover_url ELSE usv.avatar_url END,
        lm.id,
        lm.sender_id,
        lm.recipient_id,
        lm.content,
        lm.created_at,
        (SELECT count(*) FROM public.messages m
          WHERE m.chat_id = c.id
            AND m.sender_id <> v_me
            AND m.recipient_id IS NULL
            AND m.created_at > cp.last_read_at)
        + (SELECT count(*) FROM public.minigame_group_messages nmu
            WHERE nmu.chat_id = c.id
              AND nmu.created_at > cp.last_read_at),
        GREATEST(lm.created_at, nm.created_at),
        CASE
            WHEN nm.created_at IS NOT NULL
                 AND (lm.created_at IS NULL OR nm.created_at > lm.created_at)
            THEN 'minigame_notice'
            ELSE 'message'
        END,
        nm.session_id,
        nm.game_type::text,
        nm.status::text
    FROM public.chats c
    JOIN public.chat_participants cp
      ON cp.chat_id = c.id AND cp.user_id = v_me
    LEFT JOIN public.groups g
      ON c.type = 'group' AND g.id = c.reference_id
    LEFT JOIN public.user_search_view usv
      ON usv.id = (
          SELECT cp2.user_id FROM public.chat_participants cp2
          WHERE cp2.chat_id = c.id AND cp2.user_id <> v_me
          LIMIT 1
      )
    LEFT JOIN LATERAL (
        SELECT messages.id, messages.sender_id, messages.recipient_id,
               messages.content, messages.created_at
        FROM public.messages
        WHERE messages.chat_id = c.id
          AND messages.recipient_id IS NULL
        ORDER BY messages.created_at DESC
        LIMIT 1
    ) lm ON TRUE
    LEFT JOIN LATERAL (
        SELECT m.session_id, m.created_at, ms.game_type, ms.status
        FROM public.minigame_group_messages m
        JOIN public.minigame_sessions ms ON ms.id = m.session_id
        WHERE m.chat_id = c.id
        ORDER BY m.created_at DESC
        LIMIT 1
    ) nm ON TRUE
    ORDER BY GREATEST(lm.created_at, nm.created_at) DESC NULLS LAST,
             c.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_chat_inbox() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_chat_inbox() TO authenticated;
