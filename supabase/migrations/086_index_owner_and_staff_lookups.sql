-- Run in the Supabase SQL Editor.
--
-- Index the two columns the dashboard filters by on every single load.
--
-- BE CLEAR ABOUT WHAT THIS DOES AND DOES NOT FIX.
--
-- It is NOT the six-second request. That was measured, and the query
-- itself takes 0.42 ms warm and 111 ms on its first run in a session --
-- with an identical plan and identical buffer counts whether RLS is on
-- or off, so even the 111 ms is warm-up rather than policy. Six seconds
-- is not being spent in Postgres. This changes none of that.
--
-- What it fixes is a shape that gets worse as the directory grows. The
-- EXPLAIN for getMyChurch's first query says:
--
--   Seq Scan on churches  (rows=1)
--     Filter: (owner_id = '...'::uuid)
--     Rows Removed by Filter: 1286
--
-- One row wanted, 1286 read and thrown away, on every dashboard load,
-- for every signed-in person. At 1287 rows that costs 0.4 ms and does
-- not matter. This is a church directory that is imported into in
-- batches -- there is an idx_churches_import_batch_id in this schema,
-- so bulk import is an established fact about this table, not a
-- hypothetical. At a hundred thousand rows the same scan is seconds,
-- and it will arrive as "the dashboard got slow" with no obvious cause.
--
-- churches has eight indexes and none of them is on owner_id: there are
-- indexes for search (name and description trigrams), for the map (lat,
-- lng), for denomination tags, for dedupe and for import batches. Every
-- one of those serves the public directory. The column the OWNER's own
-- dashboard looks itself up by was the one nobody indexed.
--
-- church_staff has the same gap in a subtler form. It has a unique
-- index on (church_id, user_id), which cannot serve a lookup by
-- user_id alone -- user_id is the second column, so a query filtering
-- only on it scans. getMyChurch runs exactly that query twice per call.

-- ---------------------------------------------------------------------
-- CONCURRENTLY is deliberately NOT used. It cannot run inside a
-- transaction block, and the Supabase SQL Editor wraps a script in one.
-- These tables are small enough that a brief lock is nothing; on a
-- table where it mattered this would have to be run statement by
-- statement instead.
-- ---------------------------------------------------------------------
create index if not exists idx_churches_owner_id
  on churches (owner_id);

create index if not exists idx_church_staff_user_id
  on church_staff (user_id);

-- ---------------------------------------------------------------------
-- Verify, and show what changed. The planner needs current statistics
-- before it will believe the new index is worth using, so analyze
-- first -- otherwise this reports "still a seq scan" on a table it has
-- simply not looked at since.
-- ---------------------------------------------------------------------
analyze churches;
analyze church_staff;

do $verify$
declare
  n int;
begin
  select count(*) into n from pg_indexes
  where schemaname = 'public'
    and indexname in ('idx_churches_owner_id', 'idx_church_staff_user_id');
  if n <> 2 then
    raise exception 'VERIFY FAILED: expected both indexes, found %.', n;
  end if;
  raise notice 'OK: owner_id and user_id are indexed.';
end
$verify$;

-- The last statement returning rows is what the editor shows, so the
-- proof goes here rather than in a notice. Expect Index Scan rather
-- than Seq Scan -- though on 1287 rows the planner may still prefer a
-- sequential scan, which is a correct choice at this size and not a
-- failure. The index is for the size this table is heading towards.
explain (analyze, buffers)
select id, name from churches where owner_id = '00000000-0000-0000-0000-000000000000';
