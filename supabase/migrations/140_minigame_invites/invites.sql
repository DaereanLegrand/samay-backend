-- Samay — 140_minigame_invites/invites.sql
-- Minigame player invites (GMCR participant-select, 2026-08-26).
--
-- Extends the group-scoped minigame foundation (100_minigames) so sessions
-- can carry INVITEES selected from the user-search pool (reusing the
-- searchResultsProvider plumbing client-side). Model:
--
--   * minigame_invites — one row per (session, invitee); status
--     pending -> accepted | declined. An invitee need NOT be a group member:
--     the ms_read_invitee SELECT policy opens the session row to invitees so
--     the detail screen can render, and accepting is a server-side contract
--     (accept_minigame_invite) that mirrors create/join escrow. Accepts are
--     ONLY possible while the session is active (finished -> closed).
--   * users.minigame_invite_friends_only — the invite privacy switch
--     (default OFF = non-friends may invite me). Enforced in
--     create_minigame_session, never trusted client-side. Served via the
--     set_minigame_invite_friends_only RPC (profile-RPC lockdown: clients
--     hold no UPDATE on users).
--   * create_minigame_session gains p_invitees uuid[] (the previous 3-arg
--     overload is dropped; CREATE OR REPLACE cannot change the argument
--     list). Same transaction as the session insert + creator escrow.
--   * The minigame invite notification trigger moves from minigame_sessions
--     INSERT to minigame_invites INSERT (it must notify INVITEES, not the
--     creator-as-participant), and `notifications` joins the
--     supabase_realtime publication so invites arrive LIVE in the invitee's
--     notification center (GO-realtime directive).

-- Name: mini_game_invite_status; Type: TYPE; Schema: public; Owner: -
CREATE TYPE public.mini_game_invite_status AS ENUM (
    'pending',
    'accepted',
    'declined'
);

-- Name: minigame_invites; Type: TABLE; Schema: public; Owner: -
CREATE TABLE public.minigame_invites (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    session_id uuid NOT NULL,
    invitee_id uuid NOT NULL,
    created_by uuid NOT NULL,
    status public.mini_game_invite_status DEFAULT 'pending'::public.mini_game_invite_status NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    decided_at timestamp with time zone
);

-- RLS must be ENABLED for the mi_read_own policy to apply; FORCE alone does
-- not enable it (without this, any authenticated user can read every invite).
ALTER TABLE public.minigame_invites ENABLE ROW LEVEL SECURITY;

ALTER TABLE ONLY public.minigame_invites FORCE ROW LEVEL SECURITY;

-- Name: minigame_invites minigame_invites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
ALTER TABLE ONLY public.minigame_invites
    ADD CONSTRAINT minigame_invites_pkey PRIMARY KEY (id);

-- A player can only be invited once per session (idempotent invites).
ALTER TABLE ONLY public.minigame_invites
    ADD CONSTRAINT minigame_invites_session_invitee_key UNIQUE (session_id, invitee_id);

ALTER TABLE ONLY public.minigame_invites
    ADD CONSTRAINT minigame_invites_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.minigame_sessions(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.minigame_invites
    ADD CONSTRAINT minigame_invites_invitee_id_fkey FOREIGN KEY (invitee_id) REFERENCES public.users(id);

ALTER TABLE ONLY public.minigame_invites
    ADD CONSTRAINT minigame_invites_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);

CREATE INDEX idx_minigame_invites_invitee ON public.minigame_invites USING btree (invitee_id);
CREATE INDEX idx_minigame_invites_session ON public.minigame_invites USING btree (session_id);

-- Name: users minigame_invite_friends_only; Type: COLUMN; Schema: public; Owner: -
ALTER TABLE public.users ADD COLUMN minigame_invite_friends_only boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.users.minigame_invite_friends_only IS
    'Invite privacy switch: when TRUE only accepted friends may invite this user to a minigame (default FALSE = anyone may invite).';

