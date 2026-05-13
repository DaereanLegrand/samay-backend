-- Drop display_name column from users table.
-- Username is the single display identifier going forward.
ALTER TABLE users DROP COLUMN IF EXISTS display_name;
