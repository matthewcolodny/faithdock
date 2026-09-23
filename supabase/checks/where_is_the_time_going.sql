-- Run in the Supabase SQL Editor. Reads only. Creates nothing that
-- outlives the session.
--
-- WHERE THIS STANDS
--
-- The client is exonerated, measured in your own browser:
--
--   supabase client, 6 queries:  140, 132, 128, 133, 139, 137 ms
--      wall clock:               140 ms
--   web locks:                   held=[]  pending=[]
--
-- Six queries in parallel, all fast, no lock. Nothing is serialising
-- anything. My earlier staircase was my own test sending six identical
-- urls, which browsers deliberately serialise.
--
-- The real thing is in the console:
--
--   POST /rest/v1/rpc/search_events  500
--   {code: '57014', message: 'canceling statement due to statement timeout'}
--
-- search_events ran until Postgres killed it. And in the same load,
-- search_churches took 6436 ms and 5865 ms.
--
-- Both run on the PUBLIC home page, and both are heavy enough to
-- saturate a shared-CPU instance. That is why a churches read measures
-- 90 ms on its own and 6700 ms during a page load: it is queued behind
-- these. It also explains why everything looked slow at once --
-- including auth/v1/user, which shares the machine but not the schema.
--
-- The statistics were reset at 17:47, so what follows is a clean sample
-- of recent activity rather than a lifetime average.

create or replace function pg_temp.where_is_the_time_going()
returns table(section text, ord int, detail text)
language plpgsql
as $fn$
declare
  r record;
  i int := 0;
begin
  -- -------------------------------------------------------------------
  -- 1. What has actually cost time since the reset.
  --
  -- Read `calls` beside `mean`: this page makes forty-odd requests per
  -- load, so a 200 ms statement called forty times outranks a 2-second
  -- one called twice.
  -- -------------------------------------------------------------------
  for r in
    select round(s.total_exec_time::numeric, 0) as total_ms,
           s.calls,
           round(s.mean_exec_time::numeric, 1) as mean_ms,
           round(s.max_exec_time::numeric, 0) as max_ms,
           left(regexp_replace(s.query, '\s+', ' ', 'g'), 110) as q
    from pg_stat_statements s
    where s.dbid = (select oid from pg_database where datname = current_database())
      and s.query not ilike '%pg_stat_statements%'
      and s.query not ilike '%pg_catalog%'
    order by s.total_exec_time desc
    limit 15
  loop
    i := i + 1;
    section := '1. costliest since reset';
    ord := i;
    detail := 'total ' || r.total_ms || 'ms  x' || r.calls
              || '  mean ' || r.mean_ms || 'ms  max ' || r.max_ms || 'ms  ::  ' || r.q;
    return next;
  end loop;

  -- -------------------------------------------------------------------
  -- 2. The signatures of the two suspects, so the next step can EXPLAIN
  --    them with the right arguments rather than guessing at them.
  -- -------------------------------------------------------------------
  i := 0;
  for r in
    select p.proname,
           pg_get_function_identity_arguments(p.oid) as args,
           p.provolatile,
           p.prosecdef
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('search_events', 'search_churches')
    order by p.proname
  loop
    i := i + 1;
    section := '2. suspect signatures';
    ord := i;
    detail := r.proname || '(' || r.args || ')'
              || '   volatility=' || case r.provolatile
                   when 'i' then 'immutable' when 's' then 'stable' else 'VOLATILE' end
              || '  security_definer=' || r.prosecdef;
    return next;
  end loop;

  -- -------------------------------------------------------------------
  -- 3. How long a statement is allowed to run before being killed --
  --    which is the 57014 the browser saw.
  -- -------------------------------------------------------------------
  i := 0;
  for r in
    select rolname, coalesce(array_to_string(rolconfig, ', '), '(inherits default)') as cfg
    from pg_roles
    where rolname in ('anon', 'authenticated', 'service_role', 'authenticator')
    order by rolname
  loop
    i := i + 1;
    section := '3. statement timeouts';
    ord := i;
    detail := rpad(r.rolname, 16) || r.cfg;
    return next;
  end loop;
end
$fn$;

select * from pg_temp.where_is_the_time_going();
