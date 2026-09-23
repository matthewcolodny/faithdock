-- Run in the Supabase SQL Editor. Reads only. Creates nothing that
-- outlives the session.
--
-- WHAT pg_stat_statements ALREADY TOLD US
--
-- I said nothing in this schema was slow. That was wrong, and the
-- numbers say so plainly:
--
--   total_ms   calls   mean_ms   max_ms   statement
--   120855.4      77   1569.55   7580.2   ...target_church_i...
--   110617.3      72   1536.35   6784.6   ...target_church_i...
--    64141.3     140    458.15   3765.0   ...target_church_i...
--    33971.3      84    404.42   3436.3   ...target_church_i...
--
-- A mean of one and a half seconds, and a worst case of seven and a
-- half. Those are ours. The 6470 ms request the browser measured is
-- very likely one of these rather than the platform -- I measured the
-- wrong query earlier (a churches lookup, which really is 0.4 ms) and
-- generalised from it.
--
-- The statement text was truncated at 130 characters by my own probe,
-- so we cannot yet tell WHICH function. This gets the full text, and
-- the two other things worth knowing.

create or replace function pg_temp.which_rpc_is_slow()
returns table(section text, ord int, detail text)
language plpgsql
as $fn$
declare
  r record;
  i int := 0;
begin
  -- -------------------------------------------------------------------
  -- 1. The full text of the slow ones, so we know what to fix.
  -- -------------------------------------------------------------------
  for r in
    select round(s.mean_exec_time::numeric, 0) as mean_ms,
           s.calls,
           round(s.max_exec_time::numeric, 0) as max_ms,
           regexp_replace(s.query, '\s+', ' ', 'g') as q
    from pg_stat_statements s
    where s.query ilike '%target_church_i%'
      and s.query not ilike '%pg_stat_statements%'
    order by s.total_exec_time desc
    limit 6
  loop
    i := i + 1;
    section := '1. slow RPCs (full text)';
    ord := i;
    detail := 'mean ' || r.mean_ms || 'ms, max ' || r.max_ms || 'ms, ' || r.calls
              || ' calls  ::  ' || left(r.q, 600);
    return next;
  end loop;

  -- -------------------------------------------------------------------
  -- 2. Which tables are being read sequentially, and how much.
  --
  -- seq_tup_read is the number of rows Postgres has walked through
  -- without an index. A big number next to a small n_live_tup means the
  -- same table is being scanned over and over -- which is exactly what
  -- a join inside a function called on every dashboard load looks like
  -- when the joined column is not indexed.
  -- -------------------------------------------------------------------
  i := 0;
  for r in
    select t.relname,
           t.seq_scan, t.seq_tup_read, coalesce(t.idx_scan, 0) as idx_scan,
           t.n_live_tup
    from pg_stat_user_tables t
    where t.seq_tup_read > 0
    order by t.seq_tup_read desc
    limit 15
  loop
    i := i + 1;
    section := '2. sequential scans';
    ord := i;
    detail := rpad(r.relname, 28) || ' rows_live=' || r.n_live_tup
              || '  seq_scans=' || r.seq_scan
              || '  rows_walked=' || r.seq_tup_read
              || '  index_scans=' || r.idx_scan;
    return next;
  end loop;

  -- -------------------------------------------------------------------
  -- 3. What is firing 12,269 HTTP posts.
  --
  -- net.http_post showed 12,269 calls and cron.job_run_details 12,297
  -- inserts. That is a scheduled job running roughly once a minute for
  -- about eight and a half days. Worth seeing what it is and how often
  -- it needs to be -- constant background work is felt more on a shared
  -- CPU than on a dedicated one.
  -- -------------------------------------------------------------------
  begin
    i := 0;
    for r in execute
      'select jobid, schedule, active, left(command, 120) as command from cron.job order by jobid'
    loop
      i := i + 1;
      section := '3. cron jobs';
      ord := i;
      detail := 'job ' || r.jobid || '  [' || r.schedule || ']  active=' || r.active
                || '  ' || r.command;
      return next;
    end loop;
    if i = 0 then
      section := '3. cron jobs'; ord := 1; detail := 'No cron jobs found.'; return next;
    end if;
  exception when others then
    section := '3. cron jobs'; ord := 1;
    detail := 'Could not read cron.job: ' || sqlerrm;
    return next;
  end;
end
$fn$;

select * from pg_temp.which_rpc_is_slow();
