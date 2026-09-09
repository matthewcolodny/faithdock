-- Run in Supabase SQL Editor.
--
-- Same bug as the two church-claim functions: a literal
-- "-- ADMIN CHECK HERE" placeholder with nothing after it, so this
-- currently has no permission check at all. Lower severity than the
-- claim functions (it only lists church id/name/address, doesn't
-- transfer anything or expose personal contact info), but still an
-- unauthenticated information leak and an easy, same-pattern fix.
-- Return type is unchanged, so create or replace works here directly.
--
-- SUPERSEDED: see 009_fix_ambiguous_id_admin_check.sql for the
-- corrected, currently-live version (this one's `where id =
-- auth.uid()` is ambiguous against the RETURNS TABLE's own `id`
-- column and fails closed) -- kept here for the historical record.

create or replace function get_churches_without_coordinates(
  p_limit integer default 30,
  p_offset integer default 0
)
returns table (id uuid, name text, address text, total_count bigint)
language plpgsql
security definer
as $$
begin
  if not exists (
    select 1 from profiles where id = auth.uid() and is_platform_admin = true
  ) then
    raise exception 'You do not have permission to view this.';
  end if;

  return query
    select c.id, c.name, c.address, count(*) over() as total_count
    from churches c
    where c.lat is null or c.lng is null
    order by c.name
    limit p_limit offset p_offset;
end;
$$;
