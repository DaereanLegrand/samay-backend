-- Samay E2EE chat — prekey bundle storage + atomic fetch RPC (agent I-38)
--
-- Reference: docs/security/E2EE-ARCHITECTURE.md §5 (X3DH prekeys), §9.3
-- (server model). Companion Dart: lib/crypto/e2ee_prekey_service.dart.
--
-- Consolidation vs E2EE-ARCHITECTURE.md §9.1 (documented deviation, S-07
-- audit input): the three spec tables (user_devices, signed_prekeys,
-- one_time_prekeys) are merged into ONE per-user row `e2ee_identity_keys`:
-- identity + signed prekey are scalars, one-time prekeys live in a jsonb
-- array (public keys only — private keys NEVER leave the device). The
-- one-time prekey is consumed atomically inside `fetch_prekey_bundle`
-- (FOR UPDATE + array pop) and moved to `consumed_one_time_prekeys`
-- (kept for audit/reporting; a clean-up cron can prune it later).
--
-- Two extra columns vs the task brief (also S-07 audit inputs):
--   * identity_sig_key  — Ed25519 public key; the X3DH initiator MUST verify
--     Sig(IK_sig_B, SPKB) (R1 §3.3) and the AD_base (§6.1) needs both
--     identity keys of each party.
--   * signed_prekey_id  — the init envelope (§6.3) carries spk_id so the
--     responder can load the matching private key (§5.4); without it the
--     crypto core (lib/crypto/session.dart) cannot process init messages.

-- ============================================================
-- 1. Table — one row per user, public keys only
-- ============================================================
CREATE TABLE public.e2ee_identity_keys (
    user_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    identity_key text NOT NULL,                 -- X25519 identity public, base64url
    identity_sig_key text NOT NULL,             -- Ed25519 signing public, base64url
    signed_prekey_id integer NOT NULL,          -- spk_id carried by init envelopes
    signed_prekey text NOT NULL,                -- X25519 signed prekey public, base64url
    signed_prekey_sig text NOT NULL,            -- Ed25519 sig over signed_prekey, base64url
    signed_prekey_expires_at timestamptz NOT NULL,
    one_time_prekeys jsonb NOT NULL DEFAULT '[]',      -- [{id, key}, ...] public keys
    consumed_one_time_prekeys jsonb NOT NULL DEFAULT '[]', -- consumed marker (audit)
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Explicit index on user_id (the PK already provides one; kept for clarity
-- of intent and for the pgTAP assertion in Section 41).
CREATE INDEX e2ee_identity_keys_user_id_idx ON public.e2ee_identity_keys (user_id);

-- ============================================================
-- 2. RLS — own-row only (uid-scoped, signup_tracker pattern)
-- ============================================================
ALTER TABLE public.e2ee_identity_keys ENABLE ROW LEVEL SECURITY;

CREATE POLICY "e2ee_identity_keys_select_own" ON public.e2ee_identity_keys
    FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "e2ee_identity_keys_insert_own" ON public.e2ee_identity_keys
    FOR INSERT WITH CHECK (user_id = auth.uid());

CREATE POLICY "e2ee_identity_keys_update_own" ON public.e2ee_identity_keys
    FOR UPDATE USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "e2ee_identity_keys_delete_own" ON public.e2ee_identity_keys
    FOR DELETE USING (user_id = auth.uid());

-- FORCE RLS (I-31 pattern): even the table owner must obey policies.
ALTER TABLE public.e2ee_identity_keys FORCE ROW LEVEL SECURITY;

-- ============================================================
-- 3. SECURITY DEFINER RPC — atomic bundle fetch + OPK consumption
-- ============================================================
-- The one-time prekey is popped atomically: the row is locked with
-- FOR UPDATE SKIP LOCKED, the first OPK moves from one_time_prekeys to
-- consumed_one_time_prekeys, and the bundle is returned in the same
-- statement — concurrent callers serialize (or skip a locked row and
-- receive NULL), so an OPK can never be served twice (§5.4 FS guarantee).
--
-- RATE LIMIT NOTE (E2EE-ARCHITECTURE.md §5.5): the spec asks for
-- 10 fetches/hour per caller via a prekey_fetch_log counter to prevent
-- OPK draining. Deliberately deferred to S-10 (rate limiting audit) —
-- the JSONB-payload call path needs the caller identity for the counter
-- and a log table + prune step; the FOR UPDATE serialization above
-- already prevents the only *integrity* violation.
CREATE OR REPLACE FUNCTION public.fetch_prekey_bundle(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_row public.e2ee_identity_keys%ROWTYPE;
    v_remaining jsonb;
    v_next jsonb;
BEGIN
    SELECT * INTO v_row
    FROM public.e2ee_identity_keys
    WHERE user_id = p_user_id
    FOR UPDATE SKIP LOCKED;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    v_remaining := v_row.one_time_prekeys;
    v_next := NULL;
    IF jsonb_typeof(v_remaining) = 'array' AND jsonb_array_length(v_remaining) > 0 THEN
        v_next := v_remaining -> 0;
        v_remaining := v_remaining - 0;
        UPDATE public.e2ee_identity_keys
        SET one_time_prekeys = v_remaining,
            consumed_one_time_prekeys =
                COALESCE(v_row.consumed_one_time_prekeys, '[]'::jsonb)
                || jsonb_build_array(v_next),
            updated_at = now()
        WHERE user_id = p_user_id;
    END IF;

    RETURN jsonb_build_object(
        'user_id', v_row.user_id,
        'identity_key', v_row.identity_key,
        'identity_sig_key', v_row.identity_sig_key,
        'signed_prekey_id', v_row.signed_prekey_id,
        'signed_prekey', v_row.signed_prekey,
        'signed_prekey_sig', v_row.signed_prekey_sig,
        'signed_prekey_expires_at', v_row.signed_prekey_expires_at,
        'one_time_prekey', v_next
    );
END;
$$;

REVOKE ALL ON FUNCTION public.fetch_prekey_bundle(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fetch_prekey_bundle(uuid) TO authenticated;
