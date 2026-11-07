-- ============================================================================
-- 240_group_theme/01_group_theme.sql — E4 group theme (server remainder)
--
-- Owner decisions (14-wave2-decisions §3 E4 and §9):
--   * host-owned theme; default control `everyone` (any active member may
--     change the colours), the host may switch to `host_only` or `locked`;
--   * the HOST's effective tier gates the palette: free = fixed black
--     (free-hosted groups default `locked`), Pro/VIP = RGB; VIP textures later;
--   * static colours only, automatic AA-contrast foreground (black or white,
--     whichever is measurably better — always >= 4.58:1);
--   * 3 changes/min/group + 20/day/user;
--   * audit actor / old / new / control mode.
--
-- Applies to group chat, the member list and group minigames on the client.
-- Writes go through `set_group_theme` only: direct INSERT/UPDATE/DELETE on
-- `group_themes` is revoked and RLS has a read-only policy for active members.
--
-- Rollback: forward-fix only (the theme table is additive; dropping it would
-- require a new owner decision).
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Enum + table.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_type
                    WHERE typname = 'group_theme_mode'
                      AND typnamespace = 'public'::regnamespace) THEN
        CREATE TYPE public.group_theme_mode AS ENUM ('everyone', 'host_only', 'locked');
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.group_themes (
    group_id uuid PRIMARY KEY REFERENCES public.groups(id) ON DELETE CASCADE,
    control_mode public.group_theme_mode NOT NULL DEFAULT 'everyone',
    background_color text NOT NULL DEFAULT '#000000',
    accent_color text NOT NULL DEFAULT '#FFFFFF',
    foreground_color text NOT NULL DEFAULT '#FFFFFF',
    accent_foreground_color text NOT NULL DEFAULT '#000000',
    updated_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT group_themes_background_hex CHECK (background_color ~ '^#[0-9A-F]{6}$'),
    CONSTRAINT group_themes_accent_hex CHECK (accent_color ~ '^#[0-9A-F]{6}$')
);

ALTER TABLE ONLY public.group_themes FORCE ROW LEVEL SECURITY;
ALTER TABLE public.group_themes ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 2. WCAG helpers (static colours only; automatic foreground).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.theme_srgb_channel(p_value integer)
RETURNS numeric
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
    SELECT CASE
        WHEN (p_value::numeric / 255) <= 0.04045
            THEN (p_value::numeric / 255) / 12.92
        ELSE power(((p_value::numeric / 255) + 0.055) / 1.055, 2.4)
    END;
$$;

CREATE OR REPLACE FUNCTION public.theme_relative_luminance(p_hex text)
RETURNS numeric
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
    SELECT 0.2126 * public.theme_srgb_channel(('x' || substr(p_hex, 2, 2))::bit(8)::integer)
         + 0.7152 * public.theme_srgb_channel(('x' || substr(p_hex, 4, 2))::bit(8)::integer)
         + 0.0722 * public.theme_srgb_channel(('x' || substr(p_hex, 6, 2))::bit(8)::integer);
$$;

CREATE OR REPLACE FUNCTION public.theme_contrast_ratio(p_a text, p_b text)
RETURNS numeric
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
    SELECT (GREATEST(la, lb) + 0.05) / (LEAST(la, lb) + 0.05)
      FROM (SELECT public.theme_relative_luminance(upper(p_a)) AS la,
                   public.theme_relative_luminance(upper(p_b)) AS lb) s;
$$;

-- Black or white text, whichever contrasts more. For any background one of
-- the two is always >= 4.58:1 (WCAG AA for normal text) — so this derives an
-- accessible foreground automatically.
CREATE OR REPLACE FUNCTION public.theme_best_foreground(p_hex text)
RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
    SELECT CASE
        WHEN public.theme_contrast_ratio(p_hex, '#000000')
             >= public.theme_contrast_ratio(p_hex, '#FFFFFF')
            THEN '#000000'
        ELSE '#FFFFFF'
    END;
$$;

-- The app shell is dark: a group background is clamped to a dark relative
-- luminance so the existing white text (headers, chips, bubbles) stays
-- >= 4.5:1 everywhere. The hue is preserved; only lightness is reduced.
CREATE OR REPLACE FUNCTION public.theme_clamp_dark(p_hex text, p_max numeric DEFAULT 0.12)
RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO ''
    AS $$
DECLARE
    v_r integer := ('x' || substr(p_hex, 2, 2))::bit(8)::integer;
    v_g integer := ('x' || substr(p_hex, 4, 2))::bit(8)::integer;
    v_b integer := ('x' || substr(p_hex, 6, 2))::bit(8)::integer;
    v_hex text := upper(p_hex);
