-- Run in Supabase SQL Editor.
--
-- groups.visibility becomes a real boundary.
--
-- ---------------------------------------------------------------------
-- WHAT WAS WRONG
--
-- Measured signed out, against eight seeded groups:
--
--   select on groups   -> 8 rows, INCLUDING the members-only one, with
--                         its name and description
--   search_groups(...) -> 7 rows, members-only correctly excluded
--
-- The RPC filtered and RLS did not. Same hole migration 113 closed on
-- churches.is_hidden.
--
-- groups has three policies that permit SELECT, and permissive policies
-- OR together, so only one of them was doing any harm:
--
--   "Staff can view their church's groups"  owner or staff_beyond_checkin
--   "groups are publicly readable"          using (true)      <-- this
--   "owner or staff can manage groups"      ALL, owner or staff
--
-- Only the middle one is replaced. The other two already say what they
-- mean and are what keeps owners and staff seeing their own groups --
-- this migration deliberately does not touch them, and does not repeat
-- them inside the new predicate either.
--
-- ---------------------------------------------------------------------
-- THE SHAPE IS COPIED, NOT INVENTED
--
-- events already gets this right and was used as the reference:
--
--   coalesce(visibility, 'public') <> ALL (ARRAY['draft','private'])
--   OR (visibility = 'private' AND is_approved_church_member(church_id) ...)
--
-- groups uses 'members' where events uses 'private', so the same test
-- reads: anything that is not members-only, or a member of that church.
-- coalesce for the same reason events has it -- a null visibility is a
-- group nobody restricted, not a group nobody may see.
--
-- is_platform_admin is added because groups had no admin policy at all
-- and an admin cannot support what they cannot read.
--
-- PERFORMANCE: the function calls sit behind (select auth.uid()) is not
-- null, which the planner evaluates once as an InitPlan rather than per
-- row. A signed-out visitor -- most traffic -- never reaches a function
-- call; a signed-in one only does on rows that are actually
-- members-only.

do $$
begin
  if not exists (select 1 from pg_policies
                 where schemaname = 'public' and tablename = 'groups'
                   and policyname = 'groups are publicly readable') then
    raise exception 'ABORT: the policy this replaces is not there under that name. Re-read pg_policies before continuing.';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.groups'::regclass) then
    raise exception 'ABORT: row level security is not enabled on groups, so no policy would do anything.';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'is_approved_church_member') then
    raise exception 'ABORT: is_approved_church_member() is missing; the policy would have nothing to call.';
  end if;
end $$;

drop policy if exists "groups are publicly readable" on groups;

create policy "groups are publicly readable" on groups
  for select to public
  using (
    coalesce(visibility, 'public') <> 'members'
    or (
      (select auth.uid()) is not null
      and (
        is_approved_church_member(church_id)
        or is_platform_admin()
      )
    )
  );

-- ---------------------------------------------------------------------
-- The only verification that means anything is what an anon actually
-- sees. postgres is superuser and bypasses RLS, so counting as postgres
-- would prove nothing; SET LOCAL ROLE anon makes the policy apply, and
-- RESET ROLE puts it back.
do $$
declare
  total       bigint;
  public_n    bigint;
  members_n   bigint;
  anon_sees   bigint;
  anon_member bigint;
begin
  select count(*),
         count(*) filter (where coalesce(visibility,'public') <> 'members'),
         count(*) filter (where visibility = 'members')
    into total, public_n, members_n
    from groups;

  set local role anon;
  select count(*) into anon_sees from groups;
  select count(*) into anon_member from groups where visibility = 'members';
  reset role;

  raise notice 'groups: % rows, % public, % members-only.', total, public_n, members_n;
  raise notice 'anon now sees % of them, of which % are members-only.', anon_sees, anon_member;

  if anon_member > 0 then
    raise exception 'VERIFY FAILED: anon can still read % members-only groups.', anon_member;
  end if;
  if anon_sees <> public_n then
    raise exception 'VERIFY FAILED: anon sees % but should see % (the public ones).', anon_sees, public_n;
  end if;

  raise notice 'OK. Members-only groups are no longer readable by anon.';
  raise notice 'Check next: the Groups tab still lists the public ones, and a church owner still sees their own members-only group in the dashboard.';
end $$;

-- ---------------------------------------------------------------------
-- ROLLBACK, if something that should see a group cannot. This puts the
-- leak back, so it buys time rather than fixing anything:
--
--   drop policy if exists "groups are publicly readable" on groups;
--   create policy "groups are publicly readable" on groups
--     for select to public using (true);
