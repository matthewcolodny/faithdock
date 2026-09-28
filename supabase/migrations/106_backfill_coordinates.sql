-- Run in Supabase SQL Editor.
--
-- Lets the admin panel fill in coordinates for churches that were
-- imported without them, without deleting or re-importing anything.
--
-- ---------------------------------------------------------------------
-- WHY THIS EXISTS
--
-- 1,259 churches are in the directory with no lat/lng, so they are
-- findable by search and invisible on every map. Two causes, measured:
--
--   155  addresses that genuinely cannot be geocoded -- PO boxes,
--        no street number -- almost all from the pre-faithstreet data.
--   the rest, from the fs-towns-* batches, where the import's own
--        geocoding rule refused a town-centre result. That rule has
--        since been relaxed for towns holding three or fewer churches,
--        which is the population it was losing.
--
-- Re-uploading the same CSV does not fix them: the importer skips a row
-- whose name and address it already holds, so it never reaches the
-- geocoder. Deleting and re-importing would work and would throw away
-- the import history with it. This is the third option -- geocode the
-- rows already there, leave everything else alone.
--
-- The geocoding itself stays in the browser, where the Maps key already
-- is and where the import does it too. These two functions are only the
-- read and the write.

do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_name = 'churches' and column_name = 'lat') then
    raise exception 'ABORT: churches.lat is missing.';
  end if;
end $$;

-- A page of churches that have an address and no coordinates. Ordered
-- so a run is resumable: the same query after a partial pass returns
-- what is left, because the rows that succeeded no longer qualify.
create or replace function admin_churches_missing_coords(p_limit integer default 200)
returns table(
  id uuid,
  name text,
  address text,
  import_batch_id text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to list churches.';
  end if;

  p_limit := greatest(1, least(500, coalesce(p_limit, 200)));

  return query
    select c.id, c.name, c.address, c.import_batch_id
      from churches c
     where c.lat is null
       and c.address is not null
       and btrim(c.address) <> ''
     order by c.import_batch_id nulls last, c.name
     limit p_limit;
end;
$$;

grant execute on function admin_churches_missing_coords(integer) to authenticated;

-- How many are left, so the panel can say so without paging through.
create or replace function admin_churches_missing_coords_count()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  n integer;
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to list churches.';
  end if;
  select count(*) into n
    from churches c
   where c.lat is null and c.address is not null and btrim(c.address) <> '';
  return n;
end;
$$;

grant execute on function admin_churches_missing_coords_count() to authenticated;

-- Writes coordinates and nothing else.
--
-- Deliberately refuses to overwrite: it only fills a row that has none.
-- A backfill is a repair for rows that were missed, not a way to move
-- a pin somebody has already corrected by hand, and a re-run of the
-- whole job must not undo that work.
create or replace function admin_set_church_coords(
  target_church_id uuid,
  p_lat double precision,
  p_lng double precision
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  n integer;
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to change a church''s location.';
  end if;
  if p_lat is null or p_lng is null then
    return false;
  end if;

  update churches
     set lat = p_lat, lng = p_lng
   where id = target_church_id
     and lat is null;

  get diagnostics n = row_count;
  return n > 0;
end;
$$;

grant execute on function admin_set_church_coords(uuid, double precision, double precision) to authenticated;

-- ---------------------------------------------------------------------
do $$
declare
  n_missing   integer;
  n_hopeless  integer;
begin
  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                 where ns.nspname = 'public' and p.proname = 'admin_churches_missing_coords') then
    raise exception 'VERIFY FAILED: admin_churches_missing_coords was not created.';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                 where ns.nspname = 'public' and p.proname = 'admin_set_church_coords') then
    raise exception 'VERIFY FAILED: admin_set_church_coords was not created.';
  end if;

  -- Counted directly rather than through the functions, which would
  -- raise: auth.uid() is null in the SQL Editor, so is_platform_admin()
  -- is always false here.
  select count(*) into n_missing
    from churches where lat is null and address is not null and btrim(address) <> '';
  select count(*) into n_hopeless
    from churches
   where lat is null
     and (address is null or btrim(address) = '' or address ~* '\mP\.?\s?O\.?\s+box\M');

  raise notice 'OK. % churches to try, and a further % that no geocoder will place (PO box or no address).',
    n_missing, n_hopeless;
end $$;