-- ======================================================================
-- set_minigame_invite_friends_only(boolean)
-- Profile-RPC lockdown: clients hold no UPDATE on users, so the privacy
-- toggle self-serves through this SECURITY DEFINER RPC scoped to auth.uid()
-- (mirror of set_read_receipts_enabled / set_profile_public).
-- ======================================================================
CREATE FUNCTION public.set_minigame_invite_friends_only(p_value boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.users SET minigame_invite_friends_only = p_value WHERE id = auth.uid();
END;
$$;

-- ======================================================================
-- create_minigame_session(uuid, text, integer, uuid[])
-- ----------------------------------------------------------------------
-- Replaces the GMCR 3-arg baseline with the invite-aware 4-arg contract.
-- The old overload is dropped first (CREATE OR REPLACE cannot change the
-- argument list). New p_invitees uuid[] semantics:
--   * deduped (self + repeats removed), capped at 20 (search caps at 20;
--     defence in depth against abuse).
--   * each invitee must be a live user (users row, deleted_at IS NULL)
--     and NOT blocked in either direction (friendships.status='blocked').
--   * an invitee with users.minigame_invite_friends_only=true requires an
--     accepted friendship with the caller (either direction).
--   * a single failing invitee rejects the WHOLE create atomically
--     (typed jsonb statuses, I-57 contract).
-- On success: creator escrow (unchanged) + session insert + one
-- minigame_invites (pending) row per invitee, all in one transaction.
-- ======================================================================
DROP FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer);

