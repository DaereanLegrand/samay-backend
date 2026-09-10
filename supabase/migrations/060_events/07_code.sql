-- Samay — 060_events/07_code.sql
--
-- Rotating attendance code (Stage 4, 2026-09-08). Each attendee — host,
-- designated staff, or invited guest — holds their own rotating 24-hex
-- attendance code. The code is derived authenticator-style (TOTP-like) from a
-- per-attendee secret + the current time window, so BOTH the attendee device
-- and the server derive it independently; the server is authoritative at
-- validation.
--
-- Model / decisions:
--
--   * Attendee = host/staff (event_hosts) OR a CONFIRMED invite
--     (event_invites.status IN ('accepted','attended')). A PENDING invitee is
--     NOT an attendee (2026-09-09 security fix): they may only accept or
--     decline, cannot mint a code, and can never be confirmed by a scan.
--   * event_code_keys(event_id, user_id, secret) — ONE long-lived random
--     32-byte secret per (event, attendee), issued lazily on first fetch
--     inside the activation window. No per-window token rows accumulate; the
--     displayed code is a PURE FUNCTION of (secret, 30-s counter).
--   * event_code(secret, counter) — immutable helper:
--         left(hex(hmac_sha256("samay.code.v1:<counter>", secret)), 24)
--     Domain-separated per the crypto policy (approved: HMAC-SHA256). Codes
--     are 24 lowercase hex = 96 bits, unguessable, carry NO identity.
--   * get_my_code(p_event_id) — attendee-side issue. Gates: activation window
--     (qr.activation_minutes_before) + host/staff/CONFIRMED-invite membership.
--     Issues the secret on first call; returns {code, secret, counter,
--     windowSeconds, windowStart, windowEnd, serverNowMs} for the CURRENT 30-s
--     window. `serverNowMs` is the server's own UTC epoch milliseconds at
--     issue, and is STABLE within the transaction (now() is transaction-time),
--     so it is consistent with `counter`. The device anchors its (possibly
--     skewed) wall clock to it and derives every later window on the server's
--     lattice. The secret is returned so the
--     device derives codes LOCALLY (offline, seamless regeneration) — it is
--     never logged, never persisted by the app, and is scoped to one
--     (event, user).
--   * validate_code(p_event_id, p_code) — host/staff-only, recomputes
--     every attendee secret's code for counter ± 1 (clock-skew tolerance) and
--     confirms the match ONCE: event_attendances is the single-confirmation
--     marker (event_invites flips to attended for guests). Statuses:
--       not_host / not_in_window / invalid_code / not_invited /
--       already_scanned / confirmed.
--     A 30-s window code is deliberately replayable for its lifetime (like an
--     authenticator code) but only ONE confirmation lands — re-scans in the
--     same or later windows answer already_scanned.
--   * event_code_keys has FORCE RLS and NO policies: no client can read a
--     secret through PostgREST (the only handle is the SECURITY DEFINER RPC).
--     Row cleanup: when an invite row is deleted (declined, or converted to a
--     staff seat) or a staff row is removed, the code key is purged by
--     triggers so a revoked attendee's code dies instantly. Purge on guest→
--     staff conversion is a benign forced refresh (the screen re-fetches).
--   * The scan/decode side (reading the pattern from the camera) is Stage 5.
--     This file only pins the code the attendee display must encode and the
--     authoritative server validation.
--
-- Config: code.window_seconds (seed 10) is added in seed-config.sql; the
-- activation window reuses qr.activation_minutes_before (seed 30).

-- ======================================================================
-- event_code_keys — per-(event, attendee) HMAC secret
-- ======================================================================
CREATE TABLE public.event_code_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_id uuid NOT NULL,
    user_id uuid NOT NULL,
    secret text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT event_code_keys_pkey PRIMARY KEY (id),
    CONSTRAINT event_code_keys_event_id_user_id_key UNIQUE (event_id, user_id),
    CONSTRAINT event_code_keys_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.events(id) ON DELETE CASCADE,
    CONSTRAINT event_code_keys_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE,
    CONSTRAINT event_code_keys_secret_hex CHECK ((secret ~ '^[0-9a-f]{64}$'))
);

