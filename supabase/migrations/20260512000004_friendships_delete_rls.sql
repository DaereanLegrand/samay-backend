-- Fix: Allow users to delete their own friendships (decline requests, remove friends).
CREATE POLICY friendships_delete_own ON friendships FOR DELETE USING (requester_id = auth.uid() OR addressee_id = auth.uid());
