-- Run in the Supabase SQL Editor.
--
-- One RPC behind the admin coverage map: where the churches we hold
-- actually are, grouped so the answer stays small however many there
-- are. Requested before loading the statewide Texas CSV, to see which
-- metros are already covered and where a new batch would land.
--
-- WHY AGGREGATE RATHER THAN RETURN THE ROWS. Today there are 800
-- churches and all of them would fit in one response and on one map.
-- The whole reason this is being built is that that is about to stop
-- being true -- a statewide file is tens of thousands of rows, which
-- is both a response nobody wants to download and more markers than a
-- browser will draw. Grouping server-side means the response size is
-- set by how much of the map you are looking at, not by how many
-- churches exist.
--
-- p_precision is decimal places of latitude/longitude, and the client
-- ties it to zoom:
--     0  ~111 km   whole state at a glance
--     1  ~11 km    metro areas separate
--     2  ~1.1 km   neighbourhoods separate
--     3  ~110 m    individual churches, effectively
-- Clamped 0..3 here rather than trusted. 4+ would defeat the grouping
-- and hand back a row per church, which is the thing being avoided.
--
-- WHAT IT DELIBERATELY DOES NOT DO. It does not filter by viewport.
-- That was the first design, and it is the wrong one at this size: it
-- makes every pan a round trip, and at precision 0-1 the entire state
-- is a few hundred rows anyway. Revisit it if a nationwide import ever
-- makes precision 2 across a whole viewport too large.
--
-- Churches with no coordinates are not in here at all -- they cannot
-- be placed. admin_coverage_unmapped_count below reports how many, so
-- the map can say what it is not showing rather than quietly omitting
-- it. get_churches_without_coordinates already lists them one by one.

-- ---------------------------------------------------------------------
-- Preflight -- fail loudly rather than create something subtly wrong
-- ---------------------------------------------------------------------
do $preflight$
begin
  if not exists (select 1 from pg_proc where proname = 'is_platform_admin') then
    raise exception 'ABORT: is_platform_admin() does not exist. Every admin RPC in this database gates on it; without it this function would be readable by any signed-in user.';
  end if;
  -- Named explicitly because guessing a column here is how migration
  -- 089 got five rules wrong.
  if not exists (select 1 from information_schema.columns
                 where table_name = 'churches' and column_name = 'import_batch_id') then
    raise exception 'ABORT: churches.import_batch_id is missing. Run 020_import_batch_tracking.sql first.';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_name = 'churches' and column_name = 'is_hidden') then
    raise exception 'ABORT: churches.is_hidden is missing. Run 018_church_is_hidden.sql first.';
  end if;
end
$preflight$;

-- ---------------------------------------------------------------------
-- The cells
-- ---------------------------------------------------------------------
create or replace function admin_church_coverage_cells(p_precision integer default 1)
returns table(
  cell_lat double precision,
  cell_lng double precision,
  import_batch_id text,
  n bigint,
  claimed bigint,
  hidden bigint
)
language plpgsql
security definer
-- Explicit, because SECURITY DEFINER runs this as the owner: an empty
-- or attacker-influenced search_path is how a definer function gets
-- tricked into calling someone else's round() or churches.
set search_path = public, pg_temp
as $$
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to view the coverage map.';
  end if;

  p_precision := greatest(0, least(3, coalesce(p_precision, 1)));

  return query
    select
      -- via numeric, because round(double precision, int) does not
      -- exist in Postgres -- only round(numeric, int) takes a scale.
      round(c.lat::numeric, p_precision)::double precision,
      round(c.lng::numeric, p_precision)::double precision,
      c.import_batch_id,
      count(*)::bigint,
      count(*) filter (where c.owner_id is not null)::bigint,
      count(*) filter (where c.is_hidden)::bigint
    from churches c
    where c.lat is not null
      and c.lng is not null
    group by 1, 2, 3;
end;
$$;

revoke all on function admin_church_coverage_cells(integer) from public, anon;
grant execute on function admin_church_coverage_cells(integer) to authenticated;

-- ---------------------------------------------------------------------
-- What the map cannot show
-- ---------------------------------------------------------------------
-- A coverage map that silently drops the churches it could not place
-- overstates coverage, which is exactly the decision this map is for.
create or replace function admin_coverage_unmapped_count()
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count bigint;
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to view the coverage map.';
  end if;
  select count(*) into v_count from churches where lat is null or lng is null;
  return v_count;
