-- Samay — 202_minigame_play_v2/play_v2.sql
-- Minigame play engine v2: answer-first, by-turns/async modes, anonymous
-- play, E2EE answers (2026-08-30).
--
-- Product contract (user directives 2026-08-30):
--   * ANSWER-FIRST: the current-turn subject MUST submit an answer before the
--     others can react. Truth = text input; Reto = image + text. The subject
--     can never react to their own round.
--   * PASAR (skip): available for truth AND reto. Passing blocks all
--     reactions on that round and the subject auto-scores -1.
--   * MODES (settable at match creation): `by_turns` (existing total-rounds;
--     answer -> ALL others react/pass -> next turn) and `async` (per-player
--     rounds, default 1; each player completes their own rounds any time; a
--     list of completed rounds is available for others to react to). Async
--     ends on a SETTABLE timer (default 1 day, no override after creation).
--   * ANONYMOUS (settable at creation): no usernames during play — players
--     get an editable temporary nickname (default localized `anonimoXXX`,
--     random-unique) chosen on accept, updatable anytime (realtime). Real
--     usernames appear ONLY in the leaderboard / match summary.
--   * E2EE: truth/dare answers (text + image) are encrypted so ONLY
--     participants can read them — the server never sees plaintext. The
--     answer ciphertexts are stored in `minigame_answers`; the group
--     sender-key distribution bundles ride `minigame_e2ee_bundles` as
--     pairwise-encrypted envelopes.
--
-- Model:
--   * minigame_sessions + play_mode (by_turns|async), + anonymous bool,
--     + async_rounds_per_player (default 1), + async_ends_at (settable at
--     creation; NULL for by_turns).
--   * minigame_aliases — (session, participant) -> temp nickname. FORCE RLS,
--     read by participants (realtime), written ONLY through
--     set_minigame_alias.
--   * minigame_answers — the E2EE answer store: one row per (session, round),
--     ciphertext-only (text + optional image), `passed` flag, subject_id +
--     prompt_type + prompt_id. FORCE RLS, readable by participants, written
--     ONLY through submit_minigame_answer / submit_minigame_pasar /
--     submit_minigame_async_answer.
--   * minigame_e2ee_bundles — sender-key distribution delivery rows
--     (pairwise-encrypted bundle envelopes per recipient). FORCE RLS: the
--     sender writes (own rows), the recipient reads (recipient_id = me).
--   * submit_minigame_answer(session, answer_ciphertext, image_storage_path) —
--     the by_turns subject submits their encrypted answer for the CURRENT
--     round. Gates: caller IS state.subject_id, round not answered/passed.
--     Mirrors into state.answer (ciphertext only) so it streams realtime.
--   * submit_minigame_pasar(session) — subject passes: records passed=true,
--     blocks all reactions, auto-advances immediately with score -1.
--   * submit_minigame_reaction (CREATE OR REPLACE) — adds the answer gate
--     (reactions open only after the subject answered) and the subject
--     exclusion; after the LAST required voter reacts (or the subject
--     passed) the round AUTO-ADVANCES (by_turns).
--   * react_minigame_round(session, round, reaction) — reaction targeting an
--     arbitrary completed round (async reactable-rounds list; also the
--     by_turns path). Caller cannot be the round's subject; a passed round
--     rejects reactions.
--   * submit_minigame_async_answer(session, prompt_type, answer_ciphertext,
--     image_storage_path) — async: draws a server-random prompt, records the
--     caller's round (round_map[uid]++), mirrors into state.answers.
--   * _minigame_advance_round(session) — shared server-side turn close:
--     scores the round (reaction count, -1 for passed/zero), appends the
--     round record, rotates judge/subject, resets reactions, auto-finishes at
--     round_target.
--   * advance_minigame_turn (CREATE OR REPLACE) — by_turns: advances only
--     when ALL non-subject participants have reacted/passed, or the CREATOR
--     forces it ('waiting_reactions' otherwise).
--   * async auto-finish: the pg_cron `minigames-async-finish` job settles any
--     async session past async_ends_at; get_minigame_game_state also performs
--     the lazy flip on read. finish_minigame_game recomputes async scores
--     from minigame_reactions (total reactions received across the player's
--     rounds, -1 per passed round).
--
-- Posture mirrors 100/140/150/180/190/201: FORCE RLS, mutations through
-- SECURITY DEFINER RPCs only, PUBLIC EXECUTE revoked, authenticated +
-- service_role.

-- ======================================================================
-- 1. minigame_sessions: play mode + anonymous + async configuration
-- ======================================================================
ALTER TABLE public.minigame_sessions
    ADD COLUMN play_mode text NOT NULL DEFAULT 'by_turns'
        CHECK (play_mode IN ('by_turns', 'async'));

ALTER TABLE public.minigame_sessions
    ADD COLUMN anonymous boolean NOT NULL DEFAULT false;

ALTER TABLE public.minigame_sessions
    ADD COLUMN async_rounds_per_player integer NOT NULL DEFAULT 1;

ALTER TABLE public.minigame_sessions
    ADD COLUMN async_ends_at timestamp with time zone;

COMMENT ON COLUMN public.minigame_sessions.play_mode IS
    '202_minigame_play_v2: by_turns (answer -> all react -> next turn, total round_target) or async (per-player rounds, timer deadline).';
COMMENT ON COLUMN public.minigame_sessions.anonymous IS
    '202_minigame_play_v2: hide usernames during play; participants use temp nicknames until the leaderboard reveals real names.';
COMMENT ON COLUMN public.minigame_sessions.async_rounds_per_player IS
    '202_minigame_play_v2: per-player round target in async mode (default 1).';
COMMENT ON COLUMN public.minigame_sessions.async_ends_at IS
    '202_minigame_play_v2: async mode hard deadline (settable at creation, no override); the game auto-finishes when it passes. NULL for by_turns.';

-- ======================================================================
-- 2. minigame_aliases — temporary nicknames (anonymous mode)
-- ======================================================================
CREATE TABLE public.minigame_aliases (
    session_id uuid NOT NULL,
    participant_id uuid NOT NULL,
    alias text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT minigame_aliases_pkey PRIMARY KEY (session_id, participant_id),
    CONSTRAINT minigame_aliases_session_id_fkey FOREIGN KEY (session_id)
        REFERENCES public.minigame_sessions(id) ON DELETE CASCADE
);

ALTER TABLE public.minigame_aliases ENABLE ROW LEVEL SECURITY;
ALTER TABLE ONLY public.minigame_aliases FORCE ROW LEVEL SECURITY;

CREATE INDEX minigame_aliases_session_idx
    ON public.minigame_aliases (session_id);

