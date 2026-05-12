-- Fix: Add missing FOR INSERT RLS policies
-- users: allow authenticated user to insert their own row on signup
-- shard_ledger: allow authenticated user to insert their own ledger entries

CREATE POLICY users_insert_own ON users FOR INSERT WITH CHECK (id = auth.uid());
CREATE POLICY sl_insert_own ON shard_ledger FOR INSERT WITH CHECK (user_id = auth.uid());
