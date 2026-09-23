-- Run in the Supabase SQL Editor. Diagnostic only -- it changes nothing.
--
-- WHY THIS EXISTS
--
-- A dashboard load was timed in the browser. One request stood out:
--
--   NET rest/v1/churches   took 6470 ms
--
-- with about five requests in flight. That is not queueing; that is one
-- query taking six and a half seconds.
--
-- The same query SHAPE, measured from outside as the `anon` role,
-- returns in 150-220 ms every time:
--
--   select id, name, denomination, plan_type, logo_url,
--          subscription_status
--   from churches where owner_id = <uuid> order by name
--
-- So the difference is not the query and not the table size (1287
-- rows). It is what happens to that query when the caller is
-- `authenticated` rather than `anon` -- which means the row-level
-- security policy.
--
-- An RLS policy is a WHERE clause the database adds to every query. If
-- it calls a function, that function runs per row unless the planner
-- can prove otherwise. Over 1287 rows, a policy that is cheap at one
-- row is not cheap here.
--
-- This script does not assume that. It measures it.

-- ---------------------------------------------------------------------
-- 1. What policies are on the tables getMyChurch reads, and what do
--    they actually say? A policy that mentions a function name is the
--    first thing to look at.
-- ---------------------------------------------------------------------
select
  tablename,
  policyname,
  cmd,
  roles::text as applies_to,
  coalesce(qual, '(none)') as using_clause
from pg_policies
where schemaname = 'public'
  and tablename in ('churches', 'church_staff')
order by tablename, cmd, policyname;

-- ---------------------------------------------------------------------
-- 2. Is the column actually indexed? A sequential scan over 1287 rows
--    is fast on its own -- but not once a per-row function is attached
--    to each of those rows.
-- ---------------------------------------------------------------------
select
  tablename,
  indexname,
  indexdef
from pg_indexes
where schemaname = 'public'
  and tablename in ('churches', 'church_staff')
order by tablename, indexname;

-- ---------------------------------------------------------------------
-- 3. The measurement. Runs the real query as a real signed-in user,
--    with RLS on, and reports where the time goes.
--
-- Change the email on the first line if you want to test as somebody
-- else. Everything runs inside a transaction that is rolled back, so
-- the role switch and the claims do not outlive this script.
-- ---------------------------------------------------------------------
do $measure$
declare
  test_email text := 'matthewcolodny@gmail.com';
  test_uid   uuid;
  plan_line  text;
begin
  select id into test_uid from auth.users where email = test_email;
  if test_uid is null then
    raise exception 'No auth.users row for %. Edit test_email at the top of section 3.', test_email;
  end if;
  raise notice 'Measuring as % (%)', test_email, test_uid;
end
$measure$;

begin;

-- Become that user, exactly as PostgREST would for a request carrying
-- their JWT: the role plus the claims RLS reads auth.uid() out of.
set local role authenticated;
set local request.jwt.claims = '{"role":"authenticated","sub":"REPLACE_WITH_UID"}';

-- The query getMyChurch sends, verbatim.
explain (analyze, buffers, verbose)
select id, name, denomination, plan_type, logo_url, subscription_status
from churches
where owner_id = (current_setting('request.jwt.claims', true)::json ->> 'sub')::uuid
order by name;

rollback;

-- ---------------------------------------------------------------------
-- HOW TO READ SECTION 3
--
-- "Execution Time" at the bottom is the answer. If it is a few
-- milliseconds, the slowness is not in this query and the next place to
-- look is the network or the auth service (auth/v1/user was also
-- measured at 1419 ms in the same browser timeline, and that is
-- Supabase's own service rather than anything in this database).
--
-- If it is seconds, look for a line containing "Filter:" or
-- "Subplan" that names a function, and for "rows removed by filter"
-- with a large number. That is the policy running per row, and the fix
-- is to make the policy's own lookup indexed -- or to wrap it in a
-- stable SECURITY DEFINER function so the planner runs it once instead
-- of 1287 times.
--
-- NOTE ON THE PLACEHOLDER: `set local` will not take a variable, so
-- REPLACE_WITH_UID above has to be pasted in by hand. Section 3's first
-- block prints the uuid to copy.
-- ---------------------------------------------------------------------
