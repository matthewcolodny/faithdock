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
-- Verify. Read the output rather than assuming it worked.
-- ---------------------------------------------------------------------
-- Expect: anon_can_execute false for BOTH, and both definers.
--
-- The grant is the part worth checking, not the result. These read
-- every church in the table, including hidden ones, and they are
-- SECURITY DEFINER -- so if anon can execute them, RLS is bypassed for
-- the whole table. Migration 094 predicted a grant and was wrong about
-- it; assert it, do not print it and move on.
select
  p.proname                                            as fn,
  p.prosecdef                                          as is_security_definer,
  has_function_privilege('anon', p.oid, 'EXECUTE')     as anon_can_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('admin_church_coverage_cells', 'admin_coverage_unmapped_count')
order by p.proname;

-- And the shape of the data, at state level. Expect one row per
-- (cell, batch) -- with the San Antonio import only, a handful of rows
-- around lat 29, lng -98.
select cell_lat, cell_lng, n, claimed, hidden,
       coalesce(import_batch_id, '(added individually)') as batch
from admin_church_coverage_cells(0)
order by n desc
limit 10;
