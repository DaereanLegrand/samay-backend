-- =============================================================================
-- 20260816000001 — Group chain of command (OPT-009)
-- -----------------------------------------------------------------------------
-- Fixes the group leadership contract, verified live by test/opt-009:
--
-- 1. RLS role hierarchy on group_members. Before this, BOTH
--    group_members_update_promotor and group_members_delete_promotor let a
--    co_promotor modify/kick ANY member row — including the promotor: a
--    co_promotor could demote the promotor and kick them, leaving the group
--    leaderless (reproduced live). New rule: only a promotor manages
--    promotors; co_promotors manage members/co_promotors; members manage
--    nothing. A promotor may self-demote (the transfer step below).
--
-- 2. transfer_promotor RPC — atomic promotor handover in a single
--    transaction (demote self to co_promotor + promote the successor),
--    promotor-only. The previous client-side two-PATCH dance was
--    non-atomic and is now impossible under the hierarchy RLS.
--
-- 3. reassign_group_promotor triggers — when the promotor is banned,
--    soft-deletes their account, or their membership row disappears
--    (hard-delete cron, promotor leaves), leadership auto-passes to a
--    co_promotor (random pick), else to a random ACTIVE member. Invited
--    members are never promoted. On the ban/soft-delete path the old
--    promotor's row is demoted to 'member' (the CLI unban restores a
--    member, not leadership).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Role-hierarchy RLS on group_members
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS group_members_update_promotor ON public.group_members;
CREATE POLICY group_members_update_promotor ON public.group_members FOR UPDATE
USING (
    EXISTS (
        SELECT 1 FROM public.group_members gm2
        WHERE gm2.group_id = group_members.group_id
          AND gm2.user_id = auth.uid()
          AND gm2.role IN ('promotor', 'co_promotor')
          -- the actor must outrank the TARGET row (a co_promotor may never
          -- touch a promotor's row; a promotor may update anything incl.
          -- its own self-demotion on transfer)
          AND (gm2.role = 'promotor' OR group_members.role <> 'promotor')
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.group_members gm2
        WHERE gm2.group_id = group_members.group_id
          AND gm2.user_id = auth.uid()
          AND (
              gm2.role = 'promotor'
              OR (gm2.role = 'co_promotor'
                  AND group_members.role IN ('member', 'co_promotor'))
          )
    )
);

DROP POLICY IF EXISTS group_members_delete_promotor ON public.group_members;
CREATE POLICY group_members_delete_promotor ON public.group_members FOR DELETE USING (
    EXISTS (
        SELECT 1 FROM public.group_members gm2
        WHERE gm2.group_id = group_members.group_id
          AND gm2.user_id = auth.uid()
          AND (gm2.role = 'promotor'
               OR (gm2.role = 'co_promotor' AND group_members.role <> 'promotor'))
    )
);

-- -----------------------------------------------------------------------------
-- 2. transfer_promotor RPC (promotor-only, atomic)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.transfer_promotor(p_group_id uuid, p_new_promotor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_actor_role public.group_role;
    v_new_role   public.group_role;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'not_authenticated';
    END IF;

    SELECT role INTO v_actor_role
    FROM public.group_members
    WHERE group_id = p_group_id AND user_id = auth.uid() AND status = 'active';

    IF v_actor_role IS NULL THEN
        RAISE EXCEPTION 'not_a_member';
    END IF;
    IF v_actor_role <> 'promotor' THEN
        RAISE EXCEPTION 'not_promotor';
    END IF;

    SELECT role INTO v_new_role
    FROM public.group_members
    WHERE group_id = p_group_id AND user_id = p_new_promotor_id AND status = 'active';

    IF v_new_role IS NULL THEN
        RAISE EXCEPTION 'new_member_not_found';
    END IF;

    -- Single transaction: demote self, promote the successor. Idempotent —
    -- a successor who is already promotor leaves exactly one promotor.
    UPDATE public.group_members SET role = 'co_promotor'
    WHERE group_id = p_group_id AND user_id = auth.uid() AND role = 'promotor';

    UPDATE public.group_members SET role = 'promotor'
    WHERE group_id = p_group_id AND user_id = p_new_promotor_id;

    RETURN jsonb_build_object('status', 'ok');
END;
$$;

REVOKE EXECUTE ON FUNCTION public.transfer_promotor(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transfer_promotor(uuid, uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Leadership reassignment (ban / account deletion / promotor row gone)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.promote_next_member(p_group_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_next uuid;
BEGIN
    -- Prefer a co-promotor; fall back to a random ACTIVE member. Invited
    -- members (status <> 'active') never receive leadership.
    SELECT user_id INTO v_next
    FROM public.group_members
    WHERE group_id = p_group_id AND status = 'active' AND role = 'co_promotor'
    ORDER BY random()
    LIMIT 1;

    IF v_next IS NULL THEN
        SELECT user_id INTO v_next
        FROM public.group_members
        WHERE group_id = p_group_id AND status = 'active' AND role = 'member'
        ORDER BY random()
        LIMIT 1;
    END IF;

    IF v_next IS NOT NULL THEN
        UPDATE public.group_members SET role = 'promotor'
        WHERE group_id = p_group_id AND user_id = v_next;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.reassign_group_promotor()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    gid uuid;
BEGIN
    -- Promotor membership row deleted (kick is RLS-blocked for everyone but
    -- the promotor itself, so this is: promotor leaves, hard-delete cron,
    -- or account-delete cascade) → pass leadership on. Note: plpgsql does
    -- NOT short-circuit AND/OR conditions, so the OLD.role access must live
    -- in a DELETE-only branch (this function also fires on users UPDATE).
    IF TG_OP = 'DELETE' THEN
        IF OLD.role = 'promotor' THEN
            PERFORM public.promote_next_member(OLD.group_id);
        END IF;
        RETURN OLD;
    END IF;

    -- Promotor banned or soft-deleted → demote to member + pass leadership.
    -- (Fires only on banned_at/deleted_at column updates; the demotion
    -- below is a group_members UPDATE, so there is no recursion.)
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.banned_at IS NOT NULL AND OLD.banned_at IS NULL)
           OR (NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL) THEN
            FOR gid IN
                SELECT group_id FROM public.group_members
                WHERE user_id = NEW.id AND role = 'promotor'
            LOOP
                UPDATE public.group_members SET role = 'member'
                WHERE group_id = gid AND user_id = NEW.id AND role = 'promotor';
                PERFORM public.promote_next_member(gid);
            END LOOP;
        END IF;
        RETURN NEW;
    END IF;

    RETURN COALESCE(OLD, NEW);
END;
$$;

DROP TRIGGER IF EXISTS reassign_group_promotor_delete_trigger ON public.group_members;
CREATE TRIGGER reassign_group_promotor_delete_trigger
    AFTER DELETE ON public.group_members
    FOR EACH ROW EXECUTE FUNCTION public.reassign_group_promotor();

DROP TRIGGER IF EXISTS reassign_group_promotor_user_trigger ON public.users;
CREATE TRIGGER reassign_group_promotor_user_trigger
    AFTER UPDATE OF banned_at, deleted_at ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.reassign_group_promotor();

-- Trigger-invoked helpers need no EXECUTE privilege; explicit REVOKE so the
-- anon-executable SD-function posture (Section 48) stays clean.
REVOKE EXECUTE ON FUNCTION public.promote_next_member(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reassign_group_promotor() FROM PUBLIC;
