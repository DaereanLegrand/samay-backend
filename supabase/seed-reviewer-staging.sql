-- Samay — seed-reviewer-staging.sql
-- STAGING ONLY. Creates the store-reviewer account (auth.users +
-- auth.identities + public.users) with a password supplied at run time.
--
-- Run through tools/seed-reviewer.sh: it requires SAMAY_ENV=staging and
-- REVIEWER_PASSWORD, passes them as psql variables, and never echoes the
-- password. The default seed-config.sql deliberately contains no users.
--
-- Idempotent: every INSERT is ON CONFLICT DO NOTHING, so a second run leaves
-- the existing bcrypt hash untouched (rotation is a separate, explicit action).
-- Triggers are suppressed (replica role) exactly like the old seed block.
\set ON_ERROR_STOP on

\if :{?samay_env}
\else
\echo 'refusing: SAMAY_ENV is not set (run tools/seed-reviewer.sh)'
\quit
\endif

\if :{?reviewer_password}
\else
\echo 'refusing: REVIEWER_PASSWORD is not set (run tools/seed-reviewer.sh)'
\quit
\endif

SELECT (:'samay_env' = 'staging') AS samay_env_ok \gset
\if :samay_env_ok
\else
\echo 'refusing: reviewer seed is staging-only (SAMAY_ENV must equal staging)'
\quit
\endif

BEGIN;
SET LOCAL session_replication_role = replica;

INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, invited_at, confirmation_token, confirmation_sent_at, recovery_token, recovery_sent_at, email_change_token_new, email_change, email_change_sent_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data, is_super_admin, created_at, updated_at, phone, phone_confirmed_at, phone_change, phone_change_token, phone_change_sent_at, email_change_token_current, email_change_confirm_status, banned_until, reauthentication_token, reauthentication_sent_at, is_sso_user, deleted_at, is_anonymous)
VALUES ('00000000-0000-0000-0000-000000000000', '197930fc-c5d3-4ab1-9601-21d3999a36b5', 'authenticated', 'authenticated', 'tester@qallariy.lat', extensions.crypt(:'reviewer_password', extensions.gen_salt('bf', 10)), '2026-10-18 05:25:21.457661+00', NULL, '', NULL, '', NULL, '', '', NULL, NULL, '{"provider": "email", "providers": ["email"]}', '{"sub": "197930fc-c5d3-4ab1-9601-21d3999a36b5", "email": "tester@qallariy.lat", "email_verified": true, "phone_verified": false}', NULL, '2026-10-18 05:24:12.59166+00', '2026-10-18 05:25:22.3405+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at, id)
VALUES ('197930fc-c5d3-4ab1-9601-21d3999a36b5', '197930fc-c5d3-4ab1-9601-21d3999a36b5', '{"sub": "197930fc-c5d3-4ab1-9601-21d3999a36b5", "email": "tester@qallariy.lat", "email_verified": true, "phone_verified": false}', 'email', NULL, '2026-10-18 05:24:12.596404+00', '2026-10-18 05:24:12.596404+00', '6ead7142-a0cf-4675-9cd5-2193cc1a406e')
ON CONFLICT DO NOTHING;

INSERT INTO public.users (id, username, avatar_url, date_of_birth, bio, banned_at, ban_reason, deleted_at, personal_shards, preshards, subscription_tier, subscription_expires_at, notification_preferences, created_at, updated_at, interest_tags, discovery_opt_in, read_receipts_enabled, profile_public, minigame_invite_friends_only, deletion_previous_username)
VALUES ('197930fc-c5d3-4ab1-9601-21d3999a36b5', 'tester', NULL, '2008-10-02', NULL, NULL, NULL, NULL, 256, 0, 'free', NULL, '{}', '2026-10-18 05:25:47.898474+00', '2026-10-18 05:25:47.898474+00', '{}', false, true, false, false, NULL)
ON CONFLICT (id) DO NOTHING;

COMMIT;
