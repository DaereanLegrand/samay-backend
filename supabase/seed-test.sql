-- Samay — seed-test.sql (MSQ-01, user directive 2026-08-23)
-- Test-data snapshot: @tester.com users, friendships, and group
-- "Cowboy Bebopers" (+members).
--
-- NO IMAGE DATA (user directive 2026-08-28): avatars/banners and the
-- storage.objects metadata rows are stripped — the 4 users carry no
-- avatar_url and the group has no cover_url.
--
-- CONVERSATIONS AND NOTIFICATIONS ARE DELIBERATELY ABSENT (user directive):
-- no chats / messages / read receipts / deleted_messages / notifications.
--
-- REGENERABLE DATA REMOVED (user directive 2026-08-30): e2ee_identity_keys,
-- shard_ledger, minigame_sessions, group_rank_snapshots, and signup_tracker
-- are gone — everything left is user identity or durable social graph.
--
-- EXPLICIT ONLY — never applied by init/reset/migrate:
--   make supabase-seed-test
-- Idempotent (ON CONFLICT DO NOTHING).

SET TIME ZONE 'UTC';
BEGIN;
-- Suppress user-space triggers (notification fan-out etc.) while
-- seeding: rows here are historical facts, not new events.
SET LOCAL session_replication_role = replica;


-- ── auth.users (password hashes preserved; fresh-schema columns only) ──
INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,invited_at,confirmation_token,confirmation_sent_at,recovery_token,recovery_sent_at,email_change_token_new,email_change,email_change_sent_at,last_sign_in_at,raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at,phone,phone_confirmed_at,phone_change,phone_change_token,phone_change_sent_at,email_change_token_current,email_change_confirm_status,banned_until,reauthentication_token,reauthentication_sent_at,is_sso_user,deleted_at,is_anonymous) VALUES ('00000000-0000-0000-0000-000000000000','9bb9e190-da36-42ec-952e-26dca8ec51ba','authenticated','authenticated','tester2@tester.com','$2a$10$toqRPeDso5laOyPR4uVEr.DooqIBA1wU9VxzsOfI12fH/cKWEezau','2026-08-15 10:35:38.986954+00',NULL,'',NULL,'',NULL,'','',NULL,'2026-08-23 07:01:04.994663+00','{"provider": "email", "providers": ["email"]}','{"email_verified": true}',NULL,'2026-08-15 10:35:38.979401+00','2026-08-23 07:01:04.996996+00',NULL,NULL,'','',NULL,'','0',NULL,'',NULL,'false',NULL,'false') ON CONFLICT DO NOTHING;
INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,invited_at,confirmation_token,confirmation_sent_at,recovery_token,recovery_sent_at,email_change_token_new,email_change,email_change_sent_at,last_sign_in_at,raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at,phone,phone_confirmed_at,phone_change,phone_change_token,phone_change_sent_at,email_change_token_current,email_change_confirm_status,banned_until,reauthentication_token,reauthentication_sent_at,is_sso_user,deleted_at,is_anonymous) VALUES ('00000000-0000-0000-0000-000000000000','c5c2cba7-c25b-45c8-a4f3-a33b3cbe0227','authenticated','authenticated','tester3@tester.com','$2a$10$ZKAkPR4yZOZDuVwuVyEVc.14aaOQRygdMgmw8TsJD4vMi5Ixujdn2','2026-08-15 10:35:49.040139+00',NULL,'',NULL,'',NULL,'','',NULL,'2026-08-23 00:28:33.314563+00','{"provider": "email", "providers": ["email"]}','{"email_verified": true}',NULL,'2026-08-15 10:35:49.037847+00','2026-08-23 04:56:33.025107+00',NULL,NULL,'','',NULL,'','0',NULL,'',NULL,'false',NULL,'false') ON CONFLICT DO NOTHING;
INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,invited_at,confirmation_token,confirmation_sent_at,recovery_token,recovery_sent_at,email_change_token_new,email_change,email_change_sent_at,last_sign_in_at,raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at,phone,phone_confirmed_at,phone_change,phone_change_token,phone_change_sent_at,email_change_token_current,email_change_confirm_status,banned_until,reauthentication_token,reauthentication_sent_at,is_sso_user,deleted_at,is_anonymous) VALUES ('00000000-0000-0000-0000-000000000000','6f8108f5-3964-45df-82a1-76a5d9185c10','authenticated','authenticated','tester@tester.com','$2a$10$uEcO8WuADg9LuESAcd/YFeOZVuiF4LhDDK5ElMdVxZPnwXxop8.HK','2026-08-15 21:59:57.493015+00',NULL,'',NULL,'',NULL,'','',NULL,'2026-08-18 03:37:32.191651+00','{"provider": "email", "providers": ["email"]}','{"sub": "6f8108f5-3964-45df-82a1-76a5d9185c10", "email": "tester@tester.com", "email_verified": true, "phone_verified": false}',NULL,'2026-08-15 21:57:37.83625+00','2026-08-23 04:15:07.425421+00',NULL,NULL,'','',NULL,'','0',NULL,'',NULL,'false',NULL,'false') ON CONFLICT DO NOTHING;
INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,invited_at,confirmation_token,confirmation_sent_at,recovery_token,recovery_sent_at,email_change_token_new,email_change,email_change_sent_at,last_sign_in_at,raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at,phone,phone_confirmed_at,phone_change,phone_change_token,phone_change_sent_at,email_change_token_current,email_change_confirm_status,banned_until,reauthentication_token,reauthentication_sent_at,is_sso_user,deleted_at,is_anonymous) VALUES ('00000000-0000-0000-0000-000000000000','e5b725d6-b491-4f36-9528-278363846697','authenticated','authenticated','tester4@tester.com','$2a$10$witcBw/hqIhbSB6iFW0WlOGm.u7ZXXZG67uMNq55MUxYJw2fwG0Ru','2026-08-15 22:00:53.429143+00',NULL,'',NULL,'',NULL,'','',NULL,'2026-08-15 22:00:53.432019+00','{"provider": "email", "providers": ["email"]}','{"sub": "e5b725d6-b491-4f36-9528-278363846697", "email": "tester4@tester.com", "email_verified": true, "phone_verified": false}',NULL,'2026-08-15 21:58:00.78909+00','2026-08-23 04:15:07.42733+00',NULL,NULL,'','',NULL,'','0',NULL,'',NULL,'false',NULL,'false') ON CONFLICT DO NOTHING;


