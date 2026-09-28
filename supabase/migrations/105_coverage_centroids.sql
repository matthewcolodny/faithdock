-- Run in Supabase SQL Editor. Supersedes 104_coverage_denominations.sql
-- and is safe to run whether or not 104 was run.
--
-- Puts each circle where its churches actually are.
--
-- ---------------------------------------------------------------------
-- WHY THE MAP LOOKED LIKE GRAPH PAPER
--
-- Cells are made by rounding lat/lng to a fixed number of decimals, so
-- every cell centre is a point on a lattice -- whole degrees at the
-- widest zoom. Drawing each circle at its cell's rounded coordinate put
-- the whole state on a grid of evenly spaced dots, which says nothing
-- about where anything is: a cell holding one church in its far corner
-- and a cell holding forty spread across it drew in exactly the same
-- place.
--
-- Rounding is still how the cells are made -- it is cheap, it is stable
-- as you zoom, and it is what keeps the response small. Only the
-- position drawn changes: avg(lat), avg(lng) over the churches in the
-- cell, so a circle sits over its own churches and the map stops
-- looking like a lattice.
--
-- The cell key is still returned, because the client groups by it.

do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_name = 'churches' and column_name = 'lat') then
    raise exception 'ABORT: churches.lat is missing.';
  end if;
end $$;

-- Both possible shapes, because 104 may or may not have been run. The
-- return type changes either way, and CREATE OR REPLACE cannot change
-- a return type.
drop function if exists admin_church_coverage_cells(integer);
drop function if exists admin_church_coverage_cells(integer, text[]);

create or replace function admin_church_coverage_cells(
  p_precision integer default 1,
  p_denominations text[] default null
)
returns table(
  cell_lat double precision,
  cell_lng double precision,
  avg_lat double precision,
  avg_lng double precision,
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
      avg(c.lat)::double precision,
      avg(c.lng)::double precision,
      c.import_batch_id,
      count(*)::bigint,
      count(*) filter (where c.owner_id is not null)::bigint,
      count(*) filter (where c.is_hidden)::bigint
    from churches c
    where c.lat is not null
      and c.lng is not null
      and (
        p_denominations is null
        -- Blank and null denominations ride along under '' so that
        -- "no denomination" is something the filter can include, not a
        -- group that silently vanishes the moment any filter is on.
        or coalesce(nullif(trim(c.denomination), ''), '') = any (p_denominations)
      )
    group by 1, 2, 5;
end;
$$;

grant execute on function admin_church_coverage_cells(integer, text[]) to authenticated;

-- Repeated from 104 so this file stands alone: running 105 on a
-- database that never got 104 still ends up with a working filter.
create or replace function admin_coverage_denominations()
returns table(denomination text, n bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to view the coverage map.';
  end if;

  return query
    select coalesce(nullif(trim(c.denomination), ''), '')::text, count(*)::bigint
      from churches c
     where c.lat is not null and c.lng is not null
     group by 1
     order by 2 desc, 1;
end;
$$;

grant execute on function admin_coverage_denominations() to authenticated;

-- ---------------------------------------------------------------------
do $$
declare
  n_sigs   integer;
  n_args2  integer;
  has_avg  integer;
  spread   numeric;
begin
  select count(*), count(*) filter (where p.pronargs = 2)
    into n_sigs, n_args2
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'admin_church_coverage_cells';
  if n_args2 <> 1 or n_sigs <> 1 then
    raise exception 'VERIFY FAILED: expected one two-argument admin_church_coverage_cells, found % total.', n_sigs;
  end if;

  select count(*) into has_avg
    from information_schema.routines r
    join information_schema.parameters pa on pa.specific_name = r.specific_name
   where r.routine_name = 'admin_church_coverage_cells'
     and pa.parameter_mode = 'OUT' and pa.parameter_name = 'avg_lat';
  if has_avg <> 1 then
    raise exception 'VERIFY FAILED: admin_church_coverage_cells has no avg_lat column.';
  end if;

  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                 where ns.nspname = 'public' and p.proname = 'admin_coverage_denominations') then
    raise exception 'VERIFY FAILED: admin_coverage_denominations was not created.';
  end if;

  -- Run the grouping directly rather than calling the function, which
  -- would raise: auth.uid() is null in the SQL Editor, so
  -- is_platform_admin() is always false here. This is the number the
  -- change is for -- how far a cell's churches sit from its grid point.
  select round(avg(d), 4) into spread from (
    select abs(avg(c.lat) - round(c.lat::numeric, 1)::double precision) as d
      from churches c
     where c.lat is not null and c.lng is not null
     group by round(c.lat::numeric, 1), round(c.lng::numeric, 1)
  ) x;

  raise notice 'OK. Churches sit on average %° from their cell''s grid point -- that offset is what the circles now use.', coalesce(spread, 0);
end $$;
