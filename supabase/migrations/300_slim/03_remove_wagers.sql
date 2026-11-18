-- ============================================================================
-- 300_slim/03_remove_wagers.sql — retire the shard wager/escrow economy
--
-- Slim-prod keeps the multi-game play engine but removes gambling entirely:
--   * create_minigame_session loses p_wager (the whole 11-arg overload is
--     dropped; CREATE OR REPLACE cannot change the argument list) and always
--     stores shard_wager = 0.
--   * Every minigame escrow write is neutralized while each function keeps
--     its status strings and all non-wager behaviour: join_minigame_session,
--     join_minigame_by_code, accept_minigame_invite,
--     remove_minigame_participant, finish_minigame_game,
--     abandon_minigame_game. finish_minigame_session / complete_minigame_game
--     were already dropped by 201_minigame_voting (guard-dropped here so a
--     re-added body can never resurrect escrow).
--   * The shard_wager COLUMN stays (retired) so old reads/notifications keep
--     working; it is always 0 from now on.
--
-- NON-MINIGAME shard hits that this file deliberately leaves alone:
--   * 060_events/03_economy.sql, 090_shards/ledgers.sql,
--     229_wave0_trust_boundary (grant/donate/distribute),
--     236_economy_distribution, create_my_profile → event/global economy,
--     not gameplay escrow. Left intact.
--   * 221/222/233 (erasure, export, retention) → ledger retention, untouched.
--
-- Rollback: forward-fix only (re-adding wagers is a product decision).
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. create_minigame_session — wager-free (new 10-arg signature).
--    Drop every historical overload first (3/4/5/7/11 args).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_minigame_session(uuid, text, integer);
DROP FUNCTION IF EXISTS public.create_minigame_session(uuid, text, integer, uuid[]);
DROP FUNCTION IF EXISTS public.create_minigame_session(uuid, text, integer, uuid[], text);
DROP FUNCTION IF EXISTS public.create_minigame_session(uuid, text, integer, uuid[], text, integer, integer);
DROP FUNCTION IF EXISTS public.create_minigame_session(uuid, text, integer, uuid[], text, integer, integer, text, boolean, integer, timestamp with time zone);

CREATE OR REPLACE FUNCTION public.create_minigame_session(
    p_group_id uuid,
    p_game_type text,
    p_invitees uuid[] DEFAULT '{}'::uuid[],
    p_name text DEFAULT NULL,
    p_rounds integer DEFAULT 5,
    p_prize_positions integer DEFAULT 3,
    p_play_mode text DEFAULT 'by_turns',
    p_anonymous boolean DEFAULT false,
    p_async_rounds_per_player integer DEFAULT 1,
    p_async_ends_at timestamp with time zone DEFAULT NULL
) RETURNS jsonb
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

    -- 1a. Onboarding gate (slim): a profile with the age gate + Terms
    --     accepted is required to host a match.
    IF NOT public.is_onboarded() THEN
        RETURN jsonb_build_object('status', 'not_onboarded');
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

    -- 3. Game-type validation.
    BEGIN
        v_game_type := p_game_type::public.mini_game_type;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('status', 'invalid_game_type');
    END;

    -- 3b. Round-target validation (201).
    v_rounds := COALESCE(p_rounds, 5);
    IF v_rounds < 1 THEN
        RETURN jsonb_build_object('status', 'invalid_rounds');
    END IF;

    -- 3c. Prize-position validation (201). Prizes are cosmetic now (no
    --     escrow), but the ranking contract still caps paid places.
    v_prize_positions := COALESCE(p_prize_positions, 3);
    IF v_prize_positions < 1 THEN
        RETURN jsonb_build_object('status', 'invalid_prize_positions');
    END IF;

    -- 3d. Play-mode validation (202).
    v_play_mode := COALESCE(p_play_mode, 'by_turns');
    IF v_play_mode NOT IN ('by_turns', 'async') THEN
        RETURN jsonb_build_object('status', 'invalid_play_mode');
    END IF;

    -- 3e. Async validation: rounds-per-player >= 1; async requires a
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

    -- 4. Invitee cleaning + per-invitee gates (unchanged from 201).
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

    -- 5. Player-cap gate (explicit invitees only — the group fan-out below
    --    is intentionally not capped; accept enforces the limit).
    IF (1 + COALESCE(array_length(v_clean_invitees, 1), 0)) > v_player_limit THEN
        RETURN jsonb_build_object('status', 'player_limit_reached');
    END IF;

    -- 5b. Partida name + auto name.
    v_name := NULLIF(btrim(p_name), '');
    v_auto_name := 'partida-' || (
        SELECT count(*) + 1
        FROM public.minigame_sessions
        WHERE game_type = v_game_type AND status = 'active'
    );

    -- 5c. Group fan-out (210, 2026-09-15): a group partida automatically
    --     marks EVERY active member as invited (creator excluded, explicit
    --     invitees deduped). Deliberately bypasses the explicit cap/privacy
    --     gates — members are siblings and may be non-friends; accept still
    --     enforces the player limit.
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

    -- 6. Session insert (300_slim: no wager/escrow — shard_wager retired 0).
    INSERT INTO public.minigame_sessions
        (group_id, game_type, status, shard_wager, player_limit, participants, name, auto_name, round_target, prize_positions, play_mode, anonymous, async_rounds_per_player, async_ends_at)
    VALUES
        (p_group_id, v_game_type, 'active', 0, v_player_limit,
         ARRAY[v_current_user], v_name, v_auto_name, v_rounds, v_prize_positions,
         v_play_mode, v_anonymous, v_async_rounds, v_async_ends_at)
    RETURNING id INTO v_session_id;

    -- 6b. Seed the game-state row (191/201) with the mode fields pre-loaded.
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

    -- 7. Invite rows.
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

