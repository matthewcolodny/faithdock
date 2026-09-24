-- Run in the Supabase SQL Editor.
--
-- Drops "private events visible to members", which lets ANY signed-in
-- account read a church's hidden events.
--
-- THE HOLE. That policy's whole test is:
--
--     visibility = 'private'
--     AND EXISTS (select 1 from church_memberships
--                  where church_id = events.church_id
--                    and user_id = auth.uid())
--
-- It checks that a membership ROW EXISTS. It does not check
-- is_permanent, and it does not check status.
--
-- Migration 035 lets anyone insert their own church_memberships row for
-- any church -- that is what "Request to join" does. The trigger forces
-- status := 'pending' for a stranger, but the ROW IS THERE the moment
-- they click. So:
--
--   sign up -> click Request to join at any church -> immediately read
--   every event that church marked "hidden from everyone except your
--   members"
--
-- No approval required, and the church sees only a pending request in
-- its queue. Being turned down does not help either: a rejected row is
-- still a row.
--
-- WHY 092 DID NOT FIX THIS. Permissive policies OR together, so the
-- loosest wins. 092 replaced the policy it knew about and verified the
-- result signed OUT, where private events did go from 5 rows to 0 --
-- because an anonymous caller has auth.uid() = null and matches no
-- membership row. That test could never have caught this one. The
-- policy count in 092's own output (three, where one was expected) is
-- what did.
--
-- WHAT REPLACES IT: nothing. Migration 092's policy already covers the
-- legitimate case and covers it correctly --
-- is_approved_church_member() requires is_permanent AND
-- status = 'approved', the same definition get_directory_people uses,
-- and it also admits anyone actually registered for the event.
--
-- WHAT IS DELIBERATELY LEFT ALONE:
--
--   "public events are visible to all"  (visibility = 'public')
--       Strictly narrower than 092's first branch, so it grants
--       nothing extra. Kept as a backstop for the one failure mode
--       that is catastrophic rather than merely wrong: anonymous
--       event browsing breaking for every visitor, which is what
--       migration 085 had to repair.
--
--   the two "manage events" policies (FOR ALL, so they cover SELECT)
--       Both require owner, or staff of that church with
--       can_manage_events. Narrow. They overlap each other, which is
--       untidy, but neither grants a read to anyone who should not
--       have one.

-- ---------------------------------------------------------------------
-- Preflight: 092 must already be in place, or dropping this leaves
-- members unable to see their own church's hidden events.
-- ---------------------------------------------------------------------
do $preflight$
begin
  if not exists (
    select 1 from pg_policy p join pg_class c on c.oid = p.polrelid
    where c.relname = 'events' and p.polcmd = 'r'
      and p.polname = 'Drafts staff-only; members-only needs membership'
  ) then
    raise exception 'VERIFY FAILED: migration 092 has not been run. Dropping the loose policy without it would hide members-only events from the members who should see them. Nothing was changed.';
  end if;
  if to_regprocedure('public.is_approved_church_member(uuid)') is null then
    raise exception 'VERIFY FAILED: is_approved_church_member(uuid) is missing -- run migration 092 first. Nothing was changed.';
  end if;
  raise notice 'Preflight OK: 092 is in place.';
end
$preflight$;

drop policy if exists "private events visible to members" on events;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Verify.
-- ---------------------------------------------------------------------
do $verify$
begin
  if exists (
    select 1 from pg_policy p join pg_class c on c.oid = p.polrelid
    where c.relname = 'events' and p.polname = 'private events visible to members'
  ) then
    raise exception 'VERIFY FAILED: the loose policy is still there.';
  end if;
  raise notice 'OK: dropped.';
end
$verify$;

-- Every remaining policy that can grant a SELECT on events, printed in
-- full. Listed rather than counted: a count is what let this one hide
-- behind migration 092 in the first place.
select
  p.polname as policy_name,
  case p.polcmd when 'r' then 'SELECT' when '*' then 'ALL (covers SELECT)' else p.polcmd::text end as command,
  case p.polpermissive when true then 'PERMISSIVE (ORed)' else 'RESTRICTIVE (ANDed)' end as kind,
  pg_get_expr(p.polqual, p.polrelid) as using_expression
from pg_policy p
join pg_class c on c.oid = p.polrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'events' and p.polcmd in ('r', '*')
order by p.polname;
