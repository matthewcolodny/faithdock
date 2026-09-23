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
-- EVERYTHING COMES BACK AS ONE TABLE AT THE END. The editor only shows
-- the last statement that returns rows -- the previous version of this
-- script ended in ROLLBACK and therefore showed nothing at all, which
-- is entirely my fault. Read the `section` column to tell the parts
-- apart.

create temp table if not exists diag(section text, ord int, detail text);
truncate diag;

-- ---------------------------------------------------------------------
-- 1. The policies on the tables getMyChurch reads.
--    A policy whose USING clause calls a function is the first suspect.
-- ---------------------------------------------------------------------
insert into diag
select '1. policies', row_number() over (order by tablename, cmd, policyname),
       tablename || '  [' || cmd || ', ' || roles::text || ']  ' || policyname
         || '  USING ' || coalesce(qual, '(none)')
from pg_policies
where schemaname = 'public' and tablename in ('churches', 'church_staff');

-- ---------------------------------------------------------------------
-- 2. The indexes. A sequential scan over 1287 rows is cheap on its own
--    -- but not with a per-row function attached to each of them.
-- ---------------------------------------------------------------------
insert into diag
select '2. indexes', row_number() over (order by tablename, indexname),
       tablename || '  ' || indexdef
from pg_indexes
where schemaname = 'public' and tablename in ('churches', 'church_staff');

-- ---------------------------------------------------------------------
-- 3 and 4. The measurement.
--
-- The real query, run twice: once as a real signed-in user with RLS
-- applied, and once as the table owner with RLS bypassed. The second is
-- the control. If they are both fast, the policy is not the problem and
-- the time is going somewhere outside this database. If only the first
-- is slow, the gap between them IS the policy, measured rather than
-- argued.
--
-- The role switch happens inside the block and is reset before
-- anything is written, so the plan lines are collected as the role that
-- owns the temp table.
-- ---------------------------------------------------------------------
do $measure$
declare
  test_email text := 'matthewcolodny@gmail.com';
  uid        uuid;
  line       text;
  as_user    text[] := '{}';
  as_owner   text[] := '{}';
  i          int;
  q          text;
begin
  select id into uid from auth.users where email = test_email;
  if uid is null then
    raise exception 'No auth.users row for %. Edit test_email at the top of this block.', test_email;
  end if;

  q := format(
    'explain (analyze, buffers) select id, name, denomination, plan_type, '
    || 'logo_url, subscription_status from churches where owner_id = %L order by name',
    uid);

  -- ---- as the signed-in user, RLS on -------------------------------
  -- Exactly what PostgREST does for a request carrying their JWT: the
  -- role, plus the claims that auth.uid() reads out of.
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('role', 'authenticated', 'sub', uid)::text);
  for line in execute q loop as_user := as_user || line; end loop;

  -- ---- back to the owner, RLS bypassed -----------------------------
  execute 'reset role';
  execute 'set local request.jwt.claims = ' || quote_literal('{}');
  for line in execute q loop as_owner := as_owner || line; end loop;

  insert into diag values ('3. as authenticated (RLS on)', 0, '--- uid ' || uid || ' ---');
  for i in 1 .. coalesce(array_length(as_user, 1), 0) loop
    insert into diag values ('3. as authenticated (RLS on)', i, as_user[i]);
  end loop;
  for i in 1 .. coalesce(array_length(as_owner, 1), 0) loop
    insert into diag values ('4. as owner (RLS bypassed)', i, as_owner[i]);
  end loop;
end
$measure$;

-- ---------------------------------------------------------------------
-- The one result. Send back section 3's "Execution Time" line, section
-- 4's, and any line in section 3 containing "Filter" or a function
-- name.
--
-- If 3 is slow and 4 is fast, the policy is the cost and the fix is to
-- make its own lookup indexed, or to wrap it in a STABLE function so
-- the planner runs it once rather than 1287 times.
--
-- If both are fast, nothing here is slow and the six seconds are being
-- spent between the browser and the database -- which is where
-- auth/v1/user at 1419 ms in the same timeline also points, and that is
-- Supabase's own service rather than anything in this schema.
-- ---------------------------------------------------------------------
select section, ord, detail from diag order by section, ord;
