-- Run in Supabase SQL Editor. Run 117 and 118 first.
--
-- The two things the RLS sweep found and left.
--
-- ---------------------------------------------------------------------
-- 1. profiles: the policy stops saying "true"
--
-- Measured 2026-09-30:
--
--   policy  "profiles are publicly readable"  SELECT  using (true)
--   anon           no SELECT grant at all
--   authenticated  SELECT on id, full_name, age_range -- and nothing else
--
-- Reads are gated by the COLUMN GRANTS, not by the policy. That works,
-- and 012b chose it deliberately, because roughly fifteen shipped
-- features need cross-row reads of those three columns -- staff lists,
-- group member lists, donation and registration names, insights. A
-- policy of `auth.uid() = id` would break every one of them.
--
-- What is wrong with it is that a single
--
--   grant select on profiles to anon;
--
-- typed by anyone, at any point, would reopen every column of every
-- row -- phone, avatar_url, is_platform_admin -- and the policy would
-- raise no objection, because it has no opinion. One grant is the
-- whole distance between here and a full disclosure.
--
-- So the policy gets the opinion it was missing: you have to be signed
-- in. That is the weakest true statement about who may read this
-- table, it breaks none of the fifteen features (all of them run
-- signed in), and it means the grant above would no longer be
-- sufficient on its own.
--
-- Nothing changes for anon today. It has no SELECT grant, so it reads
-- nothing now and reads nothing after -- including the one profile
-- read that sits on a public page (a group's creator name), which
-- already comes back empty when signed out and is already written to
-- carry on without it.
--
-- The name goes too. "profiles are publicly readable" would be a lie
-- about what the policy does, and the next person to read the list is
-- entitled to believe the names.
--
-- PERFORMANCE: (select auth.uid()) rather than auth.uid(), so the
-- planner evaluates it once as an InitPlan instead of per row. Same
-- reason 116 is written that way.

do $$
begin
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'profiles'
                    and policyname = 'profiles are publicly readable') then
    raise exception 'ABORT: the profiles SELECT policy is not there under that name. Re-read pg_policies before continuing.';
  end if;

  -- If anon has been granted SELECT since this was measured, something
  -- started relying on signed-out reads and this would break it.
  if exists (select 1 from information_schema.column_privileges
              where table_schema = 'public' and table_name = 'profiles'
                and grantee = 'anon' and privilege_type = 'SELECT') then
    raise exception 'ABORT: anon now has a SELECT grant on profiles. Find out what needs it before requiring a session.';
  end if;
end $$;

drop policy if exists "profiles are publicly readable" on profiles;

create policy "signed-in users can read profiles" on profiles
  for select to public
  using ((select auth.uid()) is not null);

-- ---------------------------------------------------------------------
-- 2. group_members: the result of an update has to pass the same test
--    as the row it started from
--
-- Measured: the UPDATE policy's USING correctly asks whether you are
-- the church owner, a staff member with can_manage_groups, or a leader
-- of that group -- and its WITH CHECK is `true`.
--
-- USING decides which rows you may touch. WITH CHECK decides what they
-- may become. With it set to true, a group leader may take a
-- membership row they legitimately control and rewrite its group_id to
-- a group they have nothing to do with -- moving a person into it, or
-- out of their own group and into somebody else's.
--
-- WITH CHECK is dropped rather than restated. Postgres then uses USING
-- for both, which is the behaviour wanted here and, more to the point,
-- makes it impossible for the two to drift apart later.
--
-- Nothing legitimate changes. Every group_members update in the client
-- sets status or role on a row in a group the actor already manages --
-- checked, not assumed: `.update({ status: 'active' })`,
-- `.update({ role: 'leader' })`, `.update({ role: 'member' })`, and
-- two upserts whose group_id is the group being managed. group_id is
-- never rewritten by the app, so the new predicate never fires on a
-- real call. Moving somebody between groups is a delete and an insert.

do $$
declare
  n int;
