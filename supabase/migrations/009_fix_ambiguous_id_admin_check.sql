-- Run in Supabase SQL Editor.
--
-- Fixes a real bug in the last round of fixes: both of these
-- functions' RETURNS TABLE includes a column named `id`, which
-- PL/pgSQL exposes as an implicit variable throughout the function
-- body. The permission check's bare `where id = auth.uid()` was
-- therefore ambiguous -- Postgres couldn't tell if `id` meant
-- `profiles.id` or the function's own output column -- and refused
-- to run at all. This failed CLOSED (nobody could get data out,
-- including a real admin) rather than open, but it's still broken
-- for legitimate use. Fixed by qualifying the column explicitly as
-- `profiles.id`. Also switched both to the same is_platform_admin()
-- helper the other 7 fixes already use, so this whole family is
-- consistent and doesn't rely on remembering to qualify every column.
--
-- CURRENT / live definitions of get_pending_church_claims() and
-- get_churches_without_coordinates() -- this supersedes both
-- 006_church_claim_admin_checks.sql and
-- 007b_get_churches_without_coordinates.sql. Chronologically this ran
-- AFTER 008_remaining_admin_rpc_security_fixes.sql (numbered lower
-- only because that batch happened to touch different functions).

create or replace function get_pending_church_claims(
  p_keyword text default null,
  p_limit integer default 30,
  p_offset integer default 0
)
returns table (
  id uuid, church_id uuid, church_name text, church_address text,
  requester_name text, requester_role text, requester_email text,
  requester_phone text, note text, created_at timestamptz, total_count bigint
)
language plpgsql
security definer
as $$
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to view claim requests.';
  end if;

  return query
    select r.id, r.church_id, c.name, c.address, r.requester_name, r.requester_role, r.requester_email,
      r.requester_phone, r.note, r.created_at,
      count(*) over() as total_count
    from church_claim_requests r
    join churches c on c.id = r.church_id
    where r.status = 'pending'
      and (
        p_keyword is null or p_keyword = ''
        or c.name ilike '%' || p_keyword || '%'
        or r.requester_name ilike '%' || p_keyword || '%'
        or r.requester_email ilike '%' || p_keyword || '%'
      )
    order by r.created_at
    limit p_limit offset p_offset;
end;
$$;

create or replace function get_churches_without_coordinates(
  p_limit integer default 30,
  p_offset integer default 0
)
returns table (id uuid, name text, address text, total_count bigint)
language plpgsql
security definer
as $$
begin
  if not is_platform_admin() then
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
