-- Run in Supabase SQL Editor. Requires 098_admin_coverage_map.sql.
--
-- Lets the coverage map answer "where are the Baptists" and not only
-- "where did batch 7 land".
--
-- ---------------------------------------------------------------------
-- WHY A FILTER PARAMETER AND NOT ANOTHER GROUPING COLUMN
--
-- Adding denomination to the GROUP BY would let the client slice
-- locally with no extra round trip, which is tempting. It also
-- multiplies the row count by the number of denominations present in
-- each cell, and denomination here is free text out of the imports --
-- 163 distinct values in the faithstreet source alone. At precision 3
-- over twenty thousand churches that is a large payload to send so the
-- browser can throw most of it away.
--
-- Filtering server side keeps the response the same size it is today.
-- The cost is one round trip per change of filter, which is a click
-- somebody made deliberately.
--
-- null means no filter, so the existing single-argument call keeps
-- working unchanged.

do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                 where ns.nspname = 'public' and p.proname = 'admin_church_coverage_cells') then
    raise exception 'ABORT: admin_church_coverage_cells is missing. Run 098_admin_coverage_map.sql first.';
  end if;
end $$;

-- DROPped, not replaced: the argument list changes, and CREATE OR
-- REPLACE cannot do that. Replacing in place leaves two live overloads
-- and PostgREST then cannot choose between them.
drop function if exists admin_church_coverage_cells(integer);

create or replace function admin_church_coverage_cells(
  p_precision integer default 1,
  p_denominations text[] default null
)
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
      and (
        p_denominations is null
        -- Blank and null denominations ride along under '' so that
        -- "no denomination" is something the filter can include, not a
        -- group that silently vanishes the moment any filter is on.
        or coalesce(nullif(trim(c.denomination), ''), '') = any (p_denominations)
      )
    group by 1, 2, 3;
end;
$$;

grant execute on function admin_church_coverage_cells(integer, text[]) to authenticated;

-- The list behind the denomination dropdown. Counts included so the
-- long tail sorts itself out -- free text from the imports means the
-- top twenty matter and the rest are ones and twos.
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
  n_cells   integer;
  n_denoms  integer;
  n_args    integer;
begin
  select count(*) filter (where p.pronargs = 2), count(*)
    into n_args, n_cells
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'admin_church_coverage_cells';

  if n_args <> 1 then
    raise exception 'VERIFY FAILED: no two-argument admin_church_coverage_cells.';
  end if;
  if n_cells <> 1 then
    raise exception 'VERIFY FAILED: expected 1 admin_church_coverage_cells signature, found %.', n_cells;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                 where ns.nspname = 'public' and p.proname = 'admin_coverage_denominations') then
    raise exception 'VERIFY FAILED: admin_coverage_denominations was not created.';
  end if;

  -- Run the grouping directly rather than calling the function, which
  -- would raise: auth.uid() is null in the SQL Editor, so
  -- is_platform_admin() is always false here.
  select count(*) into n_denoms from (
    select coalesce(nullif(trim(c.denomination), ''), '')
      from churches c where c.lat is not null and c.lng is not null
     group by 1
  ) d;

  raise notice 'OK. % distinct denominations across the geocoded churches.', n_denoms;
end $$;
