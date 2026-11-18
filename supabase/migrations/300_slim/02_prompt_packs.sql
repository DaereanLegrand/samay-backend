-- ============================================================================
-- 300_slim/02_prompt_packs.sql — prompt packs (free + paid)
--
-- Slim-prod ships the prompt bank behind PACKS so the store (RevenueCat) can
-- sell extra content later without a schema change:
--   * prompt_packs — one row per sellable pack. tier_requirement is the
--     minimum subscription_tier (free < pro < vip); pack_version lets the
--     client invalidate a cached copy.
--   * minigame_prompts.pack_id — every prompt belongs to a pack; the base
--     packs are backfilled, so the legacy NULL rows disappear on upgrade.
--   * The prompt bank is NO LONGER client-readable. reveal_minigame_prompt()
--     is SECURITY DEFINER, so draws keep working while direct PostgREST
--     enumeration of the bank is closed (paid prompts must not leak).
--   * list_prompt_packs() lists the catalogue with a `locked` flag;
--     get_prompt_pack(uuid) returns the pack + prompts once the caller's tier
--     covers it.
--
-- Rollback: forward-fix only (dropping the packs would orphan paid content).
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Pack catalogue.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.prompt_packs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    game_type public.mini_game_type NOT NULL,
    name text NOT NULL,
    tier_requirement public.subscription_tier NOT NULL DEFAULT 'free',
    pack_version integer NOT NULL DEFAULT 1,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT prompt_packs_pkey PRIMARY KEY (id)
);

ALTER TABLE public.prompt_packs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prompt_packs FORCE ROW LEVEL SECURITY;

COMMENT ON TABLE public.prompt_packs IS
    'Sellable prompt packs (300_slim). tier_requirement gates access by subscription_tier rank; written by service_role/RevenueCat only.';
COMMENT ON COLUMN public.prompt_packs.tier_requirement IS
    'Minimum subscription_tier required to read the pack prompts: free < pro < vip.';
COMMENT ON COLUMN public.prompt_packs.pack_version IS
    'Bumped when the pack contents change so clients invalidate a cached copy.';

-- Only service_role writes the catalogue; reads go through the RPCs.
REVOKE ALL ON TABLE public.prompt_packs FROM anon, authenticated;
GRANT ALL ON TABLE public.prompt_packs TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Attach prompts to packs.
-- ---------------------------------------------------------------------------
ALTER TABLE public.minigame_prompts
    ADD COLUMN IF NOT EXISTS pack_id uuid
        REFERENCES public.prompt_packs(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.minigame_prompts.pack_id IS
    'Owning prompt pack (300_slim). NULL is a legacy/unsorted prompt; the seeds below attach every base prompt.';

-- ---------------------------------------------------------------------------
-- 3. Seed: one free base pack per game type (deterministic uuids).
-- ---------------------------------------------------------------------------
INSERT INTO public.prompt_packs (id, game_type, name, tier_requirement, pack_version, is_active)
VALUES
    ('c0000000-0000-4000-8000-000000000001', 'truth_dare', 'Paquete base', 'free', 1, true),
    ('c0000000-0000-4000-8000-000000000002', 'drunk_bottle', 'Paquete base', 'free', 1, true),
    ('c0000000-0000-4000-8000-000000000003', 'two_lies_one_truth', 'Paquete base', 'free', 1, true),
    ('c0000000-0000-4000-8000-000000000004', 'charades', 'Paquete base', 'free', 1, true)
ON CONFLICT (id) DO NOTHING;

-- Attach every still-unassigned prompt to its game's base pack.
UPDATE public.minigame_prompts
   SET pack_id = 'c0000000-0000-4000-8000-000000000001'
 WHERE pack_id IS NULL AND game_type = 'truth_dare';
UPDATE public.minigame_prompts
   SET pack_id = 'c0000000-0000-4000-8000-000000000002'
 WHERE pack_id IS NULL AND game_type = 'drunk_bottle';
UPDATE public.minigame_prompts
   SET pack_id = 'c0000000-0000-4000-8000-000000000003'
 WHERE pack_id IS NULL AND game_type = 'two_lies_one_truth';
UPDATE public.minigame_prompts
   SET pack_id = 'c0000000-0000-4000-8000-000000000004'
 WHERE pack_id IS NULL AND game_type = 'charades';

-- ---------------------------------------------------------------------------
-- 4. Seed: one paid extra pack per game type (no prompts yet — content is
--    pushed by RevenueCat/service_role when the store product ships).
-- ---------------------------------------------------------------------------
INSERT INTO public.prompt_packs (id, game_type, name, tier_requirement, pack_version, is_active)
VALUES
    ('d0000000-0000-4000-8000-000000000001', 'truth_dare', 'Paquete extra', 'pro', 1, true),
    ('d0000000-0000-4000-8000-000000000002', 'drunk_bottle', 'Paquete extra', 'pro', 1, true),
    ('d0000000-0000-4000-8000-000000000003', 'two_lies_one_truth', 'Paquete extra', 'pro', 1, true),
    ('d0000000-0000-4000-8000-000000000004', 'charades', 'Paquete extra', 'pro', 1, true)
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. Lock the prompt bank down to the RPCs (reveal_minigame_prompt is
--    SECURITY DEFINER, so draws keep working with no client table grants).
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS mgs_prompts_select ON public.minigame_prompts;

REVOKE ALL ON TABLE public.minigame_prompts FROM authenticated, anon;
GRANT ALL ON TABLE public.minigame_prompts TO service_role;

-- ---------------------------------------------------------------------------
-- 6. list_prompt_packs() — the catalogue with a locked flag.
--    Auth required (raises for anon); no onboarding gate (the store is
--    browsable from the guest upsell screen). Returns the pack array directly;
--    locked = caller tier rank < requirement rank.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_prompt_packs() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
    v_tier public.subscription_tier;
    v_tier_rank integer;
    v_packs jsonb;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001';
    END IF;

    -- The catalogue is a post-onboarding surface: a guest that has not
    -- accepted 18+/terms has no profile row yet, so it cannot browse packs.
    IF NOT public.is_onboarded() THEN
        RAISE EXCEPTION 'Not onboarded' USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(subscription_tier, 'free'::public.subscription_tier)
      INTO v_tier
      FROM public.users
     WHERE id = v_uid;

    v_tier_rank := CASE COALESCE(v_tier, 'free'::public.subscription_tier)
        WHEN 'vip'::public.subscription_tier THEN 3
        WHEN 'pro'::public.subscription_tier THEN 2
        ELSE 1
    END;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', p.id,
               'game_type', p.game_type::text,
               'name', p.name,
               'tier_requirement', p.tier_requirement::text,
               'pack_version', p.pack_version,
               'prompt_count', (
                   SELECT count(*) FROM public.minigame_prompts mp
                   WHERE mp.pack_id = p.id AND mp.is_active
               ),
               'locked', v_tier_rank < CASE p.tier_requirement
                   WHEN 'vip'::public.subscription_tier THEN 3
                   WHEN 'pro'::public.subscription_tier THEN 2
                   ELSE 1
               END
           ) ORDER BY p.game_type, p.name, p.id), '[]'::jsonb)
      INTO v_packs
      FROM public.prompt_packs p
     WHERE p.is_active;

    RETURN v_packs;