CREATE INDEX idx_event_code_keys_event ON public.event_code_keys USING btree (event_id);
CREATE INDEX idx_event_code_keys_user ON public.event_code_keys USING btree (user_id);

ALTER TABLE ONLY public.event_code_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE ONLY public.event_code_keys FORCE ROW LEVEL SECURITY;
-- NO policies by design: clients cannot read/write secrets directly; the
-- only handle is the SECURITY DEFINER RPC family below.

-- ======================================================================
-- event_code(text, bigint) — the code derivation (immutable helper)
--   code = left(hex(hmac_sha256("samay.code.v1:<counter>", secret)), 24)
-- Grant: service_role only (schema-test/opt cross-checking); never PUBLIC.
-- ======================================================================
CREATE FUNCTION public.event_code(p_secret text, p_counter bigint) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    SET search_path TO ''
    AS $$
    SELECT left(
        encode(extensions.hmac(
            convert_to('samay.code.v1:' || p_counter::text, 'UTF8'),
            decode(p_secret, 'hex'),
            'sha256'
        ), 'hex'),
        24
    );
$$;

-- ======================================================================
-- get_my_code(uuid) — attendee-side code issue
-- Returns jsonb:
--   ok {code, secret, counter, windowSeconds, windowStart, windowEnd,
--       serverNowMs} |
--   not_authenticated | not_in_window | not_invited
-- ======================================================================
CREATE FUNCTION public.get_my_code(p_event_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_window integer;
    v_activation_minutes integer;
    v_event RECORD;
    v_secret text;
    v_counter bigint;
    v_start bigint;
    -- ONE captured timestamp for the whole issue: counter, window bounds and
    -- serverNowMs all derive from it, so windowStart*1000 <= serverNowMs <
    -- windowEnd*1000 holds strictly (a second now() call could round across a
    -- boundary and leave the returned "server now" outside its own window).
    v_now_ms bigint := (extract(epoch FROM now()) * 1000)::bigint;
BEGIN
    IF v_me IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    SELECT COALESCE(
        (SELECT value::integer FROM public.app_config
         WHERE key = 'qr.activation_minutes_before'), 30
    ) INTO v_activation_minutes;
    SELECT COALESCE(
        (SELECT value::integer FROM public.app_config
         WHERE key = 'code.window_seconds'), 30
    ) INTO v_window;
    IF v_window < 5 THEN
        v_window := 30; -- degenerate config guard: codes must be time-bound
    END IF;

    -- Activation window (shared with the legacy QR surface): the code exists
    -- only from `starts_at - activation_minutes` until the event ends.
    SELECT * INTO v_event FROM public.events WHERE id = p_event_id;
    IF NOT FOUND OR v_event.status NOT IN ('upcoming', 'live')
       OR now() < v_event.starts_at - make_interval(mins => v_activation_minutes)
       OR (v_event.ends_at IS NOT NULL AND now() > v_event.ends_at) THEN
        RETURN jsonb_build_object('status', 'not_in_window');
    END IF;

    -- Attendee gate (mirrors 060_events/06_staff.sql): host, staff OR a
    -- CONFIRMED invite (accepted/attended; declined invites are deleted). A
    -- PENDING invitee is NOT an attendee — they may only accept/decline, never
    -- mint a code (2026-09-09 security fix).
    IF NOT EXISTS (
        SELECT 1 FROM public.event_hosts
        WHERE event_id = p_event_id AND user_id = v_me
    ) AND NOT EXISTS (
        SELECT 1 FROM public.event_invites
        WHERE event_id = p_event_id AND user_id = v_me
          AND (status = 'accepted' OR status = 'attended')
    ) THEN
        RETURN jsonb_build_object('status', 'not_invited');
    END IF;

    -- Serialize concurrent first-issues for the same (event, user).
    PERFORM pg_advisory_xact_lock(hashtext(p_event_id::text || v_me::text));

    -- Issue the long-lived secret on first access; reuse afterwards.
    SELECT secret INTO v_secret FROM public.event_code_keys
    WHERE event_id = p_event_id AND user_id = v_me;
    IF v_secret IS NULL THEN
        INSERT INTO public.event_code_keys (event_id, user_id, secret)
        VALUES (p_event_id, v_me, encode(extensions.gen_random_bytes(32), 'hex'))
        RETURNING secret INTO v_secret;
    END IF;

    -- Current time window (UTC epoch counter), all derived from the single
    -- captured `v_now_ms` so the returned serverNowMs is inside [v_start,
    -- v_start + v_window) by construction.
    v_counter := (v_now_ms / 1000) / v_window;
    v_start := v_counter * v_window;

    RETURN jsonb_build_object(
        'status', 'ok',
        'code', public.event_code(v_secret, v_counter),
        'secret', v_secret,
        'counter', v_counter,
        'windowSeconds', v_window,
        'windowStart', v_start,
        'windowEnd', v_start + v_window,
        'serverNowMs', v_now_ms
    );
END;
$$;

-- ======================================================================
-- validate_code(uuid, text) — host/staff authoritative validation
-- Recomputes each attendee secret's code for counter ± 1 and confirms the
-- match ONCE (event_attendances = single-confirmation marker; guests' invite
-- flips to attended). Returns jsonb:
--   confirmed {attendeeUserId, attendeeName, confirmedAt} |
--   not_host | not_in_window | invalid_code | not_invited | already_scanned
-- ======================================================================
CREATE FUNCTION public.validate_code(p_event_id uuid, p_code text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_me uuid := auth.uid();
    v_window integer;
    v_activation_minutes integer;
    v_event RECORD;
    v_uid uuid;
    v_name text;
    v_counter bigint;
BEGIN
    -- 1. Scanner-role gate (host/staff only).
    IF v_me IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.event_hosts
        WHERE event_id = p_event_id
          AND user_id = v_me
          AND role IN ('host', 'staff')
    ) THEN
        RETURN jsonb_build_object('status', 'not_host');
    END IF;

    -- 2. Activation-window gate.
    SELECT COALESCE(
        (SELECT value::integer FROM public.app_config
         WHERE key = 'qr.activation_minutes_before'), 30
    ) INTO v_activation_minutes;
    SELECT COALESCE(
        (SELECT value::integer FROM public.app_config
         WHERE key = 'code.window_seconds'), 30
    ) INTO v_window;
    IF v_window < 5 THEN
        v_window := 30;
    END IF;

    SELECT * INTO v_event FROM public.events WHERE id = p_event_id;
    IF NOT FOUND OR v_event.status NOT IN ('upcoming', 'live')
       OR now() < v_event.starts_at - make_interval(mins => v_activation_minutes)
       OR (v_event.ends_at IS NOT NULL AND now() > v_event.ends_at) THEN
        RETURN jsonb_build_object('status', 'not_in_window');
    END IF;

    -- 3. Shape gate: codes are exactly 24 lowercase hex digits.
    IF p_code !~ '^[0-9a-f]{24}$' THEN
        RETURN jsonb_build_object('status', 'invalid_code');
    END IF;

    -- 4. Find the attendee whose secret derives p_code in the current window
    --    or ±1 (authenticator clock-skew tolerance). Recomputing per-attendee
    --    is O(attendees × 3) HMACs — trivial at event capacities (≤1120) and
    --    keeps validation stateless (no code→user index to maintain).
    v_counter := floor(extract(epoch FROM now()) / v_window)::bigint;
    SELECT k.user_id INTO v_uid
    FROM public.event_code_keys k
    CROSS JOIN LATERAL generate_series(-1, 1) AS s(off)
    WHERE k.event_id = p_event_id
      AND p_code = public.event_code(k.secret, v_counter + s.off)
    ORDER BY abs(s.off), k.user_id
    LIMIT 1;

    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'invalid_code');
    END IF;

    -- 5. Lock the attendee's key row so concurrent scans of the SAME code
    --    serialize — only one lands as confirmed.
    PERFORM 1 FROM public.event_code_keys
    WHERE event_id = p_event_id AND user_id = v_uid
    FOR UPDATE;

    -- 6. Attendee still valid (host/staff or CONFIRMED invite)? A revoked
    --    attendee (declined invite / removed staff — keys purged) answers
    --    not_invited, and a PENDING invitee can never be confirmed by a scan
    --    (2026-09-09 security fix).
    IF NOT EXISTS (
        SELECT 1 FROM public.event_hosts
        WHERE event_id = p_event_id AND user_id = v_uid
    ) AND NOT EXISTS (
        SELECT 1 FROM public.event_invites
        WHERE event_id = p_event_id AND user_id = v_uid
          AND (status = 'accepted' OR status = 'attended')
    ) THEN
        RETURN jsonb_build_object('status', 'not_invited');
    END IF;

    -- 7. Single confirmation: event_attendances is the marker (hosts/staff
    --    have no invite row; the invite flip below is a no-op for them).
    IF EXISTS (
        SELECT 1 FROM public.event_attendances
        WHERE event_id = p_event_id AND user_id = v_uid
    ) THEN
        RETURN jsonb_build_object('status', 'already_scanned');
    END IF;

    -- 8. Atomic writes — one transaction.
    INSERT INTO public.event_attendances (event_id, user_id)
    VALUES (p_event_id, v_uid)
    ON CONFLICT (event_id, user_id) DO NOTHING;

    UPDATE public.event_invites
    SET status = 'attended',
        responded_at = COALESCE(responded_at, now())
    WHERE event_id = p_event_id AND user_id = v_uid;

    SELECT username INTO v_name FROM public.users WHERE id = v_uid;

    RETURN jsonb_build_object(
        'status', 'confirmed',
        'attendeeUserId', v_uid,
        'attendeeName', v_name,
        'confirmedAt', now()
    );
