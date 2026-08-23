-- Samay baseline — 010_infra/01_extensions.sql
-- Platform extensions required by the app schema, pinned to their canonical
-- schemas (must match the image init + the dump's qualified references:
-- triggers call extensions.moddatetime()). Idempotent by design.
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS moddatetime WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron;
