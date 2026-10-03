-- READ ONLY. Run in the Supabase SQL Editor and paste the output back.
--
-- Confirmed from the browser, signed out, before writing any of this:
-- an anon select on churches returns all 22,887 rows, 487 of them
-- is_hidden = true, names and every other column included. Hiding a
-- church hides it from the UI and from nobody else.
--
-- The fix is a SELECT policy. What I must not do is write one blind:
--
--   * Permissive policies OR together. If churches already has a
--     permissive SELECT policy of `using (true)`, adding a stricter one
--     beside it changes nothing at all -- the existing one still lets
--     every row through. The fix is then to REPLACE that policy, not to
--     add to it, and I need its exact name and body to do that.
--
--   * The policy has to keep four groups working: anon reading the
--     directory, an owner seeing their own church even when hidden,
--     staff and members of a church, and the platform admin's church
--     detail panel -- which is a direct table select (index.html:44867),
--     not an RPC, so RLS applies to it.
--
--   * Whether search_churches is SECURITY DEFINER decides whether the
--     directory listing is affected at all. Definer bypasses RLS; the
--     leak is then only via direct selects, and the listing keeps
--     working untouched. Invoker means RLS applies and the same policy
--     fixes the listing too.
--
--   * A policy that subqueries church_staff or church_memberships is
--     itself subject to those tables' RLS and can recurse. If there is
--     already a SECURITY DEFINER helper for "am I staff/member of this
--     church", I want to call that instead of hand-rolling one.

-- 1 -------------------------------------------------------------------
-- Every policy on churches. permissive vs restrictive and the exact
-- USING body are the two things that decide add-versus-replace.
select policyname, cmd, permissive, roles,
       pg_get_expr(pol.polqual,  pol.polrelid) as using_expr,
       pg_get_expr(pol.polwithcheck, pol.polrelid) as with_check_expr
  from pg_policies pp
  join pg_policy pol on pol.polname = pp.policyname
  join pg_class  cls on cls.oid = pol.polrelid and cls.relname = pp.tablename
 where pp.schemaname = 'public' and pp.tablename = 'churches'
 order by cmd, policyname;

-- 2 -------------------------------------------------------------------
-- Is RLS actually on, and is it forced for the table owner too?
select relname, relrowsecurity as rls_enabled, relforcerowsecurity as rls_forced
  from pg_class where oid = 'public.churches'::regclass;

-- 3 -------------------------------------------------------------------
-- Table-level grants. A policy cannot take back a grant that was never
-- needed; if anon has broad SELECT this is where it comes from.
select grantee, privilege_type
  from information_schema.role_table_grants
 where table_schema = 'public' and table_name = 'churches'
 order by grantee, privilege_type;

-- 4 -------------------------------------------------------------------
-- Definer or invoker, for every function that reads churches on a
-- public path. prosecdef = true means it bypasses RLS.
select p.proname, p.prosecdef as security_definer,
       pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('search_churches', 'search_events', 'is_platform_admin')
 order by p.proname;

-- 5 -------------------------------------------------------------------
-- Any existing helper for "does this user belong to this church".
-- If one of these exists I call it rather than writing a subquery that
-- RLS on church_staff would then apply to in turn.
select p.proname, p.prosecdef as security_definer,
       pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and (p.proname ilike '%church_member%' or p.proname ilike '%church_staff%'
        or p.proname ilike '%is_member%'  or p.proname ilike '%has_church%'
        or p.proname ilike '%church_role%' or p.proname ilike '%my_church%')
 order by p.proname;
