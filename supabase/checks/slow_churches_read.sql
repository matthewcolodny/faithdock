-- Run in the Supabase SQL Editor. Reads only -- it writes nothing and
-- creates nothing that outlives your session.
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
-- returns in 150-220 ms every time, against all 1287 rows. So it is
-- neither the query nor the table size. The difference is what happens
-- to that query when the caller is `authenticated` rather than `anon`,
-- which means the row-level security policy.
--
-- An RLS policy is a WHERE clause the database adds to every query. If
-- it calls a function, that function can run once per row unless the
-- planner can prove otherwise. Over 1287 rows, a policy that is cheap
-- at one row is not cheap here.
--
-- This script does not assume that. It measures it.
--
-- TWO NOTES ON ITS SHAPE, both learned the hard way on this one file:
--
-- The editor shows only the LAST statement that returns rows, so
-- everything comes back as a single result set with a `section` column.
-- An earlier version ended in ROLLBACK and therefore showed nothing.
--
-- It is a function in pg_temp rather than a temp table, because the
-- editor's linter -- correctly, in general -- warns about CREATE TABLE
-- without RLS and about TRUNCATE. A temp table was harmless here (it
-- lives in pg_temp, dies with the session, and PostgREST cannot see
-- it), but a probe should not make you weigh a warning before you can
-- read it. pg_temp.<name> is dropped when you disconnect.

create or replace function pg_temp.slow_churches_probe()
returns table(section text, ord int, detail text)
language plpgsql
as $fn$
declare
  -- Change this to test as somebody else.
  test_email text := 'matthewcolodny@gmail.com';
  uid        uuid;
  line       text;
  as_user    text[] := '{}';
  as_owner   text[] := '{}';
  i          int;
  q          text;
begin
  -- -------------------------------------------------------------------
  -- 1. The policies on the tables getMyChurch reads. A policy whose
  --    USING clause calls a function is the first suspect.
  -- -------------------------------------------------------------------
  for section, ord, detail in
    select '1. policies',
           (row_number() over (order by p.tablename, p.cmd, p.policyname))::int,
           p.tablename || '  [' || p.cmd || ', ' || p.roles::text || ']  ' || p.policyname
             || '   USING ' || coalesce(p.qual, '(none)')
    from pg_policies p
    where p.schemaname = 'public' and p.tablename in ('churches', 'church_staff')
  loop
    return next;
  end loop;

  -- -------------------------------------------------------------------
  -- 2. The indexes. A sequential scan over 1287 rows is cheap on its
  --    own -- but not with a per-row function attached to each row.
  -- -------------------------------------------------------------------
  for section, ord, detail in
    select '2. indexes',
           (row_number() over (order by x.tablename, x.indexname))::int,
           x.tablename || '  ' || x.indexdef
    from pg_indexes x
    where x.schemaname = 'public' and x.tablename in ('churches', 'church_staff')
  loop
    return next;
  end loop;

  -- -------------------------------------------------------------------
  -- 3 and 4. The measurement, and its control.
  --
  -- The real query run twice: once as a signed-in user with RLS
  -- applied, once as the owner with RLS bypassed. One slow and one fast
  -- localises the cost to the policy. Both fast rules this database out
  -- entirely.
  -- -------------------------------------------------------------------
  select u.id into uid from auth.users u where u.email = test_email;
  if uid is null then
    section := '3. ERROR'; ord := 1;
    detail  := 'No auth.users row for ' || test_email || '. Edit test_email at the top of this function.';
    return next;
    return;
  end if;

  q := format(
    'explain (analyze, buffers) select id, name, denomination, plan_type, '
    || 'logo_url, subscription_status from churches where owner_id = %L order by name',
    uid);

  -- As the signed-in user: exactly what PostgREST does for a request
  -- carrying their JWT -- the role, plus the claims auth.uid() reads.
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('role', 'authenticated', 'sub', uid)::text);
  for line in execute q loop as_user := as_user || line; end loop;

  -- Back to the owner, where RLS does not apply.
  execute 'reset role';
  execute 'set local request.jwt.claims = ' || quote_literal('{}');
  for line in execute q loop as_owner := as_owner || line; end loop;

  section := '3. as authenticated (RLS on)'; ord := 0;
  detail  := '--- uid ' || uid || ' ---';
  return next;
  for i in 1 .. coalesce(array_length(as_user, 1), 0) loop
    section := '3. as authenticated (RLS on)'; ord := i; detail := as_user[i];
    return next;
  end loop;
  for i in 1 .. coalesce(array_length(as_owner, 1), 0) loop
    section := '4. as owner (RLS bypassed)'; ord := i; detail := as_owner[i];
    return next;
  end loop;
end
$fn$;

-- ---------------------------------------------------------------------
-- The one result. Send back section 3's "Execution Time" line, section
-- 4's, and any line in section 3 containing "Filter" or a function
-- name.
--
-- If 3 is slow and 4 is fast, the policy is the cost, and the fix is to
-- make its own lookup indexed or to wrap it in a STABLE function so the
-- planner runs it once rather than 1287 times.
--
-- If both are fast, nothing in this database is slow and the six
-- seconds are being spent between the browser and Supabase -- which is
-- where auth/v1/user at 1419 ms in the same timeline also points, and
-- that is their auth service rather than anything in this schema.
-- ---------------------------------------------------------------------
select * from pg_temp.slow_churches_probe();
