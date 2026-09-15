-- ======================================================================
-- Charadas (212_minigame_charades) — step 1: the game type.
--
-- ALTER TYPE ... ADD VALUE cannot be used in the SAME transaction that adds
-- it, so the enum lands in its own migration file and 02_charades.sql (a
-- separate psql run) is free to reference 'charades' in seeds and RPCs.
-- ======================================================================

ALTER TYPE public.mini_game_type ADD VALUE IF NOT EXISTS 'charades';