CREATE FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[] DEFAULT '{}'::uuid[]) RETURNS jsonb
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
BEGIN
    -- 1. Authentication gate.
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 1b. Player cap frozen at creation (direct-minigames 2026-08-27):
    --     the CREATOR's subscription tier selects the app_config cap
    --     (minigame.{free,pro,vip}_max_players, defaults 8/32/100). Stored
    --     on the session so joins/accepts never re-read a downgraded tier.
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

    -- 2. Group-membership gate (direct-minigames 2026-08-27): a NULL
    --    p_group_id = DIRECT session and needs no group; a non-null group
    --    still requires active membership (is_group_member helper).
    IF p_group_id IS NOT NULL AND NOT public.is_group_member(p_group_id) THEN
        RETURN jsonb_build_object('status', 'not_member');
    END IF;

    -- 3. Wager validation (GWAG: integer shards >= 0; 0 = no wager).
    IF p_wager < 0 THEN
        RETURN jsonb_build_object('status', 'invalid_wager');
    END IF;

    -- 4. Game-type validation against the mini_game_type enum.
    BEGIN
        v_game_type := p_game_type::public.mini_game_type;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('status', 'invalid_game_type');
    END;

    -- 5. Invitee cleaning + per-invitee gates (blocked / deleted /
    --    friends-only privacy) — a single violation rejects atomically.
    IF p_invitees IS NOT NULL AND array_length(p_invitees, 1) > 0 THEN
        FOR v_invitee IN
            SELECT DISTINCT unnest(p_invitees)
        LOOP
            IF v_invitee = v_current_user THEN
                CONTINUE; -- never invite yourself
            END IF;
            IF array_length(v_clean_invitees, 1) >= 20 THEN
                RETURN jsonb_build_object('status', 'too_many_invitees');
            END IF;

            -- Blocked (either direction) or deleted invitees are rejected.
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

            -- Friends-only privacy: the invitee opted to be invitable only
            -- by accepted friends.
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

    -- 6. Player-cap gate (direct-minigames 2026-08-27): the creator counts
    --    as one participant (they are always participant[0]); the frozen
    --    player_limit bounds the total roster (free 8, scaled by the
    --    creator's tier). Typed rejection — the whole create stays atomic.
    IF (1 + COALESCE(array_length(v_clean_invitees, 1), 0)) > v_player_limit THEN
        RETURN jsonb_build_object('status', 'player_limit_reached');
    END IF;

    -- 7. Wager escrow (unchanged from the baseline 3-arg contract).
    IF p_wager > 0 THEN
        UPDATE public.users
        SET personal_shards = personal_shards - p_wager
        WHERE id = v_current_user AND personal_shards >= p_wager;

        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'insufficient_shards');
        END IF;
    END IF;

    -- 8. Session insert (the initiator is the first participant; the
    --    frozen player_limit rides the row).
    INSERT INTO public.minigame_sessions
        (group_id, game_type, status, shard_wager, player_limit, participants)
    VALUES
        (p_group_id, v_game_type, 'active', p_wager, v_player_limit,
         ARRAY[v_current_user])
    RETURNING id INTO v_session_id;

    -- 9. Ledger entry with the session reference (escrow verifiability).
    IF p_wager > 0 THEN
        INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
        VALUES (v_current_user, -p_wager, 'minigame_wager', v_session_id);
    END IF;

    -- 10. Invite rows (one pending row per invitee; the notify trigger on
    --    minigame_invites dispatches the realtime notification).
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
-- accept_minigame_invite(uuid)
-- The invitee accepts a pending invite. Accepts are ONLY valid while the
-- session is active (finished sessions cannot be joined) and the invite is
-- pending. Mirrors join_minigame_session escrow: wager deduction + ledger
-- entry + participants append + invite status flip, one transaction.
-- ======================================================================
CREATE FUNCTION public.accept_minigame_invite(p_invite_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_current_user uuid;
    v_invitee_id uuid;
    v_invite_status public.mini_game_invite_status;
    v_session_id uuid;
    v_group_id uuid;
    v_wager integer;
    v_session_status public.mini_game_status;
    v_participants uuid[];
    v_player_limit integer;
BEGIN
    -- 1. Authentication gate.
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- 2. Invite lookup + row lock (serialize concurrent accepts).
    SELECT session_id, invitee_id, status
        INTO v_session_id, v_invitee_id, v_invite_status
        FROM public.minigame_invites
        WHERE id = p_invite_id
        FOR UPDATE;
    IF NOT FOUND OR v_invitee_id <> v_current_user THEN
        RETURN jsonb_build_object('status', 'invite_not_found');
    END IF;

    -- 3. Idempotent accept / declined guard.
    IF v_invite_status = 'accepted' THEN
        RETURN jsonb_build_object('status', 'already_accepted');
    END IF;
    IF v_invite_status = 'declined' THEN
        RETURN jsonb_build_object('status', 'invite_not_active');
    END IF;

    -- 4. Session lookup + row lock (serialize against finish/join).
    SELECT group_id, shard_wager, status, participants, player_limit
        INTO v_group_id, v_wager, v_session_status, v_participants,
             v_player_limit
        FROM public.minigame_sessions
        WHERE id = v_session_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'session_not_found');
    END IF;

    -- 5. Lifecycle gate: accepts only on ACTIVE sessions (a finished game
    --    can no longer be joined — product contract).
    IF v_session_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'session_finished');
    END IF;

    -- 6. Idempotency: an already-participant accept is a no-op (mark the
    --    invite accepted and return).
    IF v_current_user = ANY(v_participants) THEN
        UPDATE public.minigame_invites
        SET status = 'accepted', decided_at = now()
        WHERE id = p_invite_id;
        RETURN jsonb_build_object('status', 'accepted');
    END IF;

    -- 6b. Player cap (direct-minigames 2026-08-27): the frozen
    --     player_limit bounds the roster — a late join when the session is
    --     full is rejected atomically (never trusted client-side).
    IF array_length(v_participants, 1) >= v_player_limit THEN
        RETURN jsonb_build_object('status', 'player_limit_reached');
    END IF;

    -- 7. Escrow on accept (mirror of create/join).
    IF v_wager > 0 THEN
        UPDATE public.users
        SET personal_shards = personal_shards - v_wager
        WHERE id = v_current_user AND personal_shards >= v_wager;

        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'insufficient_shards');
        END IF;

        INSERT INTO public.shard_ledger (user_id, delta, reason, reference_id)
        VALUES (v_current_user, -v_wager, 'minigame_wager', v_session_id);
    END IF;

    -- 8. Append the caller to the participants array + flip the invite.
    UPDATE public.minigame_sessions
    SET participants = participants || ARRAY[v_current_user]
    WHERE id = v_session_id;

    UPDATE public.minigame_invites
    SET status = 'accepted', decided_at = now()
    WHERE id = p_invite_id;

    RETURN jsonb_build_object('status', 'accepted');
END;
$$;

-- ======================================================================
-- decline_minigame_invite(uuid)
-- The invitee declines a pending invite. The row is DELETED — a declined
-- invite is indistinguishable from one that never existed (2026-09-02 user
-- directive: "declined must delete the invite like it never happened").
-- This is what makes RE-INVITE a plain fresh INSERT: the (session_id,
-- invitee_id) UNIQUE is satisfied because the old row is gone, so the host
-- can invite the same player again and invite_minigame_players fires the
-- INSERT-time notification unchanged. Accepted invites cannot be declined.
-- ======================================================================
CREATE FUNCTION public.decline_minigame_invite(p_invite_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_current_user uuid;
    v_invite_status public.mini_game_invite_status;
BEGIN
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    -- Only the invitee may decline their own invite (the invitee_id filter
    -- folds the ownership gate into the lookup — a foreign row reads as
    -- not_found).
    SELECT status
        INTO v_invite_status
        FROM public.minigame_invites
        WHERE id = p_invite_id AND invitee_id = v_current_user
        FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'invite_not_found');
    END IF;

    IF v_invite_status = 'accepted' THEN
        RETURN jsonb_build_object('status', 'already_accepted');
    END IF;

    DELETE FROM public.minigame_invites
    WHERE id = p_invite_id AND invitee_id = v_current_user;

    RETURN jsonb_build_object('status', 'declined');
