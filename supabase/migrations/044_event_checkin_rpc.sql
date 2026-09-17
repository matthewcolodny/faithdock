-- Run in Supabase SQL Editor.
--
-- Check-in has never worked for anyone but the attendee themselves.
--
-- Every UPDATE policy on event_registrations is scoped to
-- `user_id = auth.uid()`:
--
--   Users can delete their own event registrations   DELETE  user_id = auth.uid()
--   Users can update their own event registrations   UPDATE  user_id = auth.uid()
--   users can update their own registration          UPDATE  user_id = auth.uid()
--
-- There is no UPDATE policy for a church owner or for staff. A church
-- owner CAN select registrations for their own events, so the check-in
-- roster loads and shows real names -- and then every tick silently
-- matched zero rows. Combined with the optimistic paint in the client
-- (fixed separately in build v87), the door volunteer saw a green tick
-- and nothing was recorded, with no error anywhere.
--
-- === Why an RPC and not another policy ===
-- The same reasoning as migration 036, and it has earned its keep: a
-- client-side write depends on policies that aren't in this repo and
-- can't be reviewed here, which is exactly how this bug survived. A
-- SECURITY DEFINER function carries its own authorization, so the
-- answer doesn't depend on what else happens to be granted.
--
-- It also solves a problem a policy cannot. RLS is ROW-level: a policy
-- permitting staff to UPDATE these rows would permit updating any
-- column on them -- status, role, the registration itself -- when all
-- that's wanted is a check-in tick. This function writes exactly one
-- column and nothing else can be reached through it.

create or replace function set_registration_checked_in(
  p_registration_id uuid,
  p_checked_in boolean
)
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_church_id uuid;
  v_new_value timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated.';
  end if;

  select e.church_id into v_church_id
    from event_registrations er
    join events e on e.id = er.event_id
    where er.id = p_registration_id;

  if v_church_id is null then
    raise exception 'REGISTRATION_NOT_FOUND';
  end if;

  -- Owner or staff who manage events. Deliberately NOT a new ability
  -- column yet: a dedicated can_check_in flag is the right end state
  -- (a door volunteer should not be able to delete the event), but
  -- that is a product decision still being made. Adding the column
  -- here and defaulting it false would lock every existing staff
  -- member OUT of check-in the moment this runs, which is a worse
  -- failure than the one being fixed. When can_check_in lands, widen
  -- this single condition -- that is the only line that changes.
  if not (
    exists (select 1 from churches c where c.id = v_church_id and c.owner_id = auth.uid())
    or exists (
      select 1 from church_staff cs
      where cs.church_id = v_church_id
        and cs.user_id = auth.uid()
        and coalesce(cs.can_manage_events, false)
    )
  ) then
    raise exception 'NOT_PERMITTED_TO_CHECK_IN';
  end if;

  v_new_value := case when p_checked_in then now() else null end;

  update event_registrations
     set checked_in_at = v_new_value
   where id = p_registration_id;

  -- Returned so the client can show the real stored time rather than
  -- the one it optimistically guessed, and so "nothing happened" is
  -- impossible to mistake for success at the call site.
  return v_new_value;
end;
$$;

revoke execute on function set_registration_checked_in(uuid, boolean) from anon;

-- === Staff cannot see the roster either ===
-- The only SELECT policy covering other people's registrations is
-- "church owner can view registrations for their events". Staff get
-- nothing, so for a staff member the check-in list is empty before a
-- tick is ever attempted. Added here because a write permission
-- without a matching read is useless -- they are one feature.
drop policy if exists "church staff can view registrations for their church events" on event_registrations;
create policy "church staff can view registrations for their church events"
  on event_registrations for select
  to authenticated
  using (
    exists (
      select 1 from events e
      join church_staff cs on cs.church_id = e.church_id
      where e.id = event_registrations.event_id
        and cs.user_id = auth.uid()
    )
  );

notify pgrst, 'reload schema';

-- Housekeeping, safe to skip: these two UPDATE policies are identical
-- (both `user_id = auth.uid()`), so one is redundant. Left commented
-- rather than dropped, because dropping a policy this repo did not
-- create deserves a deliberate decision rather than a side effect of
-- an unrelated migration.
-- drop policy if exists "users can update their own registration" on event_registrations;
