-- READ ONLY. Run in the Supabase SQL Editor and paste the output back.
--
-- WHY THIS EXISTS
--
-- The previous probe's last query came back with this, and it is the
-- part that matters:
--
--   anon,DELETE          authenticated,DELETE
--   anon,INSERT          authenticated,INSERT
--   anon,REFERENCES      authenticated,REFERENCES
--   anon,TRIGGER         authenticated,TRIGGER
--   anon,TRUNCATE        authenticated,TRUNCATE
--
-- anon holds DELETE, INSERT and TRUNCATE on public.profiles.
--
-- Migration 012b revoked the SELECT and UPDATE grants after finding
-- both wide open. It did not touch these, and they were never part of
-- that fix -- so this is the same hole's other half, sitting there
-- since before 012b was written.
--
-- How bad it is depends entirely on one thing this does not yet know:
-- whether row level security is ON for profiles and what it says about
-- INSERT and DELETE.
--
--   * DELETE and INSERT are reachable over the REST API. If RLS is off,
--     or if a permissive policy allows them, an unauthenticated caller
--     can delete profile rows. That is the serious case.
--   * TRUNCATE is NOT reachable over PostgREST, so it is not exploitable
--     through the app -- but TRUNCATE also IGNORES row level security
--     entirely, so it is the one grant no policy can make safe, and it
--     should not be held by anon whatever the answer below is.
--   * REFERENCES and TRIGGER are schema-level and not a data path.
--
-- Nothing here writes, and nothing here touches a real row -- the point
-- is to find out whether a write WOULD be refused, not to try one.

-- 1 -------------------------------------------------------------------
-- The question that decides everything. rls_enabled false means the
-- grants above are the whole story and anon can delete profiles.
select relname,
       relrowsecurity  as rls_enabled,
       relforcerowsecurity as rls_forced
  from pg_class
 where oid = 'public.profiles'::regclass;

-- 2 -------------------------------------------------------------------
-- Every policy on profiles, with the command each one covers.
-- Permissive policies OR together, so one permissive INSERT or DELETE
-- policy of using(true) is all it takes -- and a table with RLS on and
-- NO policy for a command denies it, which would be the good outcome.
select policyname, cmd, permissive, roles, qual as using_expr, with_check
  from pg_policies
 where schemaname = 'public' and tablename = 'profiles'
 order by cmd, policyname;

-- 3 -------------------------------------------------------------------
-- Would a delete actually be refused? Asked as a PLAN, not as a delete.
-- With RLS in force and nothing permitting it, the policy collapses the
-- scan to a One-Time Filter: false and the plan says so out loud.
-- EXPLAIN without ANALYZE executes nothing, the id matches no row
-- either way, and the rollback puts the role back even if it throws.
begin;
set local role anon;
explain (costs off)
  delete from profiles where id = '00000000-0000-0000-0000-000000000000';
rollback;

-- 4 -------------------------------------------------------------------
-- The column-level grants the previous probe also asked for and the
-- paste cut off. 012b split profiles into "readable across rows" and
-- "your own row only, via a SECURITY DEFINER function", and this is
-- what actually survived.
select grantee, privilege_type, column_name
  from information_schema.column_privileges
 where table_schema = 'public' and table_name = 'profiles'
   and grantee in ('anon', 'authenticated')
 order by grantee, privilege_type, column_name;

-- 5 -------------------------------------------------------------------
-- And whether any OTHER table carries the same leftover. If profiles
-- was granted these by a blanket "grant all on all tables" at some
-- point, it will not be the only one.
select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type) as privs
  from information_schema.role_table_grants
 where table_schema = 'public'
   and grantee = 'anon'
   and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
 group by table_name, grantee
 order by table_name;