BEGIN
    IF p_max IS NULL OR p_max <= 0 THEN
        RETURN v_hex;
    END IF;
    FOR i IN 1..32 LOOP
        IF public.theme_relative_luminance(v_hex) <= p_max THEN
            RETURN v_hex;
        END IF;
        v_r := floor(v_r * 0.85)::integer;
        v_g := floor(v_g * 0.85)::integer;
        v_b := floor(v_b * 0.85)::integer;
        v_hex := '#' || upper(lpad(to_hex(v_r), 2, '0'))
                      || upper(lpad(to_hex(v_g), 2, '0'))
                      || upper(lpad(to_hex(v_b), 2, '0'));
    END LOOP;
    RETURN v_hex;
END;
$$;

REVOKE ALL ON FUNCTION public.theme_srgb_channel(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.theme_relative_luminance(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.theme_contrast_ratio(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.theme_best_foreground(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.theme_clamp_dark(text, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.theme_srgb_channel(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.theme_relative_luminance(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.theme_contrast_ratio(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.theme_best_foreground(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.theme_clamp_dark(text, numeric) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Default row lifecycle.
--   Free-hosted groups default `locked` + black; paid hosts default `everyone`.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.initialize_group_theme()
RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_mode public.group_theme_mode;
BEGIN
    v_mode := CASE
        WHEN COALESCE(public.effective_tier(NEW.created_by_user_id),
                      'free'::public.subscription_tier)
             = 'free'::public.subscription_tier
            THEN 'locked'::public.group_theme_mode
        ELSE 'everyone'::public.group_theme_mode
    END;

    INSERT INTO public.group_themes (group_id, control_mode)
    VALUES (NEW.id, v_mode)
    ON CONFLICT (group_id) DO NOTHING;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.initialize_group_theme() FROM PUBLIC;

DROP TRIGGER IF EXISTS groups_initialize_theme ON public.groups;
CREATE TRIGGER groups_initialize_theme
    AFTER INSERT ON public.groups
    FOR EACH ROW EXECUTE FUNCTION public.initialize_group_theme();

-- Backfill every existing group.
INSERT INTO public.group_themes (group_id, control_mode)
SELECT g.id,
       CASE
           WHEN COALESCE(public.effective_tier(g.created_by_user_id),
                         'free'::public.subscription_tier)
                = 'free'::public.subscription_tier
               THEN 'locked'::public.group_theme_mode
           ELSE 'everyone'::public.group_theme_mode
       END
  FROM public.groups g
ON CONFLICT (group_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. Audit table (actor / old / new / control mode).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.group_theme_changes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id uuid NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
    actor_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
    action text NOT NULL,
    old_background_color text,
    new_background_color text,
    old_accent_color text,
    new_accent_color text,
    old_control_mode public.group_theme_mode,
    new_control_mode public.group_theme_mode,
    created_at timestamp with time zone NOT NULL DEFAULT now()
);

ALTER TABLE ONLY public.group_theme_changes FORCE ROW LEVEL SECURITY;
ALTER TABLE public.group_theme_changes ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 5. The single write RPC.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_group_theme(
    p_group_id uuid,
    p_background_color text DEFAULT NULL,
    p_accent_color text DEFAULT NULL,
    p_control_mode text DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid := auth.uid();
    v_host uuid;
    v_is_host boolean;
    v_is_member boolean;
    v_theme public.group_themes%ROWTYPE;
    v_mode public.group_theme_mode;
    v_bg text := CASE WHEN p_background_color IS NULL THEN NULL
                      ELSE upper(btrim(p_background_color)) END;
    v_accent text := CASE WHEN p_accent_color IS NULL THEN NULL
                          ELSE upper(btrim(p_accent_color)) END;
    v_tier public.subscription_tier;
    v_fg text;
    v_accent_fg text;
    v_changed boolean := false;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'not_authenticated' USING ERRCODE = 'P0001';
    END IF;

    SELECT gm.user_id INTO v_host
      FROM public.group_members gm
     WHERE gm.group_id = p_group_id
       AND gm.role = 'host'
       AND gm.status = 'active'
     LIMIT 1;

    SELECT EXISTS (
        SELECT 1 FROM public.group_members gm
         WHERE gm.group_id = p_group_id
           AND gm.user_id = v_uid
           AND gm.status = 'active'
    ) INTO v_is_member;

    IF NOT v_is_member THEN
        RAISE EXCEPTION 'not_a_member' USING ERRCODE = 'P0001';
    END IF;
    v_is_host := (v_host = v_uid);

    INSERT INTO public.group_themes (group_id)
    VALUES (p_group_id)
    ON CONFLICT (group_id) DO NOTHING;

    SELECT * INTO v_theme
      FROM public.group_themes
     WHERE group_id = p_group_id
     FOR UPDATE;

    -- --- control mode (host only) ----------------------------------------
    IF p_control_mode IS NOT NULL THEN
        IF upper(btrim(p_control_mode)) NOT IN ('EVERYONE', 'HOST_ONLY', 'LOCKED') THEN
            RAISE EXCEPTION 'invalid_control_mode' USING ERRCODE = 'P0001';
        END IF;
        IF NOT v_is_host THEN
            RAISE EXCEPTION 'not_host' USING ERRCODE = 'P0001';
        END IF;
        v_mode := lower(btrim(p_control_mode))::public.group_theme_mode;
        IF v_mode <> v_theme.control_mode THEN
            v_changed := true;
        END IF;
    ELSE
        v_mode := v_theme.control_mode;
    END IF;

    -- --- colours ----------------------------------------------------------
    IF v_bg IS NOT NULL OR v_accent IS NOT NULL THEN
        IF v_bg IS NOT NULL AND v_bg !~ '^#[0-9A-F]{6}$' THEN
            RAISE EXCEPTION 'invalid_theme_color' USING ERRCODE = 'P0001';
        END IF;
        IF v_accent IS NOT NULL AND v_accent !~ '^#[0-9A-F]{6}$' THEN
            RAISE EXCEPTION 'invalid_theme_color' USING ERRCODE = 'P0001';
        END IF;
        v_bg := COALESCE(v_bg, v_theme.background_color);
        v_accent := COALESCE(v_accent, v_theme.accent_color);

        IF v_mode = 'locked'::public.group_theme_mode THEN
            RAISE EXCEPTION 'theme_locked' USING ERRCODE = 'P0001';
        END IF;
        IF v_mode = 'host_only'::public.group_theme_mode AND NOT v_is_host THEN
            RAISE EXCEPTION 'not_host' USING ERRCODE = 'P0001';
        END IF;

        -- The HOST's tier gates the palette (grandfathered themes survive).
        v_tier := COALESCE(public.effective_tier(v_host),
                           'free'::public.subscription_tier);
        IF v_tier = 'free'::public.subscription_tier
           AND (v_bg <> '#000000' OR v_accent <> '#FFFFFF') THEN
            RAISE EXCEPTION 'theme_requires_paid' USING ERRCODE = 'P0001';
        END IF;

        IF v_tier <> 'free'::public.subscription_tier THEN
            v_bg := public.theme_clamp_dark(v_bg);
        END IF;

        v_fg := public.theme_best_foreground(v_bg);
        v_accent_fg := public.theme_best_foreground(v_accent);
        IF public.theme_contrast_ratio(v_bg, v_fg) < 4.5
           OR public.theme_contrast_ratio(v_accent, v_accent_fg) < 4.5 THEN
            RAISE EXCEPTION 'theme_contrast' USING ERRCODE = 'P0001';
        END IF;
    ELSE
        v_bg := v_theme.background_color;
        v_accent := v_theme.accent_color;
        v_fg := v_theme.foreground_color;
        v_accent_fg := v_theme.accent_foreground_color;
    END IF;

    IF v_bg <> v_theme.background_color
       OR v_accent <> v_theme.accent_color THEN
        v_changed := true;
    END IF;

    IF NOT v_changed THEN
        RETURN jsonb_build_object(
            'status', 'ok',
            'group_id', p_group_id,
            'control_mode', v_mode,
            'background_color', v_theme.background_color,
            'accent_color', v_theme.accent_color,
            'foreground_color', v_theme.foreground_color,
            'accent_foreground_color', v_theme.accent_foreground_color);
    END IF;

    -- --- rate limits: 3/min/group + 20/day/user --------------------------
    PERFORM public.consume_action_limit(
        p_group_id, 'group_theme_group', '', 3, interval '1 minute');
    PERFORM public.consume_action_limit(
        v_uid, 'group_theme_user', '', 20, interval '1 day');

    UPDATE public.group_themes
       SET control_mode = v_mode,
           background_color = v_bg,
           accent_color = v_accent,
           foreground_color = v_fg,
           accent_foreground_color = v_accent_fg,
           updated_by = v_uid,
           updated_at = now()
     WHERE group_id = p_group_id;

    INSERT INTO public.group_theme_changes (
        group_id, actor_id, action,
        old_background_color, new_background_color,
        old_accent_color, new_accent_color,
        old_control_mode, new_control_mode)
    VALUES (
        p_group_id, v_uid, 'group_theme_update',
        v_theme.background_color, v_bg,
        v_theme.accent_color, v_accent,
        v_theme.control_mode, v_mode);

    RETURN jsonb_build_object(
        'status', 'ok',
        'group_id', p_group_id,
        'control_mode', v_mode,
        'background_color', v_bg,
        'accent_color', v_accent,
        'foreground_color', v_fg,
        'accent_foreground_color', v_accent_fg);
END;
$$;

REVOKE ALL ON FUNCTION public.set_group_theme(uuid, text, text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_group_theme(uuid, text, text, text)
    TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Read RPC: the theme + what the caller may do with it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_group_theme(p_group_id uuid)
RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid := auth.uid();
    v_host uuid;
    v_is_host boolean;
    v_is_member boolean;
    v_theme public.group_themes%ROWTYPE;
    v_tier public.subscription_tier;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'not_authenticated' USING ERRCODE = 'P0001';
    END IF;

    SELECT gm.user_id INTO v_host
      FROM public.group_members gm
     WHERE gm.group_id = p_group_id
       AND gm.role = 'host'
       AND gm.status = 'active'
     LIMIT 1;

    SELECT EXISTS (
        SELECT 1 FROM public.group_members gm
         WHERE gm.group_id = p_group_id
           AND gm.user_id = v_uid
           AND gm.status = 'active'
    ) INTO v_is_member;
    IF NOT v_is_member THEN
        RAISE EXCEPTION 'not_a_member' USING ERRCODE = 'P0001';
    END IF;
    v_is_host := (v_host = v_uid);
    v_tier := COALESCE(public.effective_tier(v_host),
                       'free'::public.subscription_tier);

    SELECT * INTO v_theme
      FROM public.group_themes
     WHERE group_id = p_group_id;

    IF NOT FOUND THEN
        v_theme.control_mode := CASE WHEN v_tier = 'free'
            THEN 'locked'::public.group_theme_mode
            ELSE 'everyone'::public.group_theme_mode END;
        v_theme.background_color := '#000000';
        v_theme.accent_color := '#FFFFFF';
        v_theme.foreground_color := '#FFFFFF';
        v_theme.accent_foreground_color := '#000000';
    END IF;

    RETURN jsonb_build_object(
        'group_id', p_group_id,
        'control_mode', v_theme.control_mode,
        'background_color', v_theme.background_color,
        'accent_color', v_theme.accent_color,
        'foreground_color', v_theme.foreground_color,
        'accent_foreground_color', v_theme.accent_foreground_color,
        'is_host', v_is_host,
        'palette_tier', v_tier,
        'palette', CASE WHEN v_tier = 'free'
            THEN jsonb_build_array('#000000')
            ELSE jsonb_build_array(
                '#000000', '#1E3A8A', '#14532D', '#4C1D95', '#7C2D12',
                '#0F766E', '#3F2D0B', '#1E293B', '#831843', '#164E63')
        END,
        'can_change_color',
            v_theme.control_mode <> 'locked'::public.group_theme_mode
            AND (v_theme.control_mode = 'everyone'::public.group_theme_mode
                 OR v_is_host),
        'can_change_control', v_is_host);
END;
$$;

REVOKE ALL ON FUNCTION public.get_group_theme(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_group_theme(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. RLS: active members read; no client writes.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS group_themes_read_member ON public.group_themes;
CREATE POLICY group_themes_read_member ON public.group_themes
    FOR SELECT TO authenticated
    USING (public.is_group_member(group_id));

DROP POLICY IF EXISTS active_users_only ON public.group_themes;
CREATE POLICY active_users_only ON public.group_themes
    AS RESTRICTIVE FOR ALL TO authenticated
    USING (public.is_active_user(auth.uid()))
    WITH CHECK (public.is_active_user(auth.uid()));

DROP POLICY IF EXISTS group_theme_changes_no_access ON public.group_theme_changes;
CREATE POLICY group_theme_changes_no_access ON public.group_theme_changes
    USING (false);

REVOKE ALL ON TABLE public.group_themes FROM anon, authenticated;
GRANT SELECT ON TABLE public.group_themes TO authenticated;
REVOKE ALL ON TABLE public.group_theme_changes FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. Config keys.
-- ---------------------------------------------------------------------------
INSERT INTO public.app_config (key, value, description, default_value) VALUES
    ('theme.changes_per_minute', '3',  'Max group theme changes per group per minute', '3'),
    ('theme.changes_per_day',    '20', 'Max group theme changes per user per day', '20')
ON CONFLICT (key) DO NOTHING;

COMMIT;
