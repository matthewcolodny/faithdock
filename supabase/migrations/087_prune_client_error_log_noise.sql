-- Run in the Supabase SQL Editor.
--
-- THIS ONE DELETES ROWS. Read the next paragraph before running it.
--
-- It removes rows from client_error_logs whose message is exactly
-- "Script error." or contains "TurnstileError" / "[Cloudflare
-- Turnstile]". Nothing else is touched, no other table is touched, and
-- it prints the before and after counts so you can see exactly what
-- went. These are diagnostic logs this app wrote about itself, not
-- anybody's data.
--
-- WHY
--
-- The table held 16,517 rows and pg_stat_user_tables recorded 15.3
-- MILLION rows walked across 2,822 sequential scans. Of those rows:
--
--   Script error.                        x8373
--   Uncaught TurnstileError: ...110200   x7706
--   ...plus 200 more Turnstile errors
--   ------------------------------------------
--   16,279 of 16,519 -- 99 percent
--
-- Neither is actionable. "Script error." is what a browser reports for
-- an exception inside a cross-origin script: no message, no stack, no
-- file, no line. It is the ABSENCE of an error report, stored 8,373
-- times. Turnstile's errors are Cloudflare's widget reporting on
-- itself, numbered by Cloudflare, already in the console.
--
-- WHY IT IS WORTH DELETING RATHER THAN IGNORING
--
-- This database has 500 MB of shared RAM. Every page of this table
-- that gets scanned is a page of buffer cache not holding something
-- useful -- and the two functions that turned out to be slow measure
-- 75 ms and 54 ms warm against recorded means of 1570 ms and 1536 ms.
-- That twenty-fold gap is cache misses, not bad SQL. Sixteen thousand
-- junk rows being walked fifteen million times is a direct contributor
-- to it.
--
-- The client stopped writing these in build 2026-09-23-v229, and its
-- dedup now persists across page loads -- which is the part that
-- actually mattered, since the old 60-second window was reset by every
-- refresh and both of these errors happen once per load, forever.
-- Without that change this table would simply refill.

-- ---------------------------------------------------------------------
-- Before.
-- ---------------------------------------------------------------------
do $before$
declare
  total int; noise int;
begin
  select count(*) into total from client_error_logs;
  select count(*) into noise from client_error_logs
  where trim(message) in ('Script error.', 'Script error')
     or message like '%TurnstileError%'
     or message like '%[Cloudflare Turnstile]%';
  raise notice 'Before: % rows, % of them noise.', total, noise;
end
$before$;

delete from client_error_logs
where trim(message) in ('Script error.', 'Script error')
   or message like '%TurnstileError%'
   or message like '%[Cloudflare Turnstile]%';

-- ---------------------------------------------------------------------
-- The table is read newest-first and had no index to do it with, which
-- is what 2,822 sequential scans over a growing table looks like.
-- ---------------------------------------------------------------------
create index if not exists idx_client_error_logs_created_at
  on client_error_logs (created_at desc);

-- VACUUM cannot run inside a transaction block and the SQL Editor wraps
-- scripts in one, so the space is returned to the free space map by
-- autovacuum rather than to the operating system here. ANALYZE is
-- enough for the planner to stop believing the table is large.
analyze client_error_logs;

-- ---------------------------------------------------------------------
-- After. The last statement returning rows is what the editor shows, so
-- the proof goes here: what survived, and how much of it.
-- ---------------------------------------------------------------------
select
  count(*) as rows_remaining,
  count(distinct message) as distinct_messages,
  min(created_at) as oldest,
  max(created_at) as newest
from client_error_logs;
