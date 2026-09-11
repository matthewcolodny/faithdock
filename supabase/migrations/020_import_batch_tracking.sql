-- Run in Supabase SQL Editor.
--
-- Tags every church created by a CSV import (admin_import_churches)
-- with a batch identifier, and adds admin tooling to review recent
-- import batches and bulk hide/delete a batch's still-unclaimed rows.
-- Requested ahead of the San Antonio metro import so it can be
-- reviewed/rolled back as a batch rather than church-by-church.

alter table churches add column if not exists import_batch_id text;
alter table churches add column if not exists import_source_filename text;

create index if not exists idx_churches_import_batch_id
  on churches(import_batch_id) where import_batch_id is not null;

-- admin_import_churches gets 2 new params (p_batch_id, p_source_filename)
-- -- a different signature from the existing admin_import_churches(jsonb),
-- so CREATE OR REPLACE alone would just add a second overload rather than
-- replace it (same lesson as search_churches in migration 017). Drop the
-- old one-arg version first.
drop function if exists admin_import_churches(jsonb);

create or replace function admin_import_churches(
  rows jsonb,
  p_batch_id text default null,
  p_source_filename text default null
)
returns setof uuid
language plpgsql
security definer
as $$
declare
  row_data jsonb;
  new_id uuid;
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to import churches.';
  end if;

  for row_data in select * from jsonb_array_elements(rows)
  loop
    insert into churches (name, denomination, address, phone, website, logo_url, lat, lng, owner_id, import_batch_id, import_source_filename)
    values (
      row_data->>'name', row_data->>'denomination', row_data->>'address', row_data->>'phone',
      row_data->>'website', row_data->>'logo_url',
      nullif(row_data->>'lat', '')::double precision, nullif(row_data->>'lng', '')::double precision,
      null, p_batch_id, p_source_filename
    )
    on conflict (dedupe_key) do nothing
    returning id into new_id;

    if new_id is not null then
      return next new_id;
    end if;
    new_id := null;
  end loop;
  return;
end;
$$;

grant execute on function admin_import_churches(jsonb, text, text) to authenticated;

-- Recent import batches, most recent first. row_count / unclaimed_count
-- both count the batch's current rows (a church can be deleted or
-- claimed after import, so these can drop below what was first
-- inserted -- that's intentional, it reflects what Hide all / Delete
-- all would actually act on right now).
create or replace function admin_list_import_batches(p_limit integer default 100)
returns table(
  import_batch_id text,
  source_filename text,
  batch_date timestamptz,
  row_count bigint,
  unclaimed_count bigint
)
language plpgsql
security definer
as $$
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to view import batches.';
  end if;

  return query
    select c.import_batch_id, max(c.import_source_filename), min(c.created_at) as batch_date,
      count(*) as row_count,
      count(*) filter (where c.owner_id is null) as unclaimed_count
    from churches c
    where c.import_batch_id is not null
    group by c.import_batch_id
    order by batch_date desc
    limit p_limit;
end;
$$;

grant execute on function admin_list_import_batches(integer) to authenticated;

-- Hide all still-unclaimed churches from one import batch. Deliberately
-- scoped to owner_id is null, same as admin_delete_import_batch below --
-- a church someone has since genuinely claimed shouldn't vanish from the
-- directory under them just because it started life as an import row.
create or replace function admin_hide_import_batch(p_batch_id text)
returns integer
language plpgsql
security definer
as $$
declare
  affected integer;
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to change a church''s visibility.';
  end if;

  update churches set is_hidden = true
  where import_batch_id = p_batch_id and owner_id is null;
  get diagnostics affected = row_count;
  return affected;
end;
$$;

grant execute on function admin_hide_import_batch(text) to authenticated;

-- Permanently deletes a batch's still-unclaimed churches (same
-- owner_id-is-null guard as admin_delete_unclaimed_church). Returns how
-- many were actually deleted plus how many were left alone because
-- they'd since been claimed, so the admin UI can report both rather
-- than silently deleting less than the batch's total row count.
create or replace function admin_delete_import_batch(p_batch_id text)
returns table(deleted_count integer, skipped_claimed_count integer)
language plpgsql
security definer
as $$
declare
  n_deleted integer;
  n_skipped integer;
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to delete churches.';
  end if;

  select count(*) into n_skipped from churches
  where import_batch_id = p_batch_id and owner_id is not null;

  delete from churches where import_batch_id = p_batch_id and owner_id is null;
  get diagnostics n_deleted = row_count;

  return query select n_deleted, n_skipped;
end;
$$;

grant execute on function admin_delete_import_batch(text) to authenticated;

notify pgrst, 'reload schema';
