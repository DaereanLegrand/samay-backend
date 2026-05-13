-- Add status column to group_members to support the invite system.
-- 'active' = accepted member, 'invited' = pending invitation.
-- Existing members default to 'active'.

ALTER TABLE group_members ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active';

-- Add constraint to limit valid statuses
ALTER TABLE group_members ADD CONSTRAINT group_members_status_check
    CHECK (status IN ('active', 'invited'));
