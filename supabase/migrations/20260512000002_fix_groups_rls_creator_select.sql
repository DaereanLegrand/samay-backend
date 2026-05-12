-- Fix: Groups SELECT RLS policy for creator
-- The existing groups_read_member policy requires a group_members entry.
-- But during group creation, the member insert happens AFTER the group insert.
-- Without this policy, `.insert().select().single()` returns 0 rows and crashes.
-- This policy allows the creator (created_by_user_id) to read the group at any time.

CREATE POLICY groups_read_own ON groups FOR SELECT USING (created_by_user_id = auth.uid());
