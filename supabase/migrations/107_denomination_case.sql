-- Run in Supabase SQL Editor. Requires 105_coverage_centroids.sql.
--
-- The denomination dropdown listed the same thing several times --
-- two Jewish, several Non-denominational, several Other -- because it
-- grouped on the raw column. denomination is free text from several
-- imports, and they disagree about capitalisation: "Non-denominational"
-- and "Non-Denominational" are two rows to GROUP BY and one thing to a
-- reader. Internal double spaces do the same.
--
-- Both the list and the filter now normalise the same way, so a tick in
-- the dropdown matches every spelling of what it names.
--
-- ---------------------------------------------------------------------
-- WHAT THIS DOES NOT DO
--
-- It does not merge synonyms. "Roman Catholic" and "Catholic" are
-- different strings meaning the same thing, and the older San Antonio
-- import used the first while everything since uses the second -- which
-- is why the map appears to show Roman Catholics only in San Antonio.
-- That is a real finding about the data, not about capitalisation, and
-- merging it is an edit to the churches table rather than a change of
-- grouping. Left alone deliberately: guessing which names mean the same
-- thing is exactly the kind of decision that should be made by someone
-- looking at the list, not by a migration.

do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                 where ns.nspname = 'public' and p.proname = 'admin_coverage_denominations') then
    raise exception 'ABORT: admin_coverage_denominations is missing. Run 105_coverage_centroids.sql first.';
  end if;
end $$;

-- One definition, used by the list and the filter, so they cannot drift
-- apart -- which is the whole failure being fixed.
create or replace function fd_norm_denom(v text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select lower(regexp_replace(coalesce(btrim(v), ''), '\s+', ' ', 'g'));
$$;

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
    select
      -- The spelling most churches actually use, so the dropdown reads
      -- like the data rather than like a lowercased key.
      coalesce(mode() within group (order by nullif(btrim(c.denomination), '')), '')::text,
      count(*)::bigint
      from churches c
     where c.lat is not null and c.lng is not null
     group by fd_norm_denom(c.denomination)
     order by 2 desc, 1;
end;
$$;

grant execute on function admin_coverage_denominations() to authenticated;

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
set search_path = public, pg_temp
as $$
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to view the coverage map.';
  end if;

  p_precision := greatest(0, least(3, coalesce(p_precision, 1)));

  return query
    select
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
        -- Normalised on both sides. The client sends back the display
        -- spelling it was given, which is one of several in the table;
        -- comparing raw would match only the churches that happen to
        -- share that capitalisation.
        or fd_norm_denom(c.denomination) in (
             select fd_norm_denom(u) from unnest(p_denominations) as u
           )
      )
    group by 1, 2, 5;
end;
$$;

grant execute on function admin_church_coverage_cells(integer, text[]) to authenticated;

-- ---------------------------------------------------------------------
do $$
declare
  n_raw    integer;
  n_norm   integer;
  worst    text;
begin
  if (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname = 'admin_church_coverage_cells') <> 1 then
    raise exception 'VERIFY FAILED: admin_church_coverage_cells does not have exactly one signature.';
  end if;

  -- Run the grouping directly rather than calling the functions, which
  -- would raise: auth.uid() is null in the SQL Editor.
  select count(*) into n_raw from (
    select coalesce(nullif(btrim(c.denomination), ''), '')
      from churches c where c.lat is not null and c.lng is not null group by 1) a;
  select count(*) into n_norm from (
    select fd_norm_denom(c.denomination)
      from churches c where c.lat is not null and c.lng is not null group by 1) b;

  select string_agg(d, ' / ') into worst from (
    select distinct btrim(c.denomination) as d
      from churches c
     where c.lat is not null and c.lng is not null
       and fd_norm_denom(c.denomination) in (
         select fd_norm_denom(c2.denomination)
           from churches c2
          where c2.lat is not null and c2.lng is not null
          group by fd_norm_denom(c2.denomination)
         having count(distinct btrim(c2.denomination)) > 1
         limit 1)
     limit 5) w;

  raise notice 'OK. % entries before, % after -- % duplicates were spelling only. Example: %',
    n_raw, n_norm, n_raw - n_norm, coalesce(worst, 'none');
end $$;