-- ── public.users ──
INSERT INTO public.users (id,username,avatar_url,date_of_birth,bio,banned_at,ban_reason,deleted_at,personal_shards,preshards,subscription_tier,subscription_expires_at,notification_preferences,created_at,updated_at,interest_tags,discovery_opt_in,read_receipts_enabled,profile_public) VALUES ('c5c2cba7-c25b-45c8-a4f3-a33b3cbe0227','tester3',NULL,NULL,NULL,NULL,NULL,NULL,'1000','0','free',NULL,'{}','2026-08-15 10:35:49.074734+00','2026-08-15 10:37:02.079351+00','{}','false','true','false') ON CONFLICT DO NOTHING;
INSERT INTO public.users (id,username,avatar_url,date_of_birth,bio,banned_at,ban_reason,deleted_at,personal_shards,preshards,subscription_tier,subscription_expires_at,notification_preferences,created_at,updated_at,interest_tags,discovery_opt_in,read_receipts_enabled,profile_public) VALUES ('9bb9e190-da36-42ec-952e-26dca8ec51ba','tester2',NULL,NULL,NULL,NULL,NULL,NULL,'1000','0','free',NULL,'{}','2026-08-15 10:35:58.399558+00','2026-08-15 10:37:02.079351+00','{}','false','true','false') ON CONFLICT DO NOTHING;
INSERT INTO public.users (id,username,avatar_url,date_of_birth,bio,banned_at,ban_reason,deleted_at,personal_shards,preshards,subscription_tier,subscription_expires_at,notification_preferences,created_at,updated_at,interest_tags,discovery_opt_in,read_receipts_enabled,profile_public) VALUES ('6f8108f5-3964-45df-82a1-76a5d9185c10','tester',NULL,'2008-08-09',NULL,NULL,NULL,NULL,'256','0','free',NULL,'{}','2026-08-15 17:00:15.337595+00','2026-08-18 03:54:16.328464+00','{}','false','true','false') ON CONFLICT DO NOTHING;
INSERT INTO public.users (id,username,avatar_url,date_of_birth,bio,banned_at,ban_reason,deleted_at,personal_shards,preshards,subscription_tier,subscription_expires_at,notification_preferences,created_at,updated_at,interest_tags,discovery_opt_in,read_receipts_enabled,profile_public) VALUES ('e5b725d6-b491-4f36-9528-278363846697','tester4',NULL,'2008-08-15',NULL,NULL,NULL,NULL,'256','0','free',NULL,'{}','2026-08-15 17:01:13.115392+00','2026-08-20 20:58:09.995509+00','{}','false','true','false') ON CONFLICT DO NOTHING;


