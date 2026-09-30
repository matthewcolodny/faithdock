-- Run in Supabase SQL Editor.
--
-- profiles stops accepting writes from the browser roles.
--
-- ---------------------------------------------------------------------
-- WHAT WAS MEASURED
--
-- Section by section, from rls_coverage.probe.sql on 2026-09-30:
--
--   45 tables in public, 0 with RLS off, 0 with no policies.
--   No views running as their owner.
--
-- That is the good result, and it is why the wide default grants
-- (Supabase issues `grant all on all tables in public to anon,
-- authenticated` and makes RLS the gate) are not themselves the
-- finding. RLS is there and doing the job.
--
-- profiles is the exception worth closing. Its grants:
--
--   anon           INSERT, DELETE, TRUNCATE, REFERENCES  (no SELECT, no UPDATE)
--   authenticated  INSERT, DELETE, TRUNCATE, REFERENCES,
--                  SELECT on (id, full_name, age_range) only
--
-- INSERT is held on EVERY column, is_platform_admin included. Its
-- policies:
--
--   SELECT  "profiles are publicly readable"        using (true)
--   INSERT  "users can insert their own profile"    with check (auth.uid() = id)
--   UPDATE  "users can update their own profile"    using (auth.uid() = id)
--   DELETE  -- none --
--
-- ---------------------------------------------------------------------
-- WHAT IS AND IS NOT REACHABLE TODAY
--
-- Not reachable, and this migration is not what stops them:
--   * anon inserting anything. auth.uid() is null, so `auth.uid() = id`
--     is never true.
--   * anyone deleting a profile. RLS is on and there is NO delete
--     policy, so delete is denied whatever the grant says.
--   * anyone updating one. 012b revoked the UPDATE grant outright.
--
-- Reachable, and this is the reason for the migration: a SIGNED-IN
-- user whose profile row does not exist can insert their own, and the
-- policy's `auth.uid() = id` is satisfied by doing so -- it constrains
-- WHICH row, not WHICH COLUMNS. is_platform_admin = true is inside
-- that. The only thing standing in the way is the primary key
-- conflict with a row that a signup trigger is assumed to have
-- created. "A trigger has always worked" is not an access control.
--
-- ---------------------------------------------------------------------
-- WHY REVOKING IS SAFE
--
-- Nothing writes profiles from a browser role. Checked, not assumed:
--   * every `from('profiles')` in index.html is a .select(); there is
--     no .insert(), .upsert() or .delete() anywhere in it.
--   * no Edge Function writes profiles at all.
--   * delete-account.ts does its deleting through a service_role
--     client, which bypasses RLS and is unaffected by these grants.
--   * whatever creates the row on signup is a trigger, which runs as
--     its definer and is likewise unaffected.
--
-- Every legitimate write already goes through a SECURITY DEFINER
-- function -- the pattern 012b established for exactly this reason.
--
-- TRUNCATE goes too. It is not reachable through PostgREST, so this
-- changes nothing today, but it is the one privilege that IGNORES row
-- level security entirely: no policy could ever make it safe, so the
-- grant is the only place to address it.

do $$
begin
  if not (select relrowsecurity from pg_class where oid = 'public.profiles'::regclass) then
    raise exception 'ABORT: RLS is not enabled on profiles. Revoking grants would be the only protection left, which is not the state this assumes.';
  end if;
  if exists (select 1 from pg_policies
              where schemaname = 'public' and tablename = 'profiles' and cmd = 'DELETE') then
    raise exception 'ABORT: a DELETE policy on profiles now exists. Re-read it before revoking the grant -- something may have started relying on it.';
  end if;
end $$;

revoke insert, delete, truncate on public.profiles from anon;
revoke insert, delete, truncate on public.profiles from authenticated;

-- ---------------------------------------------------------------------
-- Verification. Catalog reads only: an admin RPC cannot be called from
-- the SQL Editor, where auth.uid() is null.
do $$
declare
  bad text;
begin
  select string_agg(grantee || ':' || privilege_type, ', ' order by grantee, privilege_type)
    into bad
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'profiles'
     and grantee in ('anon', 'authenticated')
     and privilege_type in ('INSERT', 'DELETE', 'TRUNCATE', 'UPDATE');

  if bad is not null then
    raise exception 'VERIFY FAILED: profiles still writable -- %', bad;
  end if;

  -- The read side must be untouched. authenticated reads three columns
  -- across rows for roughly fifteen shipped features (staff lists,
  -- group members, donations, registrations, insights); losing that
  -- would break them quietly.
  if (select count(*) from information_schema.column_privileges
       where table_schema = 'public' and table_name = 'profiles'
         and grantee = 'authenticated' and privilege_type = 'SELECT') <> 3 then
    raise exception 'VERIFY FAILED: authenticated no longer has SELECT on exactly the three expected columns.';
  end if;

  raise notice 'OK. anon and authenticated can no longer insert, delete or truncate profiles.';
  raise notice 'Read access is unchanged: authenticated still selects id, full_name, age_range.';
  raise notice 'Check next: sign up a new account and confirm its profile row is still created, and that the name shows on a group or staff list.';
end $$;

-- ---------------------------------------------------------------------
-- STILL OPEN AFTER THIS, both recorded rather than fixed here:
--
-- 1. "profiles are publicly readable" is `using (true)`. Reads are
--    gated by the COLUMN grants, not by that policy -- which works,
--    and is what 012b chose deliberately, but it means a single
--    `grant select on profiles to anon` would reopen every column
--    including is_platform_admin, with the policy raising no
--    objection. Tightening it needs care: authenticated genuinely
--    needs cross-row reads of those three columns.
--
-- 2. group_members' UPDATE policy has `with check true`. Its USING
--    correctly limits WHICH rows an owner, staff member or group
--    leader may update, but with check true leaves the RESULT
--    unconstrained -- so a leader may update a row they control and
--    change its group_id to a group they do not. Small, real, and a
--    separate migration.
--
-- ROLLBACK, if a new signup's profile row stops being created:
--
--   grant insert on public.profiles to authenticated;
--
-- Do that only to buy time, and find out what is doing the insert --
-- it should be a SECURITY DEFINER function or a trigger, and if it is
-- neither then the escalation path above is open again.
