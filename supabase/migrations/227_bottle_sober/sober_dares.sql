-- Samay — 227_bottle_sober/sober_dares.sql
--
-- Removes the alcohol-drinking dares from the Botella (drunk_bottle) prompt
-- bank. The "castigo" arm used to instruct players to DRINK ("Si nadie se ríe,
-- tomas", "Tomas. No hay reto, no hay salida", "…elige quién toma…", "Todos
-- toman menos tú"). Google Play (Age-Restricted / content-rating accuracy) and
-- Apple 1.4.3 ("apps that encourage consumption of … excessive amounts of
-- alcohol are not permitted") both flag this class. The prompts are rephrased
-- to a generic, venue-neutral penalty ("castigo") so the alcohol profile drops
-- to a plain REFERENCE (bar/club event venues, party vocabulary), not USE.
--
-- The category name stays 'castigo' (punishment) — no drinking language.
-- 210_minigame_bottle_pizza/pizza.sql is left untouched (applied migration);
-- this corrective migration updates its seeded rows on fresh and existing DBs.
-- ======================================================================

UPDATE public.minigame_prompts
   SET body = 'Cuenta un chiste. Si nadie se ríe, cumples un castigo.'
 WHERE game_type = 'drunk_bottle'
   AND body = 'Cuenta un chiste. Si nadie se ríe, tomas.';

UPDATE public.minigame_prompts
   SET body = 'Di el nombre completo de todos los que están aquí. Si fallas uno, cumples un castigo.'
 WHERE game_type = 'drunk_bottle'
   AND body = 'Di el nombre completo de todos los que están aquí. Si fallas uno, tomas.';

UPDATE public.minigame_prompts
   SET body = 'Castigo: no hay reto, no hay salida.'
 WHERE game_type = 'drunk_bottle'
   AND body = 'Tomas. No hay reto, no hay salida.';

UPDATE public.minigame_prompts
   SET body = 'Tú repartes: elige quién cumple el castigo en esta ronda.'
 WHERE game_type = 'drunk_bottle'
   AND body = 'Tú repartes: elige quién toma en esta ronda.';

UPDATE public.minigame_prompts
   SET body = 'Todos cumplen un castigo menos tú. Disfrútalo.'
 WHERE game_type = 'drunk_bottle'
   AND body = 'Todos toman menos tú. Disfrútalo.';