REVOKE ALL ON FUNCTION public.create_minigame_session(uuid, text, uuid[], text, integer, integer, text, boolean, integer, timestamp with time zone) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_minigame_session(uuid, text, uuid[], text, integer, integer, text, boolean, integer, timestamp with time zone) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. join_minigame_session — drop the escrow deduction block.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.join_minigame_session(p_session_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_current_user uuid;
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_player_limit integer;
BEGIN
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT group_id, status, participants, player_limit
        INTO v_group_id, v_status, v_participants, v_player_limit
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    IF v_group_id IS NOT NULL THEN
        IF NOT public.is_group_member(v_group_id) THEN
            RETURN jsonb_build_object('status', 'not_member');
        END IF;
    ELSE
        IF v_current_user <> ALL(v_participants)
           AND NOT EXISTS (
               SELECT 1 FROM public.minigame_invites
               WHERE session_id = p_session_id
                 AND invitee_id = v_current_user
                 AND status = 'pending'
           )
        THEN
            RETURN jsonb_build_object('status', 'not_allowed');
        END IF;
    END IF;

    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    IF v_current_user = ANY(v_participants) THEN
        RETURN jsonb_build_object('status', 'joined');
    END IF;

    IF array_length(v_participants, 1) >= v_player_limit THEN
        RETURN jsonb_build_object('status', 'player_limit_reached');
    END IF;

    -- 300_slim: no escrow deduction — wagers are retired.

    UPDATE public.minigame_sessions
    SET participants = participants || ARRAY[v_current_user]
    WHERE id = p_session_id;

    RETURN jsonb_build_object('status', 'joined');
END;
$$;

REVOKE ALL ON FUNCTION public.join_minigame_session(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.join_minigame_session(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. join_minigame_by_code — drop the escrow deduction block.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.join_minigame_by_code(p_code text)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid := auth.uid();
    v_code text;
    v_session public.minigame_sessions;
    v_hash text;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    v_code := upper(btrim(COALESCE(p_code, '')));
    IF char_length(v_code) <> 6
       OR v_code !~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$' THEN
        RETURN jsonb_build_object('status', 'invalid_code');
    END IF;

    -- 10 attempts/min/account (per-IP flood guard is handled at the gateway).
    PERFORM public.consume_action_limit(
        v_uid, 'minigame_code_join', '', 10, interval '1 minute');

    v_hash := encode(extensions.digest(v_code, 'sha256'), 'hex');

    SELECT * INTO v_session
      FROM public.minigame_sessions
     WHERE join_code_hash = v_hash
       AND group_id IS NULL
       AND status = 'active'
     FOR UPDATE
     LIMIT 1;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'invalid_code');
    END IF;

    IF v_uid = ANY (v_session.participants) THEN
        RETURN jsonb_build_object('status', 'joined', 'session_id', v_session.id);
    END IF;

    IF array_length(v_session.participants, 1) >= v_session.player_limit THEN
        RETURN jsonb_build_object('status', 'player_limit_reached',
                                  'session_id', v_session.id);
    END IF;

    -- 300_slim: no escrow deduction — wagers are retired.

    UPDATE public.minigame_sessions
       SET participants = participants || ARRAY[v_uid]
     WHERE id = v_session.id;

    RETURN jsonb_build_object('status', 'joined', 'session_id', v_session.id);
END;
$$;

REVOKE ALL ON FUNCTION public.join_minigame_by_code(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.join_minigame_by_code(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. accept_minigame_invite — drop the escrow deduction block.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.accept_minigame_invite(p_invite_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_current_user uuid;
    v_invitee_id uuid;
    v_invite_status public.mini_game_invite_status;
    v_session_id uuid;
    v_group_id uuid;
    v_session_status public.mini_game_status;
    v_participants uuid[];
    v_player_limit integer;
BEGIN
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT session_id, invitee_id, status
        INTO v_session_id, v_invitee_id, v_invite_status
        FROM public.minigame_invites
        WHERE id = p_invite_id
        FOR UPDATE;
    IF NOT FOUND OR v_invitee_id <> v_current_user THEN
        RETURN jsonb_build_object('status', 'invite_not_found');
    END IF;

    IF v_invite_status = 'accepted' THEN
        RETURN jsonb_build_object('status', 'already_accepted');
    END IF;
    IF v_invite_status = 'declined' THEN
        RETURN jsonb_build_object('status', 'invite_not_active');
    END IF;

    SELECT group_id, status, participants, player_limit
        INTO v_group_id, v_session_status, v_participants, v_player_limit
        FROM public.minigame_sessions
        WHERE id = v_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    IF v_session_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_finished');
    END IF;

    IF v_current_user = ANY(v_participants) THEN
        UPDATE public.minigame_invites
        SET status = 'accepted', decided_at = now()
        WHERE id = p_invite_id;
        RETURN jsonb_build_object('status', 'accepted');
    END IF;

    IF array_length(v_participants, 1) >= v_player_limit THEN
        RETURN jsonb_build_object('status', 'player_limit_reached');
    END IF;

    -- 300_slim: no escrow deduction — wagers are retired.

    UPDATE public.minigame_sessions
    SET participants = participants || ARRAY[v_current_user]
    WHERE id = v_session_id;

    UPDATE public.minigame_invites
    SET status = 'accepted', decided_at = now()
    WHERE id = p_invite_id;

    RETURN jsonb_build_object('status', 'accepted');
END;
$$;

REVOKE ALL ON FUNCTION public.accept_minigame_invite(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_minigame_invite(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. remove_minigame_participant — drop the refund block.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.remove_minigame_participant(p_session_id uuid, p_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_new_participants uuid[];
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- Creator gate — the caller MUST be participants[0] (the session host).
    IF array_length(v_participants, 1) IS NULL
       OR v_participants[1] <> auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_creator');
    END IF;

    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    IF p_user_id = auth.uid() OR NOT (p_user_id = ANY(v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_participant');
    END IF;

    -- 300_slim: no escrow refund — wagers are retired.

    SELECT array_agg(p) INTO v_new_participants
      FROM unnest(v_participants) AS p
     WHERE p <> p_user_id;
    IF v_new_participants IS NULL THEN
        v_new_participants := ARRAY[]::uuid[];
    END IF;
    UPDATE public.minigame_sessions
    SET participants = v_new_participants
    WHERE id = p_session_id;

    DELETE FROM public.minigame_invites
    WHERE session_id = p_session_id AND invitee_id = p_user_id;

    UPDATE public.minigame_game_state
    SET ready = ready - p_user_id::text
    WHERE session_id = p_session_id;

    RETURN jsonb_build_object('status', 'removed');
END;
$$;

REVOKE ALL ON FUNCTION public.remove_minigame_participant(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.remove_minigame_participant(uuid, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. abandon_minigame_game — drop the refund block, keep both statuses.
--    (229 body; the abandoned/recorded contract and the game-state writes
--    stay byte-identical apart from the removed refund.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.abandon_minigame_game(p_session_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_status public.mini_game_status;
    v_participants uuid[];
    v_state jsonb;
    v_abandoned jsonb;
    v_host uuid;
    v_non_host uuid[];
    v_all_abandoned boolean;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT status, participants
      INTO v_status, v_participants
      FROM public.minigame_sessions
     WHERE id = p_session_id
       FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'already_finished');
    END IF;
    IF NOT (v_me = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    SELECT state INTO v_state
      FROM public.minigame_game_state
     WHERE session_id = p_session_id
       FOR UPDATE;
    v_abandoned := COALESCE(v_state -> 'abandoned', '[]'::jsonb);
    IF NOT (v_abandoned ? v_me::text) THEN
        v_abandoned := v_abandoned || to_jsonb(v_me);
    END IF;

    v_host := v_participants[1];
    SELECT COALESCE(array_agg(u), '{}'::uuid[])
      INTO v_non_host
      FROM unnest(v_participants) AS u
     WHERE u <> v_host;

    v_all_abandoned := (v_me = v_host) OR NOT EXISTS (
        SELECT 1 FROM unnest(v_non_host) AS u
        WHERE NOT (v_abandoned ? u::text)
    );

    IF v_all_abandoned THEN
        -- 300_slim: wagers retired, nothing to refund. `refunded` stays in
        -- the payload (always 0) for client compatibility.
        UPDATE public.minigame_sessions
           SET status = 'finished'
         WHERE id = p_session_id;

        UPDATE public.minigame_game_state
           SET state = COALESCE(state, '{}'::jsonb) || jsonb_build_object(
                   'phase', 'finished',
                   'abandoned', true,
                   'result', 'abandoned',
                   'abandoned_by', v_abandoned
               )
         WHERE session_id = p_session_id;

        RETURN jsonb_build_object(
            'status', 'abandoned',
            'refunded', 0
        );
    END IF;

    UPDATE public.minigame_game_state
       SET state = COALESCE(state, '{}'::jsonb) || jsonb_build_object(
               'abandoned', v_abandoned
           )
     WHERE session_id = p_session_id;

    RETURN jsonb_build_object('status', 'recorded', 'abandoned', v_abandoned);
END;
$$;

REVOKE ALL ON FUNCTION public.abandon_minigame_game(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.abandon_minigame_game(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. finish_minigame_game — settle the leaderboard with ZERO prizes.
--    All scoreboard/harmonic/result logic is preserved (schema_test's
--    numeric/gcd/pass_count/full-ranking contract); the pot is forced to 0
--    and the paying block is gone, so no personal_shards / shard_ledger write
--    ever happens.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.finish_minigame_game(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_prize_positions integer;
    v_rounds jsonb[];
    v_state jsonb;
    v_play_mode text;
    v_pot integer;
    v_prize_rows jsonb;
    v_row jsonb;
    v_player_count integer;
    v_lcm integer;
    v_denom integer;
    v_r integer;
    v_weights jsonb;
    v_base jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock.
    SELECT group_id, status, participants, prize_positions
        INTO v_group_id, v_status, v_participants, v_prize_positions
        FROM public.minigame_sessions
        WHERE id = p_session_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate.
    IF NOT (
            (v_group_id IS NULL AND auth.uid() = ANY (v_participants))
         OR EXISTS (
                SELECT 1 FROM public.minigame_invites mi
                WHERE mi.session_id = p_session_id AND mi.invitee_id = auth.uid()
            )
         OR EXISTS (
                SELECT 1 FROM public.group_members gm
                WHERE gm.group_id = v_group_id AND gm.user_id = auth.uid()
                  AND gm.status = 'active'
                  AND NOT EXISTS (
                        SELECT 1 FROM public.users u
                        WHERE u.id = gm.user_id AND u.deleted_at IS NOT NULL
                    )
            )
        ) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle gate (idempotent no-op on repeat).
    IF v_status <> 'active' THEN
        SELECT to_jsonb(m) INTO v_row
        FROM public.minigame_game_state m
        WHERE m.session_id = p_session_id;
        IF v_row IS NULL THEN
            RETURN jsonb_build_object('status', 'already_finished');
        END IF;
        RETURN jsonb_build_object('status', 'finished', 'state', v_row);
    END IF;

    v_player_count := COALESCE(array_length(v_participants, 1), 0);
    -- 300_slim: wagers retired — there is no pot to pay.
    v_pot := 0;
    v_prize_positions := LEAST(COALESCE(v_prize_positions, 3), v_player_count);

    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    v_play_mode := COALESCE(v_state ->> 'play_mode', 'by_turns');

    -- 5. Scoreboard source of truth: by_turns = rounds history (fractional
    --    scores allowed since 204); async = per-round emoji_count -
    --    pass_count/2 summed across the player's rounds, -1 per passed round.
    IF v_play_mode = 'async' THEN
        SELECT jsonb_agg(ranked ORDER BY (ranked ->> 'rank')::int)
        INTO v_prize_rows
        FROM (
            SELECT jsonb_build_object(
                       'participant_id', sc.participant_id,
                       'score', sc.score,
                       'rank', sc.rank
                   ) AS ranked
            FROM (
                SELECT s.participant_id,
                       CASE WHEN COALESCE(SUM(CASE
                           WHEN (a.passed) THEN -1
                           ELSE (SELECT count(*) FROM public.minigame_reactions r
                                 WHERE r.session_id = p_session_id
                                   AND r.round = a.round
                                   AND r.reaction IS NOT NULL)
                                  - (SELECT count(*) FROM public.minigame_reactions r
                                     WHERE r.session_id = p_session_id
                                       AND r.round = a.round
                                       AND r.reaction IS NULL)::numeric / 2
                       END), 0) = trunc(COALESCE(SUM(CASE
                           WHEN (a.passed) THEN -1
                           ELSE (SELECT count(*) FROM public.minigame_reactions r
                                 WHERE r.session_id = p_session_id
                                   AND r.round = a.round
                                   AND r.reaction IS NOT NULL)
                                  - (SELECT count(*) FROM public.minigame_reactions r
                                     WHERE r.session_id = p_session_id
                                       AND r.round = a.round
                                       AND r.reaction IS NULL)::numeric / 2
                       END), 0))
                            THEN COALESCE(SUM(CASE
                           WHEN (a.passed) THEN -1
                           ELSE (SELECT count(*) FROM public.minigame_reactions r
                                 WHERE r.session_id = p_session_id
                                   AND r.round = a.round
                                   AND r.reaction IS NOT NULL)
                                  - (SELECT count(*) FROM public.minigame_reactions r
                                     WHERE r.session_id = p_session_id
                                       AND r.round = a.round
                                       AND r.reaction IS NULL)::numeric / 2
                       END), 0)::bigint
                            ELSE round(COALESCE(SUM(CASE
                           WHEN (a.passed) THEN -1
                           ELSE (SELECT count(*) FROM public.minigame_reactions r
                                 WHERE r.session_id = p_session_id
                                   AND r.round = a.round
                                   AND r.reaction IS NOT NULL)
                                  - (SELECT count(*) FROM public.minigame_reactions r
                                     WHERE r.session_id = p_session_id
                                       AND r.round = a.round
                                       AND r.reaction IS NULL)::numeric / 2
                       END), 0), 1) END AS score,
                       row_number() OVER (
                           ORDER BY COALESCE(SUM(CASE
                               WHEN (a.passed) THEN -1
                               ELSE (SELECT count(*) FROM public.minigame_reactions r
                                     WHERE r.session_id = p_session_id
                                       AND r.round = a.round
                                       AND r.reaction IS NOT NULL)
                                      - (SELECT count(*) FROM public.minigame_reactions r
                                         WHERE r.session_id = p_session_id
                                           AND r.round = a.round
                                           AND r.reaction IS NULL)::numeric / 2
                               END), 0) DESC, s.ord
                       ) AS rank
                FROM unnest(v_participants) WITH ORDINALITY AS s(participant_id, ord)
                LEFT JOIN LATERAL (
                    SELECT a.passed, a.round
                    FROM public.minigame_answers a
                    WHERE a.session_id = p_session_id
                      AND a.subject_id = s.participant_id
                ) a ON true
                GROUP BY s.participant_id, s.ord
            ) sc
        ) ranked_rows;
    ELSE
        SELECT rounds INTO v_rounds
        FROM public.minigame_game_state
        WHERE session_id = p_session_id;
        IF v_rounds IS NULL THEN
            v_rounds := '{}'::jsonb[];
        END IF;

        SELECT jsonb_agg(ranked ORDER BY (ranked ->> 'rank')::int)
        INTO v_prize_rows
        FROM (
            SELECT jsonb_build_object(
                       'participant_id', sc.participant_id,
                       'score', sc.score,
                       'rank', sc.rank
                   ) AS ranked
            FROM (
                SELECT s.participant_id,
                       CASE WHEN COALESCE(sum(r.value), 0) = trunc(COALESCE(sum(r.value), 0))
                            THEN COALESCE(sum(r.value), 0)::bigint
                            ELSE round(COALESCE(sum(r.value), 0), 1) END AS score,
                       row_number() OVER (
                           ORDER BY COALESCE(sum(r.value), 0) DESC, s.ord
                       ) AS rank
                FROM unnest(v_participants) WITH ORDINALITY AS s(participant_id, ord)
                LEFT JOIN LATERAL (
                    SELECT (rr ->> 'score')::numeric AS value
                    FROM unnest(v_rounds) rr
                    WHERE (rr ->> 'subject_id')::uuid = s.participant_id
                ) r ON true
                GROUP BY s.participant_id, s.ord
            ) sc
        ) ranked_rows;
    END IF;

    IF v_prize_rows IS NULL THEN
        v_prize_rows := '[]'::jsonb;
    END IF;

    -- 6. HARMONIC prize weights (kept for the result shape; the pot is 0, so
    --    every prize resolves to 0).
    v_lcm := 1;
    FOR v_r IN 1..v_prize_positions LOOP
        v_lcm := v_lcm / gcd(v_lcm, v_r) * v_r;
    END LOOP;

    v_weights := jsonb_agg(wt) FROM (
        SELECT jsonb_build_object('rank', g.r, 'weight', v_lcm / g.r) AS wt
        FROM generate_series(1, v_prize_positions) AS g(r)
    ) q;
    v_denom := (SELECT sum((wt ->> 'weight')::int) FROM jsonb_array_elements(v_weights) wt);

    v_base := (
        SELECT jsonb_agg(jsonb_build_object(
                   'rank', r.rank,
                   'prize', 0
               ) ORDER BY r.rank)
        FROM (
            SELECT (v ->> 'rank')::int AS rank
            FROM jsonb_array_elements(v_prize_rows) v
        ) r
        JOIN jsonb_array_elements(v_weights) w ON (w ->> 'rank')::int = r.rank
    );

    -- 7. Write the settle-once leaderboard (prize = 0, no escrow payout).
    INSERT INTO public.minigame_results (session_id, results)
    SELECT p_session_id, jsonb_agg(jsonb_build_object(
               'participant_id', v ->> 'participant_id',
               'score', (v ->> 'score')::numeric,
               'rank', (v ->> 'rank')::int,
               'prize', 0
           ) ORDER BY (v ->> 'rank')::int)
    FROM jsonb_array_elements(v_prize_rows) v;

    -- 8. Flip the game phase + session status to finished.
    UPDATE public.minigame_game_state
    SET state = state || jsonb_build_object('phase', 'finished')
    WHERE session_id = p_session_id;

    UPDATE public.minigame_sessions
    SET status = 'finished'
    WHERE id = p_session_id;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'finished', 'state', v_row);
END;
$$;

-- Settlement stays server-only (229 SEC-004): authenticated cannot call it.
REVOKE ALL ON FUNCTION public.finish_minigame_game(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finish_minigame_game(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Guard-drop the already-retired settlement seams so a stale body can
--    never resurrect escrow (201 dropped them; idempotent here).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.finish_minigame_session(uuid, uuid, integer);
DROP FUNCTION IF EXISTS public.complete_minigame_game(uuid);

-- ---------------------------------------------------------------------------
-- 9. Retire (do not drop) the shard_wager column.
-- ---------------------------------------------------------------------------
COMMENT ON COLUMN public.minigame_sessions.shard_wager IS
    'RETIRED (300_slim): always 0. The gambling escrow economy was removed; the column stays for client/notification compatibility and is the re-add seam.';

COMMIT;
