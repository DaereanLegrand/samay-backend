-- Fix: trigger update_group_size_tier() assigns text to size_tier enum column
-- without explicit cast, causing "column 'size_tier' is of type size_tier
-- but expression is of type text" error (42804).

CREATE OR REPLACE FUNCTION update_group_size_tier()
RETURNS trigger AS $$
DECLARE
    member_count integer;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT COUNT(*) INTO member_count FROM group_members WHERE group_id = NEW.group_id;
    ELSE
        SELECT COUNT(*) INTO member_count FROM group_members WHERE group_id = OLD.group_id;
    END IF;

    UPDATE groups SET size_tier = CASE
        WHEN member_count >= 257 THEN 'large'::size_tier
        WHEN member_count >= 51  THEN 'medium'::size_tier
        WHEN member_count >= 15  THEN 'small'::size_tier
        ELSE 'micro'::size_tier
    END WHERE id = COALESCE(NEW.group_id, OLD.group_id);

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