begin
  select count(*) into n from pg_policies
   where schemaname = 'public' and tablename = 'group_members'
     and policyname = 'owner, staff, or leaders can update membership';
  if n <> 1 then
    raise exception 'ABORT: expected exactly one policy by that name on group_members, found %.', n;
  end if;
end $$;

do $$
declare
  using_expr text;
  role_list  text;
begin
  -- Rebuilt from the live USING rather than retyped from the probe
  -- output, so the predicate cannot be subtly different from the one
  -- working today. The role list is carried over the same way rather
  -- than assumed to be `public` -- recreating a policy against the
  -- wrong roles is how one silently stops applying. Only the WITH
  -- CHECK changes.
  select qual, array_to_string(roles, ', ')
    into using_expr, role_list
    from pg_policies
   where schemaname = 'public' and tablename = 'group_members'
     and policyname = 'owner, staff, or leaders can update membership';

  if using_expr is null or role_list is null or role_list = '' then
    raise exception 'ABORT: could not read the live USING or roles off that policy.';
  end if;

  raise notice 'Rebuilding group_members UPDATE for role(s): %', role_list;

  execute 'drop policy "owner, staff, or leaders can update membership" on group_members';
  execute 'create policy "owner, staff, or leaders can update membership" on group_members'
        || ' for update to ' || role_list
        || ' using (' || using_expr || ')';
end $$;

-- ---------------------------------------------------------------------
-- Verification. Catalog only. A functional test cannot be done from
-- here: auth.uid() is null in the SQL Editor, so even SET ROLE
-- authenticated would fail the new profiles predicate and prove
-- nothing about a real session.
do $$
declare
  p_qual  text;
  g_check text;
  n_cols  int;
begin
  -- By name, not by cmd: another SELECT policy could exist, and
  -- `select into` across two rows would pick one arbitrarily and
  -- report on whichever it happened to get.
  select qual into p_qual from pg_policies
   where schemaname = 'public' and tablename = 'profiles'
     and policyname = 'signed-in users can read profiles';

  if p_qual is null or p_qual = 'true' then
    raise exception 'VERIFY FAILED: the profiles SELECT policy is still unconditional. Got: %', coalesce(p_qual, 'null');
  end if;

  if exists (select 1 from pg_policies
              where schemaname = 'public' and tablename = 'profiles'
                and policyname = 'profiles are publicly readable') then
    raise exception 'VERIFY FAILED: the old policy name is still present.';
  end if;

  -- The three column grants are what the fifteen features actually
  -- read through. Losing them would break those quietly.
  select count(*) into n_cols from information_schema.column_privileges
   where table_schema = 'public' and table_name = 'profiles'
     and grantee = 'authenticated' and privilege_type = 'SELECT';
  if n_cols <> 3 then
    raise exception 'VERIFY FAILED: authenticated has SELECT on % columns of profiles, expected 3.', n_cols;
  end if;

  select with_check into g_check from pg_policies
   where schemaname = 'public' and tablename = 'group_members'
     and policyname = 'owner, staff, or leaders can update membership';

  if g_check is not null and g_check = 'true' then
    raise exception 'VERIFY FAILED: group_members UPDATE still has WITH CHECK true.';
  end if;

  raise notice 'OK. profiles requires a session: %', p_qual;
  raise notice 'OK. group_members UPDATE now checks the result too (with_check: %).', coalesce(g_check, 'inherits USING');
  raise notice 'Check next, signed in: a group member list still shows names, a staff list still shows names, and approving or promoting a group member still works.';
end $$;

-- ---------------------------------------------------------------------
-- ROLLBACK, if a signed-in page stops showing names or a group admin
-- action starts failing:
--
--   drop policy if exists "signed-in users can read profiles" on profiles;
--   create policy "profiles are publicly readable" on profiles
--     for select to public using (true);
--
-- and for the second, re-add the permissive check:
--
--   (re-run the block above, appending  with check (true)  to the
--    create -- but find out first WHAT is rewriting group_id, because
--    nothing in the app should be.)
