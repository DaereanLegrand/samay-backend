-- Fix: infinite recursion in group_members RLS policies
-- The old policies (group_members_read_same, group_members_insert) used
-- sub-queries on group_members within their own RLS expressions, causing
-- infinite recursion (error 42P17).
-- Replace with terminal column checks and references to the groups table.

DROP POLICY IF EXISTS group_members_read_same ON group_members;
DROP POLICY IF EXISTS group_members_insert ON group_members;

-- Terminal: each user can always read their own membership row
CREATE POLICY group_members_read_own ON group_members FOR SELECT USING (
    user_id = auth.uid()
);

-- Group creator can insert members (including themselves as first member)
CREATE POLICY group_members_insert_creator ON group_members FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM groups WHERE id = group_members.group_id AND created_by_user_id = auth.uid())
);