-- Readable by participants / invitees / group members (semantic mirror of
-- mgs_read_participant) so nicknames stream realtime.
CREATE POLICY mgs_aliases_read ON public.minigame_aliases FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM public.minigame_sessions s
        WHERE s.id = session_id
          AND (
                (s.group_id IS NULL AND auth.uid() = ANY (s.participants))
             OR EXISTS (
                    SELECT 1 FROM public.minigame_invites mi
                    WHERE mi.session_id = s.id AND mi.invitee_id = auth.uid()
                )
             OR EXISTS (
                    SELECT 1 FROM public.group_members gm
                    WHERE gm.group_id = s.group_id AND gm.user_id = auth.uid()
                      AND gm.status = 'active'
                      AND NOT EXISTS (
                            SELECT 1 FROM public.users u
                            WHERE u.id = gm.user_id AND u.deleted_at IS NOT NULL
                        )
                )
          )
    )
);

-- ======================================================================
-- 3. minigame_answers — E2EE answer store (ciphertext only)
-- ======================================================================
CREATE TABLE public.minigame_answers (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    session_id uuid NOT NULL,
    round integer NOT NULL,
    subject_id uuid NOT NULL,
    prompt_type text,
    prompt_id uuid,
    answer_ciphertext text,
    image_storage_path text,
    passed boolean NOT NULL DEFAULT false,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT minigame_answers_pkey PRIMARY KEY (id),
    CONSTRAINT minigame_answers_session_round_uniq UNIQUE (session_id, round),
    CONSTRAINT minigame_answers_session_id_fkey FOREIGN KEY (session_id)
        REFERENCES public.minigame_sessions(id) ON DELETE CASCADE
);

ALTER TABLE public.minigame_answers ENABLE ROW LEVEL SECURITY;
ALTER TABLE ONLY public.minigame_answers FORCE ROW LEVEL SECURITY;

CREATE INDEX minigame_answers_session_round_idx
    ON public.minigame_answers (session_id, round);

COMMENT ON COLUMN public.minigame_answers.image_storage_path IS
    '202_minigame_play_v2 + 2026-08-31: the PRIVATE storage bucket object path of the ENCRYPTED image bytes (minigame_images/<session>/<round>/<uuid>.bin); NULL when the answer has no image. The server never sees plaintext or keys.';

-- The answers are ciphertext-only and readable exactly when the session row
-- is (participant / invitee / group member) — the decryption keys never
-- leave the clients.
CREATE POLICY mgs_answers_read ON public.minigame_answers FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM public.minigame_sessions s
        WHERE s.id = session_id
          AND (
                (s.group_id IS NULL AND auth.uid() = ANY (s.participants))
             OR EXISTS (
                    SELECT 1 FROM public.minigame_invites mi
                    WHERE mi.session_id = s.id AND mi.invitee_id = auth.uid()
                )
             OR EXISTS (
                    SELECT 1 FROM public.group_members gm
                    WHERE gm.group_id = s.group_id AND gm.user_id = auth.uid()
                      AND gm.status = 'active'
                      AND NOT EXISTS (
                            SELECT 1 FROM public.users u
                            WHERE u.id = gm.user_id AND u.deleted_at IS NOT NULL
                        )
                )
          )
    )
);

-- ======================================================================
-- 4. minigame_e2ee_bundles — sender-key distribution delivery rows
-- ======================================================================
CREATE TABLE public.minigame_e2ee_bundles (
    session_id uuid NOT NULL,
    sender_id uuid NOT NULL,
    recipient_id uuid NOT NULL,
    bundle_ciphertext text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT minigame_e2ee_bundles_pkey PRIMARY KEY (session_id, sender_id, recipient_id),
    CONSTRAINT minigame_e2ee_bundles_session_id_fkey FOREIGN KEY (session_id)
        REFERENCES public.minigame_sessions(id) ON DELETE CASCADE
);

ALTER TABLE public.minigame_e2ee_bundles ENABLE ROW LEVEL SECURITY;
ALTER TABLE ONLY public.minigame_e2ee_bundles FORCE ROW LEVEL SECURITY;

-- The sender writes their own distribution rows (the bundle ciphertext is a
-- pairwise-encrypted envelope addressed to the recipient). Participant-only:
-- the sender must be IN the session's participants AND the recipient must
-- also be a participant (security hardening 2026-08-31 — invitees / group
-- members / bystanders never distribute keys).
CREATE POLICY mgs_bundles_insert_own ON public.minigame_e2ee_bundles
    FOR INSERT TO authenticated WITH CHECK (
        sender_id = auth.uid()
        AND EXISTS (
            SELECT 1 FROM public.minigame_sessions s
            WHERE s.id = session_id
              AND auth.uid() = ANY (s.participants)
              AND recipient_id = ANY (s.participants)
        )
    );

-- A recipient reads only bundles addressed to them.
CREATE POLICY mgs_bundles_read_recipient ON public.minigame_e2ee_bundles
    FOR SELECT TO authenticated USING (recipient_id = auth.uid());

-- ======================================================================
-- 4b. init_minigame_game_state(uuid) — CREATE OR REPLACE (190 sig).
-- 202: the countdown skeleton must PRESERVE the play-engine mode fields that
-- create_minigame_session seeded into the payload (play_mode, anonymous,
-- async_ends_at, async_rounds_per_player, round_map, answers) — the 190
-- version rebuilt v_state from scratch and wiped them, breaking async mode
-- (submit_minigame_async_answer read a missing play_mode → wrong_mode).
-- ======================================================================
CREATE OR REPLACE FUNCTION public.init_minigame_game_state(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_count integer;
    v_game_type public.mini_game_type;
    v_random_index integer;
    v_next_index integer;
    v_state jsonb;
    v_seeded jsonb;
    v_row jsonb;
    v_existing jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock.
    SELECT group_id, status, participants, game_type
        INTO v_group_id, v_status, v_participants, v_game_type
        FROM public.minigame_sessions
        WHERE id = p_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate (participant / invitee / group member).
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

    -- 3b. Creator-only Start gate (backend-enforced).
    IF array_length(v_participants, 1) IS NULL
       OR v_participants[1] <> auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_creator');
    END IF;

    -- 4. Lifecycle gate.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. Idempotency: an existing row in countdown OR playing is a no-op.
    SELECT to_jsonb(m) INTO v_existing
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_existing IS NOT NULL
       AND v_existing -> 'state' ->> 'phase' IN ('countdown', 'playing') THEN
        RETURN jsonb_build_object('status', 'already_started', 'state', v_existing);
    END IF;

    -- 6. Random first subject + random NEXT subject (server-random).
    v_count := COALESCE(array_length(v_participants, 1), 0);
    IF v_count = 0 THEN
        RETURN jsonb_build_object('status', 'no_participants');
    END IF;
    v_random_index := 1 + floor(random() * v_count)::integer;
    IF v_count = 1 THEN
        v_next_index := v_random_index;
    ELSE
        v_next_index := 1 + floor(random() * (v_count - 1))::integer;
        IF v_next_index >= v_random_index THEN
            v_next_index := v_next_index + 1;
        END IF;
    END IF;

    -- 6b. 202: carry over the mode fields the create seeded into the payload
    --     (they must survive the countdown skeleton rebuild).
    SELECT m.state INTO v_seeded
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    v_state := jsonb_build_object(
        'judge_index', 0,
        'round', 0,
        'phase', 'countdown',
        'countdown_ends_at', now() + interval '5 seconds',
        'subject_id', v_participants[v_random_index],
        'next_subject_id', v_participants[v_next_index],
        'prompt_type', NULL,
        'prompt', NULL
    );
    IF v_seeded IS NOT NULL THEN
        v_state := v_state
            || jsonb_build_object(
                   'play_mode', COALESCE(v_seeded ->> 'play_mode', 'by_turns'),
                   'anonymous', COALESCE((v_seeded ->> 'anonymous')::boolean, false),
                   'async_ends_at', v_seeded -> 'async_ends_at',
                   'async_rounds_per_player', COALESCE((v_seeded ->> 'async_rounds_per_player')::integer, 1),
                   'round_map', COALESCE(v_seeded -> 'round_map', '{}'::jsonb),
                   'answers', COALESCE(v_seeded -> 'answers', '[]'::jsonb),
                   'round_target', v_seeded -> 'round_target',
                   'prize_positions', v_seeded -> 'prize_positions'
               );
    END IF;

    -- 7. Upsert the row (fresh INSERT or lobby-seeded UPDATE).
    INSERT INTO public.minigame_game_state (session_id, game_type, state, ready)
    VALUES (p_session_id, v_game_type, v_state, '{}'::jsonb)
    ON CONFLICT (session_id) DO UPDATE
        SET state = v_state,
            game_type = v_game_type,
            ready = '{}'::jsonb;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'started', 'state', v_row);