END;
$$;

-- ======================================================================
-- ms_read_invitee — invitees (even non-members) may read the session row.
-- The foundation kept sessions strictly member-only (ms_read_group_member);
-- invites must open the narrowest READ that lets an invitee render the
-- session detail and accept while it is active.
-- ======================================================================
CREATE POLICY ms_read_invitee ON public.minigame_sessions FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM public.minigame_invites
        WHERE minigame_invites.session_id = minigame_sessions.id
          AND minigame_invites.invitee_id = auth.uid()
    )
);

-- ======================================================================
-- minigame_invites RLS: invitees read their own rows, creators read the
-- rows they created. No client INSERT/UPDATE — the RPC family owns every
-- write (FORCE RLS).
-- ======================================================================
CREATE POLICY mi_read_own ON public.minigame_invites FOR SELECT USING (
    (invitee_id = auth.uid()) OR (created_by = auth.uid())
);

-- ======================================================================
-- Realtime: notifications + minigame_invites join supabase_realtime so the
-- invite notification lands LIVE in the invitee's notification center (and
-- the session detail can stream accept/decline). Guarded — never fights
-- make supabase-init (mirror of 960_realtime guards).
-- ======================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='notifications') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='minigame_invites') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.minigame_invites;
  END IF;
END
$$;

-- ======================================================================
-- Notification trigger: move the minigame-invite dispatch from
-- minigame_sessions INSERT (which notified the CREATOR-as-participant) to
-- minigame_invites INSERT (notifies the INVITEE). The old trigger/function
-- are replaced (CREATE OR REPLACE keeps the no-arg signature valid).
-- ======================================================================
DROP TRIGGER IF EXISTS notify_minigame_invite_trigger ON public.minigame_sessions;

CREATE OR REPLACE FUNCTION public.notify_minigame_invite() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_group_id uuid;
BEGIN
    SELECT group_id INTO v_group_id
    FROM public.minigame_sessions
    WHERE id = NEW.session_id;
    IF v_group_id IS NULL THEN
        RETURN NEW;
    END IF;

    PERFORM public.insert_notification(
        NEW.invitee_id,
        'minigame_invite',
        'Invitación a minijuego',
        'Te invitaron a un minijuego',
        jsonb_build_object('groupId', v_group_id, 'sessionId', NEW.session_id, 'inviteId', NEW.id)
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER notify_minigame_invite_trigger AFTER INSERT ON public.minigame_invites
    FOR EACH ROW EXECUTE FUNCTION public.notify_minigame_invite();

-- ======================================================================
-- ACLs — hardened posture (no PUBLIC, authenticated/service only, clients
-- never write the invites table directly).
-- ======================================================================
REVOKE ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[]) TO authenticated;
GRANT ALL ON FUNCTION public.create_minigame_session(p_group_id uuid, p_game_type text, p_wager integer, p_invitees uuid[]) TO service_role;

REVOKE ALL ON FUNCTION public.set_minigame_invite_friends_only(p_value boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_minigame_invite_friends_only(p_value boolean) TO authenticated;
GRANT ALL ON FUNCTION public.set_minigame_invite_friends_only(p_value boolean) TO service_role;

REVOKE ALL ON FUNCTION public.accept_minigame_invite(p_invite_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.accept_minigame_invite(p_invite_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.accept_minigame_invite(p_invite_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.decline_minigame_invite(p_invite_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.decline_minigame_invite(p_invite_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.decline_minigame_invite(p_invite_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.notify_minigame_invite() FROM PUBLIC;
GRANT ALL ON FUNCTION public.notify_minigame_invite() TO service_role;

REVOKE ALL ON TABLE public.minigame_invites FROM anon;
REVOKE ALL ON TABLE public.minigame_invites FROM authenticated;
GRANT SELECT ON TABLE public.minigame_invites TO authenticated;
GRANT ALL ON TABLE public.minigame_invites TO service_role;