-- Samay slim-production pgTAP tests — 300_slim forward-fix layer.
-- Same shape as schema_test.sql: BEGIN / plan(N) / ... / finish / ROLLBACK.
-- Covers onboarding, prompt packs, wager removal, leave-session and the
-- removed-feature ACLs.
--
-- pg_temp.q(text) evaluates a boolean query dynamically so a missing relation
-- or function reports a single failing assertion instead of aborting the
-- whole file (the RED run of this test runs before 300_slim is applied).
BEGIN;

SELECT plan(52);

CREATE FUNCTION pg_temp.q(p_sql text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_result boolean;
BEGIN
    EXECUTE p_sql INTO v_result;
    RETURN COALESCE(v_result, false);
EXCEPTION WHEN OTHERS THEN
        RETURN false;
END;
$$;

-- ============================================================
-- onboarding — users columns + RPCs (300_slim/01_onboarding.sql)
-- ============================================================
SELECT has_column('users', 'is_guest', 'users.is_guest exists');
SELECT col_not_null('users', 'is_guest', 'users.is_guest is NOT NULL');
SELECT col_default_is('users', 'is_guest', 'false', 'users.is_guest defaults to false');
SELECT has_column('users', 'age_confirmed_at', 'users.age_confirmed_at exists');
SELECT has_column('users', 'terms_accepted_at', 'users.terms_accepted_at exists');
SELECT has_column('users', 'terms_version', 'users.terms_version exists');

SELECT has_function('public', 'is_onboarded', ARRAY[]::text[],
    'is_onboarded() exists');
SELECT has_function('public', 'bootstrap_profile', ARRAY['text'],
    'bootstrap_profile(p_terms_version text) exists');
SELECT has_function('public', 'confirm_my_account', ARRAY[]::text[],
    'confirm_my_account() exists');

SELECT is_definer('public', 'is_onboarded', ARRAY[]::text[],
    'is_onboarded is SECURITY DEFINER');
SELECT is_definer('public', 'bootstrap_profile', ARRAY['text']::name[],
    'bootstrap_profile is SECURITY DEFINER');
SELECT is_definer('public', 'confirm_my_account', ARRAY[]::text[],
    'confirm_my_account is SECURITY DEFINER');

SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'bootstrap_profile'),
    'bootstrap_profile sets search_path = ''''');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'is_onboarded'),
    'is_onboarded sets search_path = ''''');

SELECT function_privs_are('public', 'bootstrap_profile', ARRAY['text']::name[],
    'authenticated', ARRAY['EXECUTE'],
    'bootstrap_profile is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'bootstrap_profile', ARRAY['text']::name[],
    'anon', ARRAY[]::name[],
    'bootstrap_profile is not anon-EXECUTABLE');
SELECT function_privs_are('public', 'is_onboarded', ARRAY[]::text[]::name[],
    'authenticated', ARRAY['EXECUTE'],
    'is_onboarded is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'confirm_my_account', ARRAY[]::text[]::name[],
    'authenticated', ARRAY['EXECUTE'],
    'confirm_my_account is authenticated-EXECUTABLE');

-- ============================================================
-- prompt packs (300_slim/02_prompt_packs.sql)
-- ============================================================
SELECT has_table('prompt_packs', 'prompt_packs exists');
SELECT has_column('minigame_prompts', 'pack_id',
    'minigame_prompts.pack_id exists');
SELECT has_function('public', 'list_prompt_packs', ARRAY[]::text[],
    'list_prompt_packs() exists');
SELECT has_function('public', 'get_prompt_pack', ARRAY['uuid'],
    'get_prompt_pack(p_pack_id uuid) exists');

SELECT ok(
    pg_temp.q('SELECT count(*) = 8 FROM public.prompt_packs WHERE is_active'),
    'prompt_packs is seeded with 8 active packs');
SELECT ok(
    pg_temp.q($q$SELECT count(*) = 4 AND bool_and(tier_requirement = 'free')
                FROM public.prompt_packs WHERE name = 'Paquete base'$q$),
    'four free base packs are seeded (one per game type)');
SELECT ok(
    pg_temp.q($q$SELECT count(*) = 4 AND bool_and(tier_requirement = 'pro')
                FROM public.prompt_packs WHERE name = 'Paquete extra'$q$),
    'four paid extra packs are seeded (tier pro)');
SELECT ok(
    pg_temp.q($q$SELECT count(*) = 4 FROM public.prompt_packs
                WHERE id::text LIKE 'c0000000-0000-4000-8000-%'$q$),
    'free packs use the deterministic c0000000… uuids');
SELECT ok(
    pg_temp.q($q$SELECT count(*) = 0 FROM public.minigame_prompts
                WHERE game_type IN ('truth_dare', 'drunk_bottle',
                                    'two_lies_one_truth', 'charades')
                  AND pack_id IS NULL$q$),
    'every seeded prompt is attached to its free pack');

SELECT ok(
    pg_temp.q($q$SELECT NOT has_table_privilege(
                    'authenticated', 'public.minigame_prompts', 'SELECT')$q$),
    'authenticated cannot SELECT minigame_prompts');
SELECT ok(
    pg_temp.q($q$SELECT NOT has_table_privilege(
                    'authenticated', 'public.minigame_prompts', 'INSERT')$q$),
    'authenticated cannot INSERT minigame_prompts');
SELECT ok(
    pg_temp.q($q$SELECT NOT has_table_privilege(
                    'anon', 'public.minigame_prompts', 'SELECT')$q$),
    'anon cannot SELECT minigame_prompts');
SELECT ok(
    pg_temp.q($q$SELECT has_table_privilege(
                    'service_role', 'public.minigame_prompts', 'SELECT')$q$),
    'service_role keeps SELECT on minigame_prompts');
SELECT ok(
    pg_temp.q($q$SELECT NOT has_table_privilege(
                    'authenticated', 'public.prompt_packs', 'SELECT')$q$),
    'authenticated has no direct SELECT on prompt_packs');
SELECT ok(
    pg_temp.q($q$SELECT has_table_privilege(
                    'service_role', 'public.prompt_packs', 'SELECT')$q$),
    'service_role keeps SELECT on prompt_packs');
SELECT function_privs_are('public', 'list_prompt_packs', ARRAY[]::text[]::name[],
    'authenticated', ARRAY['EXECUTE'],
    'list_prompt_packs is authenticated-EXECUTABLE');
SELECT function_privs_are('public', 'get_prompt_pack', ARRAY['uuid']::name[],
    'authenticated', ARRAY['EXECUTE'],
    'get_prompt_pack is authenticated-EXECUTABLE');

-- ============================================================
-- wager removal (300_slim/03_remove_wagers.sql)
-- ============================================================
SELECT has_function('public', 'create_minigame_session',
    ARRAY['uuid', 'text', 'uuid[]', 'text', 'integer', 'integer', 'text',
          'boolean', 'integer', 'timestamp with time zone'],
    'create_minigame_session has the wager-free 10-argument signature');
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'create_minigame_session'
          AND 'p_wager' = ANY (proargnames)
    ),
    'no create_minigame_session overload takes p_wager');
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'create_minigame_session' AND pronargs = 11
    ),
    'the 11-argument wager overload is dropped');
SELECT function_privs_are('public', 'create_minigame_session',
    ARRAY['uuid', 'text', 'uuid[]', 'text', 'integer', 'integer', 'text',
          'boolean', 'integer', 'timestamp with time zone']::name[],
    'authenticated', ARRAY['EXECUTE'],
    'create_minigame_session is authenticated-EXECUTABLE');
SELECT ok(
    pg_temp.q($q$SELECT NOT has_function_privilege('anon',
        'public.create_minigame_session(uuid,text,uuid[],text,integer,integer,text,boolean,integer,timestamp with time zone)',
        'EXECUTE')$q$),
    'create_minigame_session is not anon-EXECUTABLE');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) LIKE '%not_onboarded%'
     FROM pg_proc p WHERE p.proname = 'create_minigame_session'),
    'create_minigame_session gates on onboarding (not_onboarded)');
SELECT ok(
    (SELECT pg_get_functiondef(p.oid) NOT LIKE '%minigame_wager%'
       AND pg_get_functiondef(p.oid) NOT LIKE '%personal_shards%'
     FROM pg_proc p WHERE p.proname = 'create_minigame_session'),
    'create_minigame_session writes no wager/ledger/escrow');

-- ============================================================
-- leave session (300_slim/04_leave_session.sql)
-- ============================================================
SELECT has_function('public', 'leave_minigame_session', ARRAY['uuid'],
    'leave_minigame_session(p_session_id uuid) exists');
SELECT is_definer('public', 'leave_minigame_session', ARRAY['uuid']::name[],
    'leave_minigame_session is SECURITY DEFINER');
SELECT ok(
    (SELECT 'search_path=""' = ANY (proconfig)
     FROM pg_proc WHERE proname = 'leave_minigame_session'),
    'leave_minigame_session sets search_path = ''''');
SELECT function_privs_are('public', 'leave_minigame_session',
    ARRAY['uuid']::name[], 'authenticated', ARRAY['EXECUTE'],
    'leave_minigame_session is authenticated-EXECUTABLE');

-- ============================================================
-- removed-feature ACLs (300_slim/05_revoke_removed.sql)
-- ============================================================
SELECT ok(
    pg_temp.q($q$SELECT NOT has_table_privilege(
                    'authenticated', 'public.events', 'SELECT')$q$),
    'authenticated cannot read events');
SELECT ok(
    pg_temp.q($q$SELECT NOT has_table_privilege(
                    'authenticated', 'public.chats', 'SELECT')$q$),
    'authenticated cannot read chats');
SELECT ok(
    pg_temp.q($q$SELECT NOT has_table_privilege(
                    'authenticated', 'public.shard_ledger', 'SELECT')$q$),
    'authenticated cannot read shard_ledger');
SELECT ok(
    pg_temp.q($q$SELECT NOT has_table_privilege(
                    'anon', 'public.events', 'SELECT')$q$),
    'anon cannot read events');
SELECT ok(
    pg_temp.q($q$SELECT NOT has_table_privilege(
                    'authenticated', 'public.discovery_view', 'SELECT')$q$),
    'authenticated cannot read discovery_view');
SELECT ok(
    pg_temp.q($q$SELECT NOT has_table_privilege(
                    'authenticated', 'public.user_cosmetics', 'SELECT')$q$),
    'authenticated cannot read user_cosmetics');

SELECT * FROM finish();
ROLLBACK;
