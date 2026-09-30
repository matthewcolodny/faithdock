-- READ ONLY. Run in the Supabase SQL Editor and paste the output back.
--
-- CORRECTING THE LAST PROBE'S PREMISE
--
-- profiles_write_grants.probe.sql was written on the assumption that
-- anon holding DELETE/INSERT/TRUNCATE on profiles was a leftover from
-- an incomplete fix. Its own query 5 disproved that: all 39 tables in
-- public carry the identical set.
--
--   church_billing, churches, donations, events, groups, message_log,
--   profiles, ... -> DELETE, INSERT, TRUNCATE, UPDATE
--
-- That is Supabase's default. The platform issues
--
--   grant all on all tables in schema public to anon, authenticated;
--
-- and makes row level security the entire gate. Wide grants are the
-- expected posture, not the bug.
--
-- profiles is in fact the ODD ONE OUT -- it is the only table missing
-- UPDATE, and it has no SELECT either, because migration 012b revoked
-- both. Everything else is stock.
--
-- So the question is not "who has grants". It is: does every table
-- those grants reach actually have RLS on, with policies that say
-- something? One table with RLS off is a table anon can read, write
-- and empty over the REST API.
--
-- Nothing here writes.

-- 1 -------------------------------------------------------------------
-- THE ONE THAT MATTERS. Every table in public, whether RLS is on, and
-- how many policies it has. Anything with rls_enabled = false is
-- directly exposed; anything with RLS on and 0 policies denies
-- everything to anon and authenticated, which is safe but is often
-- accidental rather than meant.
select c.relname                                   as table_name,
       c.relrowsecurity                            as rls_enabled,
       c.relforcerowsecurity                       as rls_forced,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname) as policy_count
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r'
 order by c.relrowsecurity asc, policy_count asc, c.relname;

-- 2 -------------------------------------------------------------------
-- Write policies that let anon through. A permissive INSERT, UPDATE or
-- DELETE policy whose USING/WITH_CHECK is true, applying to public or
-- anon, is the shape that turns a default grant into an open door.
-- Reading these is the point -- a few may be legitimate (contact
-- messages, error logs, waitlist signups all take anonymous inserts).
select tablename, policyname, cmd, permissive, roles,
       qual as using_expr, with_check
  from pg_policies
 where schemaname = 'public'
   and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
   and (roles::text like '%anon%' or roles::text like '%public%')
 order by tablename, cmd, policyname;

-- 3 -------------------------------------------------------------------
-- profiles specifically, which the last probe never got to answer
-- because its query 3 errored and took the batch with it.
select relname, relrowsecurity as rls_enabled, relforcerowsecurity as rls_forced
  from pg_class where oid = 'public.profiles'::regclass;

select policyname, cmd, permissive, roles, qual as using_expr, with_check
  from pg_policies
 where schemaname = 'public' and tablename = 'profiles'
 order by cmd, policyname;

-- 4 -------------------------------------------------------------------
-- The column-level grants on profiles that 012b left in place, which
-- the earlier paste cut off.
select grantee, privilege_type, column_name
  from information_schema.column_privileges
 where table_schema = 'public' and table_name = 'profiles'
   and grantee in ('anon', 'authenticated')
 order by grantee, privilege_type, column_name;

-- 5 -------------------------------------------------------------------
-- Views are worth one look of their own: a view owned by a superuser
-- runs with the owner's rights and can hand back rows from a table
-- whose RLS would otherwise have refused them. security_invoker fixes
-- that, and Postgres 15+ defaults it OFF.
select c.relname as view_name,
       coalesce((
         select option_value from pg_options_to_table(c.reloptions)
          where option_name = 'security_invoker'
       ), 'not set') as security_invoker
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'v'
 order by c.relname;
