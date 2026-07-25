-- Fix: donate_shards_to_group RPC security
--   1. Add auth.uid() check to prevent cross-user donation
--   2. REVOKE EXECUTE from PUBLIC (SECURITY DEFINER with public execute = bypass RLS)
--   3. GRANT EXECUTE to authenticated role only

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
    IF auth.uid() != p_user_id THEN
        RAISE EXCEPTION 'Not authorized';
    END IF;

    UPDATE users SET personal_shards = personal_shards - p_amount
    WHERE id = p_user_id AND personal_shards >= p_amount;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Insufficient shards';
    END IF;

    INSERT INTO shard_ledger (user_id, delta, reason, reference_id)
    VALUES (p_user_id, -p_amount, 'group_donation', p_group_id);

    INSERT INTO group_shard_contributions (group_id, user_id, shards_contributed, expires_at)
    VALUES (p_group_id, p_user_id, p_amount, p_expires_at);
END;
$$;

REVOKE EXECUTE ON FUNCTION donate_shards_to_group FROM PUBLIC;
GRANT EXECUTE ON FUNCTION donate_shards_to_group TO authenticated;
