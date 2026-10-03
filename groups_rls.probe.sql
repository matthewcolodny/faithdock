-- READ ONLY. Run in the Supabase SQL Editor and paste the output back.
--
-- Measured from the browser, signed out, against the seeded groups:
--
--   select on groups      -> 8 rows, INCLUDING the members-only one,
--                            with its name and description
--   search_groups(...)    -> 7 rows, members-only correctly excluded
--
-- The RPC filters and RLS does not. This is the same hole migration 113
-- closed on churches.is_hidden.
--
-- events is included as the CONTROL, not as a second suspect: the same
-- signed-out test returns 0 rows from a direct select on events, so
-- that table already has a policy that works. If it does, groups should
-- copy its shape rather than invent one.
--
-- Why probe instead of writing the migration now: permissive policies
-- OR together. If groups already has a permissive SELECT policy of
-- using (true), a stricter policy added beside it changes nothing at
-- all -- every row still comes through the old one. 113 only worked
-- because it REPLACED the old policy by name, and I need that name.

-- 1 -------------------------------------------------------------------
-- Every policy on groups, and on events for comparison. permissive vs
-- restrictive and the exact USING body decide add-versus-replace.
select tablename, policyname, cmd, permissive, roles, qual as using_expr, with_check
  from pg_policies
 where schemaname = 'public' and tablename in ('groups', 'events')
 order by tablename, cmd, policyname;

-- 2 -------------------------------------------------------------------
-- RLS actually on, and forced? A policy on a table with RLS off does
-- nothing at all.
select relname, relrowsecurity as rls_enabled, relforcerowsecurity as rls_forced
  from pg_class
 where oid in ('public.groups'::regclass, 'public.events'::regclass);

-- 3 -------------------------------------------------------------------
-- Table grants. If anon has broad SELECT on groups, this is where it
-- comes from, and column-level grants would show here too.
select table_name, grantee, privilege_type
  from information_schema.role_table_grants
 where table_schema = 'public' and table_name in ('groups', 'events')
   and grantee in ('anon', 'authenticated')
 order by table_name, grantee, privilege_type;

-- 4 -------------------------------------------------------------------
-- Definer or invoker. prosecdef = true bypasses RLS entirely, which
-- decides whether fixing the policy changes what the lists show.
select p.proname, p.prosecdef as security_definer,
       pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('search_groups', 'search_events', 'is_platform_admin',
                     'is_approved_church_member', 'is_church_staff_member')
 order by p.proname;

-- 5 -------------------------------------------------------------------
-- What the fixed policy has to keep working, in numbers. Signed out,
-- the right answer for "readable" is the public count.
select
  count(*)                                        as groups_total,
  count(*) filter (where visibility = 'public')   as public_groups,
  count(*) filter (where visibility = 'members')  as members_only_groups,
  count(distinct church_id)                       as churches_with_groups
from groups;
