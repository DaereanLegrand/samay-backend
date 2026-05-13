-- Add UPDATE policy for group_members so transferPromotor() and setMemberRole()
-- can update member roles from the client side.

CREATE POLICY group_members_update_promotor ON group_members FOR UPDATE USING (
    EXISTS (SELECT 1 FROM group_members gm2 WHERE gm2.group_id = group_members.group_id AND gm2.user_id = auth.uid() AND gm2.role IN ('promotor', 'co_promotor'))
);