-- ── friendships ──
INSERT INTO public.friendships (id,requester_id,addressee_id,status,created_at) VALUES ('9681ef1f-1293-46df-865f-0e4871c0e17b','9bb9e190-da36-42ec-952e-26dca8ec51ba','c5c2cba7-c25b-45c8-a4f3-a33b3cbe0227','accepted','2026-08-15 10:37:58.29232+00') ON CONFLICT DO NOTHING;
INSERT INTO public.friendships (id,requester_id,addressee_id,status,created_at) VALUES ('5e8734f0-a1fb-42e0-a926-005e79ca190b','6f8108f5-3964-45df-82a1-76a5d9185c10','9bb9e190-da36-42ec-952e-26dca8ec51ba','accepted','2026-08-15 22:01:44.078419+00') ON CONFLICT DO NOTHING;
INSERT INTO public.friendships (id,requester_id,addressee_id,status,created_at) VALUES ('61813637-75ba-4809-afb9-d92b74e00f3d','6f8108f5-3964-45df-82a1-76a5d9185c10','c5c2cba7-c25b-45c8-a4f3-a33b3cbe0227','accepted','2026-08-15 22:01:45.32234+00') ON CONFLICT DO NOTHING;
INSERT INTO public.friendships (id,requester_id,addressee_id,status,created_at) VALUES ('5a3ad7a9-6758-4c23-9e48-623b7d4f1aec','6f8108f5-3964-45df-82a1-76a5d9185c10','e5b725d6-b491-4f36-9528-278363846697','accepted','2026-08-15 22:01:46.005561+00') ON CONFLICT DO NOTHING;
INSERT INTO public.friendships (id,requester_id,addressee_id,status,created_at) VALUES ('89731187-de84-40fc-b8fa-3d8d80274ba0','e5b725d6-b491-4f36-9528-278363846697','c5c2cba7-c25b-45c8-a4f3-a33b3cbe0227','accepted','2026-08-15 22:02:05.213482+00') ON CONFLICT DO NOTHING;
INSERT INTO public.friendships (id,requester_id,addressee_id,status,created_at) VALUES ('843ceef0-821d-4dde-9455-2ca13aaeb796','e5b725d6-b491-4f36-9528-278363846697','9bb9e190-da36-42ec-952e-26dca8ec51ba','accepted','2026-08-15 22:02:06.113704+00') ON CONFLICT DO NOTHING;


-- ── groups ──
INSERT INTO public.groups (id,name,description,cover_url,created_by_user_id,group_shards,size_tier,rank_bracket,frozen_at,created_at,updated_at) VALUES ('63ff0f12-a827-48eb-b9c7-762a61259973','Cowboy Bebopers','boop',NULL,'9bb9e190-da36-42ec-952e-26dca8ec51ba','0','micro','b40_60',NULL,'2026-08-17 00:46:00.588508+00','2026-08-22 23:59:00.021216+00') ON CONFLICT DO NOTHING;


-- ── group_members ──
INSERT INTO public.group_members (id,group_id,user_id,role,joined_at,status) VALUES ('6f61ba24-9e43-4d82-87df-46c46b9bcc05','63ff0f12-a827-48eb-b9c7-762a61259973','9bb9e190-da36-42ec-952e-26dca8ec51ba','host','2026-08-17 00:46:00.841462+00','active') ON CONFLICT DO NOTHING;
INSERT INTO public.group_members (id,group_id,user_id,role,joined_at,status) VALUES ('c61221a5-5a51-4b00-aeab-877cc7a3fa17','63ff0f12-a827-48eb-b9c7-762a61259973','c5c2cba7-c25b-45c8-a4f3-a33b3cbe0227','member','2026-08-17 00:46:21.576166+00','active') ON CONFLICT DO NOTHING;
INSERT INTO public.group_members (id,group_id,user_id,role,joined_at,status) VALUES ('b805a75c-18e7-4c7d-b8fe-86b0623c2b59','63ff0f12-a827-48eb-b9c7-762a61259973','6f8108f5-3964-45df-82a1-76a5d9185c10','member','2026-08-17 00:46:22.003472+00','active') ON CONFLICT DO NOTHING;
INSERT INTO public.group_members (id,group_id,user_id,role,joined_at,status) VALUES ('db222bf1-0553-421e-8e70-b8d09ce5610d','63ff0f12-a827-48eb-b9c7-762a61259973','e5b725d6-b491-4f36-9528-278363846697','member','2026-08-17 00:46:22.277518+00','active') ON CONFLICT DO NOTHING;

COMMIT;
