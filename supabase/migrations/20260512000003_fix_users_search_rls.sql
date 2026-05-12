-- Fix: Allow users to search and view other users' basic profiles.
-- The existing users_read_own policy only lets users see their own row.
-- This new policy allows reading basic profile info of non-deleted users.

CREATE POLICY users_search ON users FOR SELECT USING (deleted_at IS NULL);