END;
$$;

-- ======================================================================
-- Key purge triggers — a revoked attendee's code dies instantly.
--   * event_invites row deleted (declined, or converted guest→staff seat):
--     purge the key. The guest→staff conversion purge is benign — the attendee
--     is re-issued a fresh secret on their next code fetch.
--   * event_hosts row deleted (remove_event_staff): purge the key. The host
--     row is never deleted.
-- SECURITY DEFINER so the purge runs as the owner (FORCE RLS tables).
-- ======================================================================
CREATE FUNCTION public.purge_event_code_key() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    DELETE FROM public.event_code_keys
    WHERE event_id = OLD.event_id AND user_id = OLD.user_id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER code_key_purge_on_invite_delete
    AFTER DELETE ON public.event_invites
    FOR EACH ROW EXECUTE FUNCTION public.purge_event_code_key();

CREATE TRIGGER code_key_purge_on_host_delete
    AFTER DELETE ON public.event_hosts
    FOR EACH ROW EXECUTE FUNCTION public.purge_event_code_key();

-- ======================================================================
-- ACLs — hardened posture (no PUBLIC; RPC EXECUTE restricted).
-- event_code_keys: ZERO client grants (secrets are RPC-only).
-- ======================================================================
REVOKE ALL ON FUNCTION public.event_code(p_secret text, p_counter bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.event_code(p_secret text, p_counter bigint) TO service_role;

REVOKE ALL ON FUNCTION public.get_my_code(p_event_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_my_code(p_event_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_my_code(p_event_id uuid) TO service_role;

REVOKE ALL ON FUNCTION public.validate_code(p_event_id uuid, p_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.validate_code(p_event_id uuid, p_code text) TO authenticated;
GRANT ALL ON FUNCTION public.validate_code(p_event_id uuid, p_code text) TO service_role;

REVOKE ALL ON TABLE public.event_code_keys FROM anon;
REVOKE ALL ON TABLE public.event_code_keys FROM authenticated;
REVOKE ALL ON TABLE public.event_code_keys FROM service_role;

REVOKE ALL ON FUNCTION public.purge_event_code_key() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_event_code_key() FROM authenticated;
REVOKE ALL ON FUNCTION public.purge_event_code_key() FROM service_role;
