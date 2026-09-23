-- Run in the Supabase SQL Editor. Reads only. Creates nothing.
--
-- THE QUESTION THIS SETTLES
--
-- The browser measured a churches read at 6470 ms. EXPLAIN ANALYZE of
-- that exact query, on this database, says 0.42 ms. Both numbers are
-- real. The six seconds are therefore being spent somewhere between
-- the browser and the executor -- or they are not, and something else
-- is slow that the single-query EXPLAIN did not catch.
--
-- pg_stat_statements answers that. It is what Postgres itself recorded
-- for every statement it has run, so it cannot be argued with.
--
-- HOW TO READ THE RESULT
--
-- If the slowest thing here has a mean of a few milliseconds, then
-- nothing in this schema is slow and the six seconds are connection
-- acquisition, the pooler, the API gateway or the network. That is a
-- compute-size and region question, not a code one. The project is on
-- NANO, which is the smallest instance offered.
--
-- If something here has a mean in the hundreds or thousands of
-- milliseconds, that is a real query to fix and I will fix it.
--
-- `calls` matters as much as `mean`. A 3 ms query called 900 times in
-- a page load costs more than a 200 ms query called once, and the
-- browser timeline showed this app making 40 to 80 requests per load.

select
  round(total_exec_time::numeric, 1)            as total_ms,
  calls,
  round(mean_exec_time::numeric, 2)             as mean_ms,
  round(max_exec_time::numeric, 1)              as max_ms,
  rows,
  -- Collapsed to something readable: PostgREST sends long parameterised
  -- statements and the interesting part is which table it touched.
  left(regexp_replace(query, '\s+', ' ', 'g'), 130) as statement
from pg_stat_statements
where dbid = (select oid from pg_database where datname = current_database())
  -- Postgres's own bookkeeping is not what we are looking for.
  and query not ilike '%pg_stat_statements%'
  and query not ilike '%pg_catalog%'
order by total_exec_time desc
limit 25;
