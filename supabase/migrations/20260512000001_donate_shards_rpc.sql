-- RPC: donate_shards_to_group
-- Atomically deducts personal shards and creates a group_shard_contributions entry.
-- The trigger group_shards_increment_trigger handles incrementing groups.group_shards.

CREATE OR REPLACE FUNCTION donate_shards_to_group(
    p_group_id uuid,
    p_user_id uuid,
    p_amount integer,
    p_expires_at timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Deduct from user
    UPDATE users SET personal_shards = personal_shards - p_amount
    WHERE id = p_user_id AND personal_shards >= p_amount;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Insufficient shards';
    END IF;

    -- Record shard ledger entry
    INSERT INTO shard_ledger (user_id, delta, reason, reference_id)
    VALUES (p_user_id, -p_amount, 'group_donation', p_group_id);

    -- Record contribution (trigger will increment group_shards)
    INSERT INTO group_shard_contributions (group_id, user_id, shards_contributed, expires_at)
    VALUES (p_group_id, p_user_id, p_amount, p_expires_at);
END;
$$;
