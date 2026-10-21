-- ============================================================================
-- 231_wave1_hardening / 05_device_tokens.sql — SEC-020
--
-- Device tokens may not be re-homed to another user, are format-validated,
-- and are capped at 10 per user. A token already owned by the caller is only
-- touched (last_seen/platform); an unknown token owned by somebody else is
-- rejected. Registration stays a SECURITY DEFINER RPC; the table keeps its
-- SELECT-own policy and no client DML grant.
--
-- Constraints are NOT VALID so the migration never fails on legacy rows; new
-- writes are enforced immediately (the RPC validates before INSERT).
--
-- Rollback: DROP the two device_tokens_token_* constraints and restore the
-- 223 upsert-on-conflict register_device_token() body. Forward-fix: replace
-- the RPC; never restore cross-user re-homing.
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'device_tokens_token_length'
    ) THEN
        ALTER TABLE public.device_tokens
            ADD CONSTRAINT device_tokens_token_length
            CHECK (char_length(token) BETWEEN 20 AND 4096) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'device_tokens_token_charset'
    ) THEN
        ALTER TABLE public.device_tokens
            ADD CONSTRAINT device_tokens_token_charset
            CHECK (token ~ '^[A-Za-z0-9_:.-]+$') NOT VALID;
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.register_device_token(
    p_token text,
    p_platform text
) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
    v_owner uuid;
    v_count integer;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = 'P0001';
    END IF;
    IF p_token IS NULL OR btrim(p_token) = '' THEN
        RAISE EXCEPTION 'Token requerido.' USING ERRCODE = 'P0001';
    END IF;
    IF p_platform IS NULL OR p_platform NOT IN ('android', 'ios') THEN
        RAISE EXCEPTION 'Plataforma inválida.' USING ERRCODE = 'P0001';
    END IF;
    IF char_length(p_token) < 20
       OR char_length(p_token) > 4096
       OR p_token !~ '^[A-Za-z0-9_:.-]+$' THEN
        RAISE EXCEPTION 'Token inválido.' USING ERRCODE = 'P0001';
    END IF;

    SELECT user_id INTO v_owner
      FROM public.device_tokens
     WHERE token = p_token
       FOR UPDATE;

    IF FOUND THEN
        IF v_owner <> v_uid THEN
            RAISE EXCEPTION 'token_owned_by_another_user' USING ERRCODE = 'P0001';
        END IF;
        UPDATE public.device_tokens
           SET platform = p_platform,
               last_seen_at = now()
         WHERE token = p_token
           AND user_id = v_uid;
        RETURN;
    END IF;

    SELECT count(*) INTO v_count
      FROM public.device_tokens
     WHERE user_id = v_uid;
    IF v_count >= 10 THEN
        RAISE EXCEPTION 'token_limit_reached' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO public.device_tokens (user_id, token, platform, last_seen_at)
    VALUES (v_uid, p_token, p_platform, now());
END;
$$;

CREATE OR REPLACE FUNCTION public.unregister_device_token(p_token text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = 'P0001';
    END IF;
    IF p_token IS NULL OR btrim(p_token) = '' THEN
        RETURN;
    END IF;

    DELETE FROM public.device_tokens
    WHERE token = p_token AND user_id = v_uid;
END;
$$;

REVOKE ALL ON FUNCTION public.register_device_token(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.unregister_device_token(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_device_token(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unregister_device_token(text) TO authenticated;
