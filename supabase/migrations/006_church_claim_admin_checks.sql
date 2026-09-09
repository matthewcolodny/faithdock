-- Run in Supabase SQL Editor.
--
-- Fixes a real, confirmed gap: the deployed version of this function
-- has a literal "-- ADMIN CHECK HERE" placeholder comment where the
-- authorization check should be -- meaning it currently has NO check
-- at all. Verified live: calling it with no login returns a real
-- result instead of a permissions error. This replaces it with an
-- actual check (must be signed in AND profiles.is_platform_admin),
-- and adds requester_phone to the return set.
--
-- SUPERSEDED: this function's `where id = auth.uid()` check turned
-- out to be ambiguous (RETURNS TABLE includes a column also named
-- `id`) and failed closed. See 009_fix_ambiguous_id_admin_check.sql
-- for the corrected, currently-live version of this function --
-- kept here only for the historical record of what shipped first.

-- Adding requester_phone changes the function's return row shape,
-- which Postgres won't let `create or replace` do in place -- has to
-- be dropped and recreated instead.
drop function if exists get_pending_church_claims(text, integer, integer);

create function get_pending_church_claims(
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
  if not exists (
    select 1 from profiles where id = auth.uid() and is_platform_admin = true
  ) then
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
