-- Run in Supabase SQL Editor.
--
-- is_hidden becomes a real boundary instead of a UI convention.
--
-- ---------------------------------------------------------------------
-- WHAT WAS WRONG
--
-- Measured from the browser, signed out, before writing this: an anon
-- select on churches returned all 22,887 rows, 487 of them hidden, with
-- names and every other column. Hiding a church hid it from the
-- directory and from nobody else -- the client filtered, the database
-- did not.
--
-- churches had exactly one SELECT policy:
--
--   "churches are publicly readable"  PERMISSIVE  {public}  using (true)
--
-- Permissive policies OR together, so adding a stricter policy beside
-- that one would have changed nothing at all: every row would still
-- have come through the old one. This REPLACES it. That is the whole
-- reason the existing policies were read first.
--
-- ---------------------------------------------------------------------
-- WHY THE SHAPE IS WHAT IT IS
--
-- search_churches is prosecdef = false -- it runs as the caller, so RLS
-- applies inside it and the directory listing depends on this policy
-- being right. Four groups have to keep working, and each is a real
-- code path, not a hypothetical:
--
--   anon          the directory and profiles          (not is_hidden)
--   owner         their own church while hidden       index.html:24165
--   platform admin the church detail panel, which is  index.html:44867
--                 a DIRECT table select, not an RPC,
--                 so RLS applies to it
--   staff/member  the role map and its churches(...)  index.html:42306
--                 embed, which is also filtered
--
-- The membership tests call is_church_staff_member and
-- is_approved_church_member, which are both SECURITY DEFINER. That
-- matters: a policy that subqueried church_staff directly would itself
-- be subject to that table's RLS and could recurse.
-- can_edit_church_profile is included because it is the exact predicate
-- the existing UPDATE policies use -- anyone trusted to edit a church
-- is certainly allowed to read it.
--
-- ---------------------------------------------------------------------
-- PERFORMANCE, DELIBERATELY
--
-- This predicate runs per row over 22,887 of them, and function calls
-- default to a cost the planner takes seriously. Two things keep it
-- cheap:
--
--   * not is_hidden is first and is a plain column test, so the planner
--     puts it ahead of anything costing 100.
--   * every expensive call sits behind `(select auth.uid()) is not
--     null`. The subselect form is evaluated once as an InitPlan rather
--     than per row, and for a signed-out visitor -- which is most
--     traffic -- the whole branch is false immediately. For a signed-in
--     user the helpers only run on rows that are actually hidden.
--
-- If the directory gets slower after this, that branch is where to
-- look. The rollback is at the bottom.

do $$
declare
  rls_on boolean;
begin
  select relrowsecurity into rls_on from pg_class where oid = 'public.churches'::regclass;
  if not rls_on then
    raise exception 'ABORT: row level security is not enabled on churches, so no policy would do anything.';
  end if;
  if not exists (select 1 from pg_policies
                 where schemaname = 'public' and tablename = 'churches'
                   and policyname = 'churches are publicly readable') then
    raise exception 'ABORT: the policy this replaces is not there under that name. Re-read pg_policies before continuing.';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('is_church_staff_member','is_approved_church_member','can_edit_church_profile','is_platform_admin')
                 having count(distinct p.proname) = 4) then
    raise exception 'ABORT: one of the helper functions the policy calls is missing.';
  end if;
end $$;

drop policy if exists "churches are publicly readable" on churches;

create policy "churches are publicly readable" on churches
  for select to public
  using (
    not is_hidden
    or (
      (select auth.uid()) is not null
      and (
        owner_id = (select auth.uid())
        or is_platform_admin()
        or can_edit_church_profile(id)
        or is_church_staff_member(id)
        or is_approved_church_member(id)
      )
    )
  );

-- ---------------------------------------------------------------------
-- The only verification that means anything here is what an anon
-- actually sees. postgres is superuser and bypasses RLS entirely, so
-- counting as postgres would prove nothing; SET LOCAL ROLE anon makes
-- the policy apply. SET LOCAL ends with the transaction, and RESET ROLE
-- puts it back either way.
do $$
declare
  total       bigint;
  hidden      bigint;
  anon_sees   bigint;
  anon_hidden bigint;
begin
  select count(*), count(*) filter (where is_hidden) into total, hidden from churches;

  set local role anon;
  select count(*) into anon_sees from churches;
  select count(*) into anon_hidden from churches where is_hidden;
  reset role;

  raise notice 'churches: % rows, % hidden.', total, hidden;
  raise notice 'anon now sees % of them, of which % are hidden.', anon_sees, anon_hidden;

  if anon_hidden > 0 then
    raise exception 'VERIFY FAILED: anon can still read % hidden churches.', anon_hidden;
  end if;
  if anon_sees <> total - hidden then
    raise exception 'VERIFY FAILED: anon sees % but should see % (total minus hidden).', anon_sees, total - hidden;
  end if;

  raise notice 'OK. Hidden churches are no longer readable by anon.';
  raise notice 'Check the directory still lists churches and that the admin church panel still opens a hidden one.';
end $$;

-- ---------------------------------------------------------------------
-- ROLLBACK, if the directory misbehaves. This puts the leak back, so it
-- is a way to buy time, not a fix:
--
--   drop policy if exists "churches are publicly readable" on churches;
--   create policy "churches are publicly readable" on churches
--     for select to public using (true);