END;
$$;

REVOKE ALL ON FUNCTION public.list_prompt_packs() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_prompt_packs() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. get_prompt_pack(uuid) — one pack + its prompts (auth + onboarded).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_prompt_pack(p_pack_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_uid uuid;
    v_pack public.prompt_packs;
    v_tier_rank integer;
    v_req_rank integer;
    v_prompts jsonb;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'not_authenticated');
    END IF;

    IF NOT public.is_onboarded() THEN
        RETURN jsonb_build_object('status', 'not_onboarded');
    END IF;

    SELECT * INTO v_pack
      FROM public.prompt_packs
     WHERE id = p_pack_id AND is_active;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'not_found');
    END IF;

    SELECT CASE COALESCE(subscription_tier, 'free'::public.subscription_tier)
               WHEN 'vip'::public.subscription_tier THEN 3
               WHEN 'pro'::public.subscription_tier THEN 2
               ELSE 1
           END
      INTO v_tier_rank
      FROM public.users
     WHERE id = v_uid;
    v_tier_rank := COALESCE(v_tier_rank, 1);

    v_req_rank := CASE v_pack.tier_requirement
        WHEN 'vip'::public.subscription_tier THEN 3
        WHEN 'pro'::public.subscription_tier THEN 2
        ELSE 1
    END;

    IF v_tier_rank < v_req_rank THEN
        RETURN jsonb_build_object('status', 'locked');
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', mp.id,
               'prompt_type', mp.prompt_type,
               'category', mp.category,
               'body', mp.body
           ) ORDER BY mp.id), '[]'::jsonb)
      INTO v_prompts
      FROM public.minigame_prompts mp
     WHERE mp.pack_id = v_pack.id AND mp.is_active;

    RETURN jsonb_build_object(
        'status', 'ok',
        'pack', jsonb_build_object(
            'id', v_pack.id,
            'game_type', v_pack.game_type::text,
            'name', v_pack.name,
            'tier_requirement', v_pack.tier_requirement::text,
            'pack_version', v_pack.pack_version,
            'prompt_count', jsonb_array_length(v_prompts)
        ),
        'prompts', v_prompts
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_prompt_pack(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_prompt_pack(uuid) TO authenticated, service_role;

COMMIT;
