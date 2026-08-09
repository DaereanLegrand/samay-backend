-- Samay — Seed Data
-- SINGLE SOURCE OF TRUTH for seed data (SUP-04, agent I-33).
-- The admin_users + app_config INSERTs were removed from
-- migrations/20260510000001_full_schema.sql §7 — never re-add them there.
-- Applied after migrations by `supabase db reset` (config.toml [db.seed]
-- sql_paths = ["./seed.sql"]), supabase/reset.sh and supabase/migrate.sh.
-- Idempotent: ON CONFLICT DO NOTHING (safe to re-run on an existing DB).

INSERT INTO admin_users (id, email, display_name, role)
VALUES ('00000000-0000-0000-0000-000000000000', 'system@qallariy.lat', 'system', 'super_admin')
ON CONFLICT (id) DO NOTHING;

INSERT INTO app_config (key, value, description, default_value) VALUES
    ('economy.user_signup_shards', '256', 'Shards granted to every new user on account creation', '256'),
    ('economy.feed_post_cost_shards', '25', 'Shards deducted when a PRO/VIP user posts to social feed', '25'),
    ('economy.preshards_free_monthly', '10', 'Preshards granted monthly to free tier users', '10'),
    ('economy.preshards_pro_monthly', '1000', 'Preshards granted monthly to PRO users', '1000'),
    ('economy.preshards_vip_monthly', '10000', 'Preshards granted monthly to VIP users', '10000'),
    ('economy.group_donation_min', '1', 'Minimum shards a user can donate to a group in one action', '1'),
    ('economy.group_shard_boost_days', '14', 'Days a group shard donation (boost) remains active before expiring', '14'),
    ('qr.activation_minutes_before', '30', 'Minutes before event start that attendance QR activates', '30'),
    ('qr.token_valid_seconds', '15', 'Server-side token validity window (seconds)', '15'),
    ('qr.display_countdown_seconds', '15', 'Countdown shown to user before QR visually refreshes', '15'),
    ('chat.message_cap', '1000', 'Max messages retained per chat (rolling window)', '1000'),
    ('events.free_daily_limit', '3', 'Max events a free user can create per day', '3'),
    ('events.pro_daily_limit', '10', 'Max events a PRO user can create per day', '10'),
    ('events.vip_daily_limit', '100', 'Max events a VIP user can create per day', '100'),
    ('events.photo_upload_window_hours', '24', 'Hours after event ends that photo upload is still allowed', '24'),
    ('events.collage_top_n_photos', '9', 'Number of top-liked photos included in the auto-collage', '9'),
    ('groups.free_max_count', '5', 'Max groups a free user can belong to as promotor', '5'),
    ('groups.pro_max_count', '20', 'Max groups a PRO user can belong to as promotor', '20'),
    ('groups.vip_max_count', '100', 'Max groups a VIP user can belong to as promotor', '100'),
    ('groups.free_max_members', '14', 'Max members per group when promotor is free tier', '14'),
    ('groups.pro_max_members', '256', 'Max members per group when promotor is PRO', '256'),
    ('groups.vip_max_members', '999999', 'Effectively unlimited for VIP (use as sentinel)', '999999'),
    ('feed.nearby_radius_km_default', '50', 'Default radius for geographical feed filter', '50'),
    ('feed.nearby_radius_km_options', '5,20,50,999', 'Comma-separated radius options shown in filter (999 = anywhere)', '5,20,50,999'),
    ('minigame.poke_timeout_minutes', '5', 'Default minutes a poked user has to poke someone else', '5'),
    ('minigame.challenge_timeout_minutes', '60', 'Default minutes to complete a challenge before it expires', '60'),
    ('ranks.update_cron', '59 23 * * *', 'Cron expression for daily rank recalculation', '59 23 * * *'),
    ('ranks.bracket_thresholds', '0,20,40,60,80,90,100', 'Percentile bracket boundaries', '0,20,40,60,80,90,100'),
    ('subs.pro_monthly_price_pen', '1999', 'PRO monthly price in Peruvian centimos (S/. 19.99)', '1999'),
    ('subs.vip_monthly_price_pen', '4999', 'VIP monthly price in Peruvian centimos (S/. 49.99)', '4999'),
    ('subs.pro_annual_price_pen', '19990', 'PRO annual price in Peruvian centimos (S/. 199.90)', '19990'),
    ('subs.vip_annual_price_pen', '49990', 'VIP annual price in Peruvian centimos (S/. 499.90)', '49990'),
    ('events.status_poll_cron', '* * * * *', 'Cron expression for polling upcoming -> live and live -> ended transitions', '* * * * *'),
    ('security.max_events_per_minute', '3', 'Rapid creation flag threshold', '3'),
    ('security.max_concurrent_event_invites', '50', 'Max pending invites per user', '50'),
    ('security.max_qr_token_rotations', '20', 'Max rotations per user per event', '20'),
    ('security.max_failed_qr_validations', '5', 'Max failed attempts per token', '5'),
    ('app.search_debounce_ms', '300', 'Debounce delay (ms) for search/invite screens (PERF-05/L-24; fallback 300 in lib)', '300')
ON CONFLICT (key) DO NOTHING;