END;
$$;

-- ======================================================================
-- 5. create_minigame_session — 11-arg (DROP the 7-arg 201 variant; CREATE OR
--    REPLACE cannot change the argument list). Validates the new options,
--    freezes them on the session row and seeds the game-state payload.
-- ======================================================================
DROP FUNCTION IF EXISTS public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text, p_rounds integer, p_prize_positions integer);

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

    -- 6. Player-cap gate.
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
            VALUES (v_session_id, v_invitee, v_current_user);
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'status', 'created',
        'sessionId', v_session_id,
        'invited', COALESCE(array_length(v_clean_invitees, 1), 0)
    );
END;
$$;

-- ======================================================================
-- 6. set_minigame_alias(uuid, text)
-- Anonymous-mode temp nickname upsert. Participant-only; validates the alias
-- shape (1..30 trimmed chars); streams realtime via the minigame_aliases
-- publication.
-- ======================================================================
CREATE FUNCTION public.set_minigame_alias(p_session_id uuid, p_alias text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_alias text;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup.
    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Participant-only gate (security hardening 2026-08-31 — invitees
    --    / inactive group members can render the lobby but never set the
    --    session's temp nicknames).
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle: aliases live while the session is active.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. Alias shape validation (1..30 trimmed, no control chars).
    v_alias := NULLIF(btrim(p_alias), '');
    IF v_alias IS NULL OR char_length(v_alias) > 30
       OR v_alias ~ '[\x00-\x1f\x7f]' THEN
        RETURN jsonb_build_object('status', 'invalid_alias');
    END IF;

    -- 6. Upsert (one nickname per participant per session).
    INSERT INTO public.minigame_aliases (session_id, participant_id, alias)
    VALUES (p_session_id, auth.uid(), v_alias)
    ON CONFLICT (session_id, participant_id) DO UPDATE
        SET alias = EXCLUDED.alias, updated_at = now();

    RETURN jsonb_build_object('status', 'alias_set', 'alias', v_alias);
END;
$$;

-- ======================================================================
-- 7. _minigame_advance_round(uuid) — shared turn close (by_turns)
-- Scores the completed round (reaction count, -1 for passed/zero reactions),
-- appends the round record, rotates judge/subject, resets reactions and
-- AUTO-FINISHES at round_target. Callers (advance_minigame_turn /
-- submit_minigame_reaction / submit_minigame_pasar) perform the access +
-- lifecycle gates first.
-- ======================================================================
CREATE FUNCTION public._minigame_advance_round(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_status public.mini_game_status;
    v_participants uuid[];
    v_state jsonb;
    v_phase text;
    v_judge_index integer;
    v_round integer;
    v_player_count integer;
    v_next_judge integer;
    v_random_index integer;
    v_next_index integer;
    v_round_target integer;
    v_subject_id uuid;
    v_reaction_count integer;
    v_score integer;
    v_passed boolean;
    v_round_json jsonb;
    v_row jsonb;
BEGIN
    SELECT status, participants INTO v_status, v_participants
    FROM public.minigame_sessions
    WHERE id = p_session_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_state IS NULL THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    v_phase := v_state ->> 'phase';
    IF v_phase <> 'playing' THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    v_player_count := COALESCE(array_length(v_participants, 1), 0);
    IF v_player_count = 0 THEN
        RETURN jsonb_build_object('status', 'no_participants');
    END IF;

    v_judge_index := COALESCE((v_state ->> 'judge_index')::integer, 0);
    v_round := COALESCE((v_state ->> 'round')::integer, 0);
    v_subject_id := (v_state ->> 'subject_id')::uuid;
    v_round_target := COALESCE((v_state ->> 'round_target')::integer, NULL);

    -- Score: reaction count, or -1 for a passed round / zero reactions.
    SELECT passed INTO v_passed
    FROM public.minigame_answers
    WHERE session_id = p_session_id AND round = v_round;
    v_passed := COALESCE(v_passed, false);

    SELECT count(*) INTO v_reaction_count
    FROM public.minigame_reactions
    WHERE session_id = p_session_id AND round = v_round;
    v_score := CASE WHEN v_passed OR v_reaction_count = 0
                    THEN -1 ELSE v_reaction_count END;

    v_round_json := jsonb_build_object(
        'subject_id', v_subject_id,
        'round', v_round,
        'score', v_score,
        'outcome', CASE WHEN v_passed THEN 'skip' ELSE 'done' END
    ) || CASE WHEN (v_state ->> 'prompt_type') IS NOT NULL
              THEN jsonb_build_object('prompt_type', v_state ->> 'prompt_type')
              ELSE '{}'::jsonb END;

    -- Rotate judge + redraw random subject + following subject.
    v_next_judge := (v_judge_index + 1) % v_player_count;
    v_random_index := 1 + floor(random() * v_player_count)::integer;
    IF v_player_count = 1 THEN
        v_next_index := v_random_index;
    ELSE
        v_next_index := 1 + floor(random() * (v_player_count - 1))::integer;
        IF v_next_index >= v_random_index THEN
            v_next_index := v_next_index + 1;
        END IF;
    END IF;

    UPDATE public.minigame_game_state
    SET rounds = rounds || ARRAY[v_round_json],
        state = v_state
                - 'subject_id' - 'next_subject_id' - 'prompt_type' - 'prompt'
                - 'reactions' - 'answer'
                || jsonb_build_object(
                       'judge_index', v_next_judge,
                       'round', v_round + 1,
                       'phase', 'playing',
                       'subject_id', v_participants[v_random_index],
                       'next_subject_id', v_participants[v_next_index],
                       'reactions', '{}'::jsonb
                   )
    WHERE session_id = p_session_id;

    -- Auto-finish at the total-turn target (201).
    IF v_round_target IS NOT NULL AND v_round + 1 >= v_round_target THEN
        RETURN public.finish_minigame_game(p_session_id);
    END IF;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'advanced', 'state', v_row);
END;
$$;

-- ======================================================================
-- 8. submit_minigame_answer(uuid, text, text) — by_turns subject answer
-- The current-turn subject submits their E2EE answer (text ciphertext +
-- optional image_storage_path to the private bucket object). Gates: caller IS
-- state.subject_id; the round must not be answered/passed. Mirrors into
-- state.answer (ciphertext + path only).
-- ======================================================================
CREATE FUNCTION public.submit_minigame_answer(p_session_id uuid, p_answer_ciphertext text, p_image_storage_path text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_state jsonb;
    v_phase text;
    v_round integer;
    v_subject_id uuid;
    v_prompt_type text;
    v_prompt_id uuid;
    v_already boolean;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + lock.
    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate — participant-only on the WRITE path (security
    --    hardening 2026-08-31: invitees / inactive group members can render
    --    the lobby but never answer).
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle + by_turns-only + playing gate.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_state IS NULL OR v_state ->> 'phase' <> 'playing' THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;
    IF COALESCE(v_state ->> 'play_mode', 'by_turns') <> 'by_turns' THEN
        RETURN jsonb_build_object('status', 'wrong_mode');
    END IF;

    -- 5. The SUBJECT only submits their own round's answer.
    v_round := COALESCE((v_state ->> 'round')::integer, 0);
    v_subject_id := (v_state ->> 'subject_id')::uuid;
    IF v_subject_id IS NULL OR v_subject_id <> auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_subject');
    END IF;

    -- 6. The round must not already be answered/passed.
    SELECT EXISTS (
        SELECT 1 FROM public.minigame_answers
        WHERE session_id = p_session_id AND round = v_round
    ) INTO v_already;
    IF v_already THEN
        RETURN jsonb_build_object('status', 'already_answered');
    END IF;

    -- 7. The prompt must be revealed for this round.
    v_prompt_type := v_state ->> 'prompt_type';
    IF v_prompt_type IS NULL OR v_state -> 'prompt' IS NULL THEN
        RETURN jsonb_build_object('status', 'no_prompt');
    END IF;
    v_prompt_id := (v_state -> 'prompt' ->> 'id')::uuid;

    -- 8. Persist the E2EE answer (ciphertext only — the server never sees
    --    plaintext).
    INSERT INTO public.minigame_answers
        (session_id, round, subject_id, prompt_type, prompt_id,
         answer_ciphertext, image_storage_path, passed)
    VALUES
        (p_session_id, v_round, v_subject_id, v_prompt_type, v_prompt_id,
         p_answer_ciphertext, p_image_storage_path, false);

    -- 9. Mirror into the state payload (realtime): the answer ciphertext
    --    streams to every participant on the existing channel.
    UPDATE public.minigame_game_state
    SET state = jsonb_set(
            state,
            '{answer}',
            jsonb_build_object(
                'subject_id', v_subject_id,
                'round', v_round,
                'prompt_type', v_prompt_type,
                'answer_ciphertext', p_answer_ciphertext,
                'image_storage_path', p_image_storage_path,
                'passed', false
            ),
            true
        )
    WHERE session_id = p_session_id;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'submitted', 'state', v_row);
END;
$$;

-- ======================================================================
-- 9. submit_minigame_pasar(uuid) — subject passes
-- Passing blocks ALL reactions on the round and auto-advances immediately
-- with score -1 (the 202 product contract).
-- ======================================================================
CREATE FUNCTION public.submit_minigame_pasar(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_state jsonb;
    v_round integer;
    v_subject_id uuid;
    v_prompt_type text;
    v_prompt_id uuid;
    v_already boolean;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + lock.
    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate — participant-only on the WRITE path (security
    --    hardening 2026-08-31: invitees / inactive group members can render
    --    the lobby but never pass).
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle + by_turns-only + playing gate.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_state IS NULL OR v_state ->> 'phase' <> 'playing' THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;
    IF COALESCE(v_state ->> 'play_mode', 'by_turns') <> 'by_turns' THEN
        RETURN jsonb_build_object('status', 'wrong_mode');
    END IF;

    -- 5. The SUBJECT only passes their own round.
    v_round := COALESCE((v_state ->> 'round')::integer, 0);
    v_subject_id := (v_state ->> 'subject_id')::uuid;
    IF v_subject_id IS NULL OR v_subject_id <> auth.uid() THEN
        RETURN jsonb_build_object('status', 'not_subject');
    END IF;

    -- 6. Not already answered/passed.
    SELECT EXISTS (
        SELECT 1 FROM public.minigame_answers
        WHERE session_id = p_session_id AND round = v_round
    ) INTO v_already;
    IF v_already THEN
        RETURN jsonb_build_object('status', 'already_answered');
    END IF;

    -- 7. Persist the passed round (no ciphertext).
    v_prompt_type := v_state ->> 'prompt_type';
    v_prompt_id := (v_state -> 'prompt' ->> 'id')::uuid;
    INSERT INTO public.minigame_answers
        (session_id, round, subject_id, prompt_type, prompt_id,
         answer_ciphertext, image_storage_path, passed)
    VALUES
        (p_session_id, v_round, v_subject_id, v_prompt_type, v_prompt_id,
         NULL, NULL, true);

    -- 8. Passing BLOCKS reactions: immediately close the round with score -1
    --    (the advance clears state.answer + reactions for the next turn).
    RETURN public._minigame_advance_round(p_session_id);
END;
$$;

-- ======================================================================
-- 10. submit_minigame_reaction(uuid, text) — CREATE OR REPLACE (201 sig)
-- 202 gates: reactions open ONLY after the subject answered (not passed);
-- the SUBJECT can never react to their own round. When the LAST required
-- voter reacts the round AUTO-ADVANCES (by_turns "all have reacted/passed").
-- ======================================================================
CREATE OR REPLACE FUNCTION public.submit_minigame_reaction(p_session_id uuid, p_reaction text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_state jsonb;
    v_phase text;
    v_round integer;
    v_subject_id uuid;
    v_answer jsonb;
    v_reacted_count integer;
    v_required_count integer;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock.
    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate — participant-only on the WRITE path (security
    --    hardening 2026-08-31: invitees / inactive group members can render
    --    the lobby but never vote).
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle + playing gate.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_state IS NULL OR v_state ->> 'phase' <> 'playing' THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    -- 5. Current round + subject (server-authoritative).
    v_round := COALESCE((v_state ->> 'round')::integer, 0);
    v_subject_id := (v_state ->> 'subject_id')::uuid;
    IF v_subject_id IS NULL THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    -- 5b. The SUBJECT can never react to their own round (202 contract).
    IF v_subject_id = auth.uid() THEN
        RETURN jsonb_build_object('status', 'own_round');
    END IF;

    -- 5c. Reactions open ONLY after the subject answered (202 answer-first).
    SELECT to_jsonb(a) INTO v_answer
    FROM public.minigame_answers a
    WHERE a.session_id = p_session_id AND a.round = v_round;
    IF v_answer IS NULL OR v_answer ->> 'passed' = 'true' THEN
        RETURN jsonb_build_object('status', 'answer_pending');
    END IF;

    -- 6. Reaction validation.
    IF p_reaction NOT IN ('disgust', 'sad', 'surprised', 'excited', 'demon', 'heart') THEN
        RETURN jsonb_build_object('status', 'invalid_reaction');
    END IF;

    -- 7. Persist the vote (idempotent upsert).
    INSERT INTO public.minigame_reactions (session_id, round, voter_id, reaction)
    VALUES (p_session_id, v_round, auth.uid(), p_reaction)
    ON CONFLICT (session_id, round, voter_id) DO UPDATE
        SET reaction = EXCLUDED.reaction;

    -- 8. Mirror into the state payload (realtime). The mirror carries the
    --    ordered vote list AND the distinct-voter count ({subject_id:
    --    {"list": [emoji...], "count": N}}) so clients render the live
    --    tally without re-querying (security hardening 2026-08-31 — the
    --    count is distinct voters, never rows).
    UPDATE public.minigame_game_state
    SET state = jsonb_set(
            state,
            '{reactions}',
            COALESCE((
                SELECT jsonb_build_object(
                    v_subject_id::text,
                    jsonb_build_object(
                        'list',
                        (SELECT COALESCE(jsonb_agg(r.reaction ORDER BY r.created_at), '[]'::jsonb)
                         FROM public.minigame_reactions r
                         WHERE r.session_id = p_session_id AND r.round = v_round),
                        'count',
                        (SELECT count(distinct r.voter_id)
                         FROM public.minigame_reactions r
                         WHERE r.session_id = p_session_id AND r.round = v_round)
                    )
                )
            ), '{}'::jsonb),
            true
        )
    WHERE session_id = p_session_id;

    -- 9. by_turns auto-advance: when every NON-subject participant has
    --    reacted, the round closes and the next turn begins (the "all have
    --    reacted" contract). Idempotent — already-advanced rounds reject.
    IF COALESCE(v_state ->> 'play_mode', 'by_turns') = 'by_turns' THEN
        SELECT count(distinct voter_id) INTO v_reacted_count
        FROM public.minigame_reactions
        WHERE session_id = p_session_id AND round = v_round;
        v_required_count := COALESCE(array_length(v_participants, 1), 1) - 1;
        IF v_reacted_count >= v_required_count THEN
            RETURN public._minigame_advance_round(p_session_id);
        END IF;
    END IF;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'submitted', 'state', v_row);
END;
$$;

-- ======================================================================
-- 11. react_minigame_round(uuid, integer, text)
-- Reaction targeting an arbitrary COMPLETED round — the async "reactable
-- rounds" list (and the by_turns path). Caller cannot be the round's
-- subject; a passed round rejects reactions.
-- ======================================================================
CREATE FUNCTION public.react_minigame_round(p_session_id uuid, p_round integer, p_reaction text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_answer jsonb;
    v_subject_id uuid;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + lock.
    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate — participant-only on the WRITE path (security
    --    hardening 2026-08-31: invitees / inactive group members can render
    --    the lobby but never vote).
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. The target round must have a completed (non-passed) answer.
    SELECT to_jsonb(a) INTO v_answer
    FROM public.minigame_answers a
    WHERE a.session_id = p_session_id AND a.round = p_round;
    IF v_answer IS NULL OR v_answer ->> 'passed' = 'true' THEN
        RETURN jsonb_build_object('status', 'answer_pending');
    END IF;
    v_subject_id := (v_answer ->> 'subject_id')::uuid;

    -- 5b. The subject of the round can never react to it (202 contract).
    IF v_subject_id = auth.uid() THEN
        RETURN jsonb_build_object('status', 'own_round');
    END IF;

    -- 6. Reaction validation.
    IF p_reaction NOT IN ('disgust', 'sad', 'surprised', 'excited', 'demon', 'heart') THEN
        RETURN jsonb_build_object('status', 'invalid_reaction');
    END IF;

    -- 7. Persist the vote.
    INSERT INTO public.minigame_reactions (session_id, round, voter_id, reaction)
    VALUES (p_session_id, p_round, auth.uid(), p_reaction)
    ON CONFLICT (session_id, round, voter_id) DO UPDATE
        SET reaction = EXCLUDED.reaction;

    -- 8. Mirror into the state payload (realtime) under the round's subject.
    --    The mirror carries the ordered vote list AND the distinct-voter
    --    count ({subject_id: {"list": [emoji...], "count": N}}) so clients
    --    render the live tally without re-querying (security hardening
    --    2026-08-31 — the count is distinct voters, never rows).
    UPDATE public.minigame_game_state
    SET state = jsonb_set(
            state,
            '{reactions}',
            COALESCE((
                SELECT jsonb_build_object(
                    v_subject_id::text,
                    jsonb_build_object(
                        'list',
                        (SELECT COALESCE(jsonb_agg(r.reaction ORDER BY r.created_at), '[]'::jsonb)
                         FROM public.minigame_reactions r
                         WHERE r.session_id = p_session_id AND r.round = p_round),
                        'count',
                        (SELECT count(distinct r.voter_id)
                         FROM public.minigame_reactions r
                         WHERE r.session_id = p_session_id AND r.round = p_round)
                    )
                )
            ), '{}'::jsonb),
            true
        )
    WHERE session_id = p_session_id;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'submitted', 'state', v_row);
END;
$$;

-- ======================================================================
-- 12. submit_minigame_async_answer(uuid, text, text, text)
-- Async mode: the caller completes one of their per-player rounds. The server
-- draws a random prompt of the requested prompt_type, records the round
-- (round_map[uid]++), and mirrors it into state.answers so the reactable
-- list streams realtime. When every participant reaches their per-player
-- target the game AUTO-FINISHES.
-- ======================================================================
CREATE FUNCTION public.submit_minigame_async_answer(p_session_id uuid, p_prompt_type text, p_answer_ciphertext text, p_image_storage_path text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_game_type public.mini_game_type;
    v_prompt jsonb;
    v_state jsonb;
    v_async_rounds integer;
    v_rounds_per_player integer;
    v_round integer;
    v_all_done boolean;
    v_row jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + lock.
    SELECT group_id, status, participants, game_type
        INTO v_group_id, v_status, v_participants, v_game_type
        FROM public.minigame_sessions
        WHERE id = p_session_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 3. Access gate — participant-only on the WRITE path (security
    --    hardening 2026-08-31: invitees / inactive group members can render
    --    the lobby but never answer).
    IF NOT (auth.uid() = ANY (v_participants)) THEN
        RETURN jsonb_build_object('status', 'not_allowed');
    END IF;

    -- 4. Lifecycle + async-only + playing gate.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_state IS NULL OR v_state ->> 'phase' <> 'playing' THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;
    IF COALESCE(v_state ->> 'play_mode', 'by_turns') <> 'async' THEN
        RETURN jsonb_build_object('status', 'wrong_mode');
    END IF;

    -- 5. Async timer gate: the deadline is fixed at creation (no override).
    IF (v_state ->> 'async_ends_at')::timestamptz <= now() THEN
        RETURN public.finish_minigame_game(p_session_id);
    END IF;

    -- 6. Prompt-type validation against the bank for THIS game type.
    IF NOT EXISTS (
        SELECT 1 FROM public.minigame_prompts
        WHERE game_type = v_game_type AND prompt_type = p_prompt_type
    ) THEN
        RETURN jsonb_build_object('status', 'invalid_prompt_type');
    END IF;

    -- 7. Per-player round target: the caller cannot exceed their quota.
    v_rounds_per_player := COALESCE((v_state ->> 'async_rounds_per_player')::integer, 1);
    v_round := COALESCE((v_state -> 'round_map' ->> auth.uid()::text)::integer, 0);
    IF v_round >= v_rounds_per_player THEN
        RETURN jsonb_build_object('status', 'rounds_exhausted');
    END IF;

    -- 8. Random draw of one active prompt.
    SELECT to_jsonb(p) INTO v_prompt
    FROM public.minigame_prompts p
    WHERE p.game_type = v_game_type
      AND p.prompt_type = p_prompt_type
      AND p.is_active = true
    ORDER BY random()
    LIMIT 1;
    IF v_prompt IS NULL THEN
        RETURN jsonb_build_object('status', 'no_prompts_available');
    END IF;

    -- 9. The round number is GLOBAL (1-based across the session) so the
    --    reactable list addresses each round uniquely.
    SELECT COALESCE(max(a.round) + 1, 1) INTO v_round
    FROM public.minigame_answers a
    WHERE a.session_id = p_session_id;

    -- 10. Persist the E2EE answer.
    INSERT INTO public.minigame_answers
        (session_id, round, subject_id, prompt_type, prompt_id,
         answer_ciphertext, image_storage_path, passed)
    VALUES
        (p_session_id, v_round, auth.uid(), p_prompt_type, (v_prompt ->> 'id')::uuid,
         p_answer_ciphertext, p_image_storage_path, false);

    -- 11. Bump the caller's round_map + mirror the round into state.answers.
    UPDATE public.minigame_game_state
    SET state = jsonb_set(
            jsonb_set(
                state,
                '{round_map}',
                (
                    SELECT jsonb_object_agg(kk, vv::int)
                    FROM (
                        SELECT e.k AS kk, e.v::text AS vv
                        FROM jsonb_each(v_state -> 'round_map') AS e(k, v)
                        UNION ALL
                        SELECT auth.uid()::text AS kk,
                               (COALESCE((v_state -> 'round_map' ->> auth.uid()::text)::int, 0) + 1)::text AS vv
                    ) merged
                ),
                true
            ),
            '{answers}',
            v_state -> 'answers' || jsonb_build_array(
                jsonb_build_object(
                    'round', v_round,
                    'subject_id', auth.uid(),
                    'prompt_type', p_prompt_type,
                    'prompt_id', (v_prompt ->> 'id')::uuid,
                    'answer_ciphertext', p_answer_ciphertext,
                    'image_storage_path', p_image_storage_path,
                    'passed', false
                )
            ),
            true
        )
    WHERE session_id = p_session_id;

    -- 12. Auto-finish when every participant reached their per-player target
    --     (read the FRESH round_map after the UPDATE above).
    SELECT bool_and(
        COALESCE((m.state -> 'round_map' ->> participant::text)::integer, 0) >= v_rounds_per_player
    ) INTO v_all_done
    FROM public.minigame_game_state m
    CROSS JOIN unnest(v_participants) AS participant
    WHERE m.session_id = p_session_id;

    IF v_all_done THEN
        RETURN public.finish_minigame_game(p_session_id);
    END IF;

    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;

    RETURN jsonb_build_object('status', 'submitted', 'state', v_row);
END;
$$;

-- ======================================================================
-- 13. advance_minigame_turn(uuid, jsonb) — CREATE OR REPLACE (201 sig)
-- 202 by_turns contract: the turn advances only when ALL non-subject
-- participants have reacted (or the subject passed — handled by
-- _minigame_advance_round), else 'waiting_reactions'. The CREATOR may
-- FORCE-advance an idle round.
-- ======================================================================
CREATE OR REPLACE FUNCTION public.advance_minigame_turn(p_session_id uuid, p_round jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_state jsonb;
    v_phase text;
    v_round integer;
    v_subject_id uuid;
    v_reacted_count integer;
    v_required_count integer;
    v_is_creator boolean;
    v_answer jsonb;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock.
    SELECT group_id, status, participants
        INTO v_group_id, v_status, v_participants
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

    -- 4. Lifecycle gate.
    IF v_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_not_active');
    END IF;

    -- 5. Load the game-state row.
    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_state IS NULL THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    v_phase := v_state ->> 'phase';
    IF v_phase = 'countdown' THEN
        RETURN jsonb_build_object('status', 'countdown_pending');
    END IF;
    IF v_phase <> 'playing' THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    -- 5b. by_turns only (async advances happen per-answer / on the timer).
    IF COALESCE(v_state ->> 'play_mode', 'by_turns') <> 'by_turns' THEN
        RETURN jsonb_build_object('status', 'wrong_mode');
    END IF;

    -- 6. The round must have an answer (answered or passed) to close.
    v_round := COALESCE((v_state ->> 'round')::integer, 0);
    v_subject_id := (v_state ->> 'subject_id')::uuid;
    SELECT to_jsonb(a) INTO v_answer
    FROM public.minigame_answers a
    WHERE a.session_id = p_session_id AND a.round = v_round;
    IF v_answer IS NULL THEN
        RETURN jsonb_build_object('status', 'answer_pending');
    END IF;

    -- 7. All-reacted gate: advance only when every non-subject participant
    --    has reacted (a passed round was already auto-advanced, so its
    --    answer row is gone from the CURRENT round). The creator may
    --    FORCE-advance an idle round (202 user directive). The count is
    --    DISTINCT voters (security hardening 2026-08-31 — re-votes by one
    --    voter must never inflate the advance gate).
    v_required_count := COALESCE(array_length(v_participants, 1), 1) - 1;
    SELECT count(distinct voter_id) INTO v_reacted_count
    FROM public.minigame_reactions
    WHERE session_id = p_session_id AND round = v_round;
    v_is_creator := array_length(v_participants, 1) IS NOT NULL
                    AND v_participants[1] = auth.uid();

    IF v_reacted_count < v_required_count AND NOT v_is_creator THEN
        RETURN jsonb_build_object('status', 'waiting_reactions');
    END IF;

    RETURN public._minigame_advance_round(p_session_id);
END;
$$;

-- ======================================================================
-- 14. get_minigame_game_state(uuid) — CREATE OR REPLACE (201 sig)
-- 202 additions: the async timer lazy-flip (an async session past its
-- deadline settles on read) alongside the existing countdown lazy-flip.
-- ======================================================================
CREATE OR REPLACE FUNCTION public.get_minigame_game_state(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_participants uuid[];
    v_row jsonb;
    v_phase text;
    v_deadline text;
    v_play_mode text;
    v_async_ends_at text;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup (no lock — read-only).
    SELECT group_id, participants
        INTO v_group_id, v_participants
        FROM public.minigame_sessions
        WHERE id = p_session_id;
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

    -- 4. Lazy countdown flip (190) + async timer lazy-flip (202): an async
    --    session past async_ends_at settles on read.
    SELECT m.state ->> 'phase',
           m.state ->> 'countdown_ends_at',
           m.state ->> 'play_mode',
           m.state ->> 'async_ends_at'
        INTO v_phase, v_deadline, v_play_mode, v_async_ends_at
        FROM public.minigame_game_state m
        WHERE m.session_id = p_session_id;

    IF v_phase = 'countdown' AND v_deadline IS NOT NULL
       AND (v_deadline)::timestamptz <= now() THEN
        UPDATE public.minigame_game_state
        SET state = state
                    - 'countdown_ends_at'
                    || jsonb_build_object('phase', 'playing')
        WHERE session_id = p_session_id;
    ELSIF COALESCE(v_play_mode, 'by_turns') = 'async'
          AND v_async_ends_at IS NOT NULL
          AND (v_async_ends_at)::timestamptz <= now()
          AND v_phase = 'playing' THEN
        RETURN public.finish_minigame_game(p_session_id);
    END IF;

    -- 5. Read the (possibly advanced) state row.
    SELECT to_jsonb(m) INTO v_row
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    IF v_row IS NULL THEN
        RETURN jsonb_build_object('status', 'not_started');
    END IF;

    RETURN jsonb_build_object('status', 'ok', 'state', v_row);
END;
$$;

-- ======================================================================
-- 15. finish_minigame_game(uuid) — CREATE OR REPLACE (201 sig)
-- 202: async sessions score from minigame_reactions (total reactions
-- received across the player's rounds, -1 per passed round) instead of the
-- by_turns per-round score. Anonymous sessions keep the reveal of real
-- usernames to the leaderboard (the RLS on the roster hides them during
-- play; the results carry participant ids the client resolves at the end).
-- ======================================================================
CREATE OR REPLACE FUNCTION public.finish_minigame_game(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
    v_status public.mini_game_status;
    v_participants uuid[];
    v_wager integer;
    v_prize_positions integer;
    v_rounds jsonb[];
    v_state jsonb;
    v_play_mode text;
    v_pot integer;
    v_prize_rows jsonb;
    v_row jsonb;
    v_result jsonb;
    v_prize integer;
    v_player_count integer;
    v_lcm integer;
    v_denom integer;
    v_r integer;
    v_weights jsonb;
    v_base jsonb;
    v_remaining integer;
    v_rank integer;
BEGIN
    -- 1. Authentication gate.
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Session lookup + row lock.
    SELECT group_id, status, participants, shard_wager, prize_positions
        INTO v_group_id, v_status, v_participants, v_wager, v_prize_positions
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
    v_pot := v_wager * v_player_count;
    v_prize_positions := LEAST(COALESCE(v_prize_positions, 3), v_player_count);

    SELECT m.state INTO v_state
    FROM public.minigame_game_state m
    WHERE m.session_id = p_session_id;
    v_play_mode := COALESCE(v_state ->> 'play_mode', 'by_turns');

    -- 5. Scoreboard source of truth: by_turns = rounds history; async =
    --    reactions across the player's rounds (summed; -1 per passed round).
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
                       COALESCE(SUM(CASE
                           WHEN (a.passed) THEN -1
                           ELSE (SELECT count(*) FROM public.minigame_reactions r
                                 WHERE r.session_id = p_session_id
                                   AND r.round = a.round)
                       END), 0) AS score,
                       row_number() OVER (
                           ORDER BY COALESCE(SUM(CASE
                               WHEN (a.passed) THEN -1
                               ELSE (SELECT count(*) FROM public.minigame_reactions r
                                     WHERE r.session_id = p_session_id
                                       AND r.round = a.round)
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
            WHERE sc.rank <= v_prize_positions
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
                       COALESCE(sum(r.value), 0) AS score,
                       row_number() OVER (
                           ORDER BY COALESCE(sum(r.value), 0) DESC, s.ord
                       ) AS rank
                FROM unnest(v_participants) WITH ORDINALITY AS s(participant_id, ord)
                LEFT JOIN LATERAL (
                    SELECT (rr ->> 'score')::int AS value
                    FROM unnest(v_rounds) rr
                    WHERE (rr ->> 'subject_id')::uuid = s.participant_id
                ) r ON true
                GROUP BY s.participant_id, s.ord
            ) sc
            WHERE sc.rank <= v_prize_positions
        ) ranked_rows;
    END IF;

    IF v_prize_rows IS NULL THEN
        v_prize_rows := '[]'::jsonb;
    END IF;

    -- 6. HARMONIC prize weights (201, unchanged — integer-exact split).
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
                   'prize', CASE WHEN v_pot = 0 THEN 0
                                 ELSE (v_pot * (w ->> 'weight')::int) / v_denom END
               ) ORDER BY r.rank)
        FROM (
            SELECT (v ->> 'rank')::int AS rank
            FROM jsonb_array_elements(v_prize_rows) v
        ) r
        JOIN jsonb_array_elements(v_weights) w ON (w ->> 'rank')::int = r.rank
    );

    IF v_pot > 0 THEN
        v_remaining := v_pot - (SELECT sum((b ->> 'prize')::int) FROM jsonb_array_elements(v_base) b);
        FOR v_r IN 1..v_remaining LOOP
            v_base := (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'rank', (b ->> 'rank')::int,
                        'prize', CASE
                            WHEN (b ->> 'rank')::int = v_r THEN (b ->> 'prize')::int + 1
                            ELSE (b ->> 'prize')::int
                        END
                    )
                    ORDER BY (b ->> 'rank')::int
                )
                FROM jsonb_array_elements(v_base) b
            );
        END LOOP;
    END IF;

    -- 7. Pay the pot.
    IF v_pot > 0 THEN
        FOR v_result IN SELECT * FROM jsonb_array_elements(v_prize_rows)
        LOOP
            v_rank := (v_result ->> 'rank')::int;
            SELECT (b ->> 'prize')::int INTO v_prize
            FROM jsonb_array_elements(v_base) b
            WHERE (b ->> 'rank')::int = v_rank;
            IF v_prize IS NULL OR v_prize <= 0 THEN
                CONTINUE;
            END IF;

            UPDATE public.users
            SET personal_shards = personal_shards + v_prize
            WHERE id = (v_result ->> 'participant_id')::uuid;

            INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
            VALUES ((v_result ->> 'participant_id')::uuid, v_prize,
                    'minigame_win', p_session_id);
        END LOOP;
    END IF;

    -- 8. Write the settle-once leaderboard.
    INSERT INTO public.minigame_results (session_id, results)
    SELECT p_session_id, jsonb_agg(jsonb_build_object(
               'participant_id', v ->> 'participant_id',
               'score', (v ->> 'score')::int,
               'rank', (v ->> 'rank')::int,
               'prize', CASE
                   WHEN v_pot = 0 THEN 0
                   ELSE COALESCE((SELECT (b ->> 'prize')::int
                                  FROM jsonb_array_elements(v_base) b
                                  WHERE (b ->> 'rank')::int = (v ->> 'rank')::int), 0)
               END
           ) ORDER BY (v ->> 'rank')::int)
    FROM jsonb_array_elements(v_prize_rows) v;

    -- 9. Flip the game phase + session status to finished.
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

-- ======================================================================
-- 16. Realtime: the new tables join supabase_realtime (answers stream live
--     so the reactable rounds / submitted answer reach every participant).
--     Guarded — never fights make supabase-init.
-- ======================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_aliases') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.minigame_aliases;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_answers') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.minigame_answers;
  END IF;
END
$$;

-- ======================================================================
-- 17. pg_cron: async auto-finish job (settles async sessions past their
--     deadline — the settable timer, no override).
-- ======================================================================
DO $job$ BEGIN
  PERFORM cron.schedule('minigames-async-finish', '* * * * *',
    $cmd$SELECT public.finish_minigame_game(id) FROM public.minigame_sessions
       WHERE status = 'active' AND play_mode = 'async'
         AND async_ends_at <= now();$cmd$);
END $job$;

-- ======================================================================
-- 18. ACLs — hardened posture (no PUBLIC; authenticated + service_role only,
--     mirror of 140/150/180/190/201).
-- ======================================================================
REVOKE ALL ON FUNCTION public.set_minigame_alias(p_session_id uuid, p_alias text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_minigame_alias(p_session_id uuid, p_alias text) TO authenticated;
GRANT ALL ON FUNCTION public.set_minigame_alias(p_session_id uuid, p_alias text) TO service_role;

REVOKE ALL ON FUNCTION public.submit_minigame_answer(p_session_id uuid, p_answer_ciphertext text, p_image_storage_path text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_minigame_answer(p_session_id uuid, p_answer_ciphertext text, p_image_storage_path text) TO authenticated;
GRANT ALL ON FUNCTION public.submit_minigame_answer(p_session_id uuid, p_answer_ciphertext text, p_image_storage_path text) TO service_role;

REVOKE ALL ON FUNCTION public.submit_minigame_pasar(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_minigame_pasar(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.submit_minigame_pasar(p_session_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.react_minigame_round(p_session_id uuid, p_round integer, p_reaction text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.react_minigame_round(p_session_id uuid, p_round integer, p_reaction text) TO authenticated;
GRANT ALL ON FUNCTION public.react_minigame_round(p_session_id uuid, p_round integer, p_reaction text) TO service_role;

-- _minigame_advance_round is SECURITY DEFINER and reached only through the
-- gated public RPCs (advance_minigame_turn / submit_minigame_reaction /
-- submit_minigame_pasar). It must NEVER be anon-callable: without an explicit
-- ACL it inherited PUBLIC EXECUTE from the schema defaults (2026-08-31
-- hardening finding) — revoke it here like every other play-engine function.
REVOKE ALL ON FUNCTION public._minigame_advance_round(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public._minigame_advance_round(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public._minigame_advance_round(p_session_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.submit_minigame_async_answer(p_session_id uuid, p_prompt_type text, p_answer_ciphertext text, p_image_storage_path text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_minigame_async_answer(p_session_id uuid, p_prompt_type text, p_answer_ciphertext text, p_image_storage_path text) TO authenticated;
GRANT ALL ON FUNCTION public.submit_minigame_async_answer(p_session_id uuid, p_prompt_type text, p_answer_ciphertext text, p_image_storage_path text) TO service_role;

REVOKE ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text, p_rounds integer, p_prize_positions integer, p_play_mode text, p_anonymous boolean, p_async_rounds_per_player integer, p_async_ends_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text, p_rounds integer, p_prize_positions integer, p_play_mode text, p_anonymous boolean, p_async_rounds_per_player integer, p_async_ends_at timestamp with time zone) TO authenticated;
GRANT ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[], p_name text, p_rounds integer, p_prize_positions integer, p_play_mode text, p_anonymous boolean, p_async_rounds_per_player integer, p_async_ends_at timestamp with time zone) TO service_role;

REVOKE ALL ON TABLE public.minigame_aliases FROM anon;
REVOKE ALL ON TABLE public.minigame_aliases FROM authenticated;
GRANT SELECT ON TABLE public.minigame_aliases TO authenticated;
GRANT ALL ON TABLE public.minigame_aliases TO service_role;

REVOKE ALL ON TABLE public.minigame_answers FROM anon;
REVOKE ALL ON TABLE public.minigame_answers FROM authenticated;
GRANT SELECT ON TABLE public.minigame_answers TO authenticated;
GRANT ALL ON TABLE public.minigame_answers TO service_role;

REVOKE ALL ON TABLE public.minigame_e2ee_bundles FROM anon;
REVOKE ALL ON TABLE public.minigame_e2ee_bundles FROM authenticated;
GRANT SELECT, INSERT ON TABLE public.minigame_e2ee_bundles TO authenticated;
GRANT ALL ON TABLE public.minigame_e2ee_bundles TO service_role;
