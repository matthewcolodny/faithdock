-- Run in the Supabase SQL Editor.
--
-- THIS ONE DELETES ROWS. Read the next paragraph before running it.
--
-- It removes rows from client_error_logs whose message is exactly
-- "Script error." or contains "TurnstileError" / "[Cloudflare
-- Turnstile]". Nothing else is touched, no other table is touched, and
-- it prints before and after counts so you can see exactly what went.
-- These are diagnostic logs this app wrote about itself.
--
-- (An earlier version of this file indexed `created_at`, which does not
-- exist on this table -- the column is `occurred_at`, and migration 041
-- already indexed it. The whole script is one transaction, so that
-- failure deleted nothing. The index it actually needs is below, and it
-- is a different one.)
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
-- WHY THE ROWS COST MORE THAN THEIR SIZE
--
-- Migration 041 put a BEFORE INSERT trigger on this table that rate
-- limits writing to it -- and to do that it runs a count over the table
-- on every single insert:
--
--   select count(*) from client_error_logs
--   where user_id = new.user_id and occurred_at > now() - interval
--
-- So each junk row was not just stored, it made every later insert
-- read more. That is what 2,822 sequential scans and fifteen million
-- rows walked actually are: a rate limiter scanning a table that the
-- thing it failed to limit kept growing.
--
-- And this database has 500 MB of shared RAM. Every page of this table
-- that gets scanned is a page of buffer cache not holding something
-- useful -- while the two functions that measured slow come in at 75 ms
-- and 54 ms warm against recorded means of 1570 ms and 1536 ms. That
-- twenty-fold gap is cache misses.
--
-- The client stopped writing these in build 2026-09-23-v229, and its
-- dedup now survives a page reload, which is the part that mattered:
-- the old 60-second window was reset by every refresh, and both of
-- these errors happen once per load, forever. 8,373 rows is 8,373 page
-- loads. Without that change this table would simply refill.

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
-- The index the rate-limit trigger actually needs.
--
-- Migration 041 indexed (occurred_at desc), which serves reading the
-- log newest-first. It does not serve the trigger's own query, which
-- filters on user_id AND a time window -- so that count either walks
-- the time range filtering user_id row by row, or gives up and scans.
--
-- Leading with user_id and keeping occurred_at second answers both
-- branches of the trigger exactly: the `user_id = x` case by equality
-- then range, and the `user_id is null` case the same way, since NULL
-- is an ordinary indexable value in a btree.
-- ---------------------------------------------------------------------
create index if not exists idx_client_error_logs_user_occurred
  on client_error_logs (user_id, occurred_at desc);

-- VACUUM cannot run inside a transaction block and the SQL Editor wraps
-- scripts in one, so space returns to the free space map via autovacuum
-- rather than to the operating system here. ANALYZE is what stops the
-- planner believing the table is still large.
analyze client_error_logs;

-- ---------------------------------------------------------------------
-- After. The last statement returning rows is what the editor shows, so
-- the proof goes here: what survived, and how much of it.
-- ---------------------------------------------------------------------
select
  count(*)                as rows_remaining,
  count(distinct message) as distinct_messages,
  min(occurred_at)        as oldest,
  max(occurred_at)        as newest
from client_error_logs;
