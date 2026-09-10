-- 208_minigame_alias_unique — session-unique anonymous nicknames (2026-09-10).
--
-- Anonymous mode's temp nicknames must be distinguishable inside a session:
-- two players may not pick the same name or the leaderboard/reactor lines
-- become ambiguous. This migration:
--   1. Adds a UNIQUE index on (session_id, lower(btrim(alias))) — the
--      canonical, case-insensitive/trimmed uniqueness key. Defence in depth:
--      it also closes the race between two concurrent renames.
--   2. Replaces set_minigame_alias so it:
--      * rejects a name already used by ANOTHER participant in the session
--        (case-insensitive, trimmed) with the new `alias_taken` status, and
--      * maps the unique-index violation to the same `alias_taken` status so
--        a lost race is a friendly rejection, never a raw 23505.
--
-- A participant KEEPING their own current name is allowed (the self-row is
-- excluded from the check; the ON CONFLICT update stays valid).

-- ======================================================================
-- 1. Unique nickname per session (case-insensitive, trimmed)
-- ======================================================================
CREATE UNIQUE INDEX minigame_aliases_session_alias_uniq
    ON public.minigame_aliases (session_id, lower(btrim(alias)));

-- ======================================================================
-- 2. set_minigame_alias(uuid, text) — CREATE OR REPLACE (202 sig)
-- 208 addition: session-unique, case-insensitive nickname + alias_taken.
-- ======================================================================
CREATE OR REPLACE FUNCTION public.set_minigame_alias(p_session_id uuid, p_alias text) RETURNS jsonb
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

    -- 6. Session-unique nickname (208): another participant must not already
    --    hold the same name (case-insensitive, trimmed). The caller's OWN row
    --    is excluded so re-saving the current name is a no-op success.
    IF EXISTS (
        SELECT 1 FROM public.minigame_aliases
        WHERE session_id = p_session_id
          AND participant_id <> auth.uid()
          AND lower(btrim(alias)) = lower(v_alias)
    ) THEN
        RETURN jsonb_build_object('status', 'alias_taken');
    END IF;

    -- 7. Upsert (one nickname per participant per session). A unique-index
    --    race maps to the same friendly alias_taken rejection.
    BEGIN
        INSERT INTO public.minigame_aliases (session_id, participant_id, alias)
        VALUES (p_session_id, auth.uid(), v_alias)
        ON CONFLICT (session_id, participant_id) DO UPDATE
            SET alias = EXCLUDED.alias, updated_at = now();
    EXCEPTION WHEN unique_violation THEN
        RETURN jsonb_build_object('status', 'alias_taken');
    END;

    RETURN jsonb_build_object('status', 'alias_set', 'alias', v_alias);
END;
$$;

REVOKE ALL ON FUNCTION public.set_minigame_alias(p_session_id uuid, p_alias text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_minigame_alias(p_session_id uuid, p_alias text) TO authenticated;
GRANT ALL ON FUNCTION public.set_minigame_alias(p_session_id uuid, p_alias text) TO service_role;