end;
$$;

revoke all on function admin_coverage_unmapped_count() from public, anon;
grant execute on function admin_coverage_unmapped_count() to authenticated;

-- ---------------------------------------------------------------------
-- Verify
-- ---------------------------------------------------------------------
-- NOTHING BELOW CALLS THE FUNCTIONS, AND IT CANNOT.
--
-- The first version of this block ended with
--   select * from admin_church_coverage_cells(0);
-- which failed with "You do not have permission to view the coverage
-- map." That was not the gate misbehaving -- it was the gate working,
-- and the verify query being impossible.
--
--   is_platform_admin()
--     -> select coalesce((select is_platform_admin
--                           from profiles where id = auth.uid()), false)
--
-- The SQL Editor carries no JWT, so auth.uid() is NULL, no profile row
-- matches, and it returns false for everybody, every time, no matter
-- whose account is logged into the dashboard. Every admin RPC in this
-- database is unreachable from the SQL Editor by design. They are
-- meant to be called from the app, signed in.
--
-- It also cost a re-run: the editor wraps the whole script in one
-- transaction, so an error in the last statement rolled back the
-- functions created above it.
--
-- The lesson is the same one migration 094 taught and 092 taught before
-- it -- a verify step has to be capable of failing for the right
-- reason. This one now checks the two things that are actually true
-- from here: the grants, and the data.

-- ---------------------------------------------------------------------
-- 1. The grants, asserted rather than printed
-- ---------------------------------------------------------------------
-- This is the part that matters. Both functions are SECURITY DEFINER
-- and read every church including hidden ones, so an EXECUTE grant to
-- anon would hand the whole table to anybody with the key that ships in
-- the page. 094 printed a grant it had predicted wrongly and nobody
-- read the column; this raises instead.
do $verify_grants$
declare
  r record;
  problems text[] := '{}';
begin
  for r in
    select p.proname,
           p.prosecdef                                        as secdef,
           has_function_privilege('anon', p.oid, 'EXECUTE')    as anon_exec,
           has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('admin_church_coverage_cells', 'admin_coverage_unmapped_count')
  loop
    if r.anon_exec then
      problems := problems || (r.proname || ': anon CAN execute -- RLS is bypassed for churches');
    end if;
    if not r.auth_exec then
      problems := problems || (r.proname || ': authenticated CANNOT execute -- the app will not be able to call it');
    end if;
    if not r.secdef then
      problems := problems || (r.proname || ': not SECURITY DEFINER -- it will read only what the caller can, which is nothing');
    end if;
  end loop;

  -- Both must exist. An empty loop would otherwise pass silently, which
  -- is the failure mode worth guarding: it looks identical to success.
  if (select count(*) from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('admin_church_coverage_cells', 'admin_coverage_unmapped_count')) <> 2 then
    problems := problems || 'expected both functions to exist, found a different number';
  end if;

  if array_length(problems, 1) > 0 then
    raise exception E'INVARIANT FAILED:\n  %', array_to_string(problems, E'\n  ');
  end if;
  raise notice 'Grants OK: both functions exist, are SECURITY DEFINER, executable by authenticated, not by anon.';
end
$verify_grants$;

-- ---------------------------------------------------------------------
-- 2. The data the map will draw
-- ---------------------------------------------------------------------
-- The same grouping the function does, run directly against the table
-- so it works from here. If this returns sensible rows, the function
-- will return the same ones to a signed-in admin -- its body is this
-- query.
--
-- Expect, with the San Antonio import only: a small number of rows
-- around lat 29, lng -98, summing to the number of geocoded churches.
select
  round(c.lat::numeric, 0)::double precision as cell_lat,
  round(c.lng::numeric, 0)::double precision as cell_lng,
  coalesce(c.import_batch_id, '(added individually)') as batch,
  count(*)                                       as n,
  count(*) filter (where c.owner_id is not null) as claimed,
  count(*) filter (where c.is_hidden)            as hidden
from churches c
where c.lat is not null and c.lng is not null
group by 1, 2, 3
order by n desc
limit 10;

-- And what the map will say it cannot show.
select
  count(*) filter (where lat is null or lng is null) as unmapped,
  count(*) filter (where lat is not null and lng is not null) as mappable,
  count(*)                                                    as total
from churches;
