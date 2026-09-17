-- Run in Supabase SQL Editor. Requires migration 035.
--
-- Fixes three things reported immediately after 035 went live, all of
-- them the same underlying mistake: "leaving" a church never actually
-- removed the membership row, it only flipped is_permanent to false and
-- left status = 'approved' sitting there.
--
--   1. There was no way to cancel a pending request at all.
--   2. Re-joining after leaving failed with "Only the church can change
--      a membership's approval status." The row still existed, so the
--      re-join was an UPDATE trying to go approved -> pending, and 035's
--      trigger only carved out rejected -> pending.
--   3. The church's directory still listed the person as a member the
--      whole time they were "gone", because the approved row never went
--      anywhere.
--
-- The fix for all three is the same: leaving means the row is deleted,
-- so coming back is a plain INSERT with nothing to reconcile.

-- === Leaving / cancelling ===
-- An RPC rather than a client-side delete plus an RLS policy, on
-- purpose. church_memberships' existing policies aren't in this repo, so
-- a client-side .delete() would depend on a policy nobody here can see
-- or verify -- which is exactly how unregistering appeared to work for
-- weeks while silently affecting zero rows (migration 033). A
-- SECURITY DEFINER function carries its own authorization, so the answer
-- is never in doubt: it deletes your own row and nobody else's, because
-- the WHERE clause is auth.uid() and isn't taking that from the caller.
--
-- Covers both verbs deliberately -- cancelling a pending request and
-- leaving an approved membership are the same operation on the data,
-- and splitting them would only invite the two copies to drift.
create or replace function leave_church(target_church_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated.';
  end if;

  delete from church_memberships
    where church_id = target_church_id and user_id = auth.uid();

  return found;
end;
$$;

-- === Re-requesting from any prior state ===
-- 035's trigger allowed only rejected -> pending, which covered asking
-- again after being turned down but not the far more ordinary case of
-- leaving and coming back later. With leave_church() deleting the row
-- that specific path is now an INSERT anyway, but the narrow rule is
-- still wrong in principle and would keep biting: a row left at
-- is_permanent = false by the switch-church-home path, for instance,
-- hits the same wall.
--
-- Widened to the actual invariant worth protecting: nobody unauthorized
-- may move a row TO 'approved' or 'rejected'. Moving your own row to
-- 'pending' is a request, not an escalation -- it strictly reduces what
-- you have -- so it's allowed from any prior state. The new.user_id =
-- auth.uid() check is what keeps that from being a way to interfere with
-- somebody else's membership; the trigger can't assume RLS already
-- guarantees that, for the same reason 035 used a trigger in the first
-- place.
create or replace function enforce_church_membership_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_can_manage boolean;
  v_user_email text;
  v_has_invite boolean;
begin
  -- Service-role / backend callers (edge functions) have no auth.uid()
  -- and are already trusted; leave whatever they set alone rather than
  -- forcing their writes into 'pending'.
  if auth.uid() is null then
    return new;
  end if;

  v_actor_can_manage := can_manage_church_members(new.church_id);

  if tg_op = 'INSERT' then
    -- The church adding someone directly is itself the approval, so an
    -- authorized actor's explicit value is taken at face value.
    if v_actor_can_manage then
      return new;
    end if;

    -- Someone joining on their own account. Already-invited people skip
    -- the queue: the church went out of its way to ask them, so making
    -- them wait for a second approval would be nonsense.
    select email into v_user_email from auth.users where id = auth.uid();
    select exists (
      select 1 from church_member_invites cmi
      where cmi.church_id = new.church_id
        and lower(cmi.email) = lower(coalesce(v_user_email, ''))
    ) into v_has_invite;

    new.status := case when v_has_invite then 'approved' else 'pending' end;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.status is distinct from old.status and not v_actor_can_manage then
      -- Asking, or asking again, on your own row. Never an escalation:
      -- 'pending' is strictly less than what 'approved' grants.
      if new.status = 'pending' and new.user_id = auth.uid() then
        return new;
      end if;
      raise exception 'Only the church can change a membership''s approval status.';
    end if;
    return new;
  end if;

  return new;
end;
$$;

notify pgrst, 'reload schema';
