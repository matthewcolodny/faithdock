-- Run in Supabase SQL Editor.
--
-- Adds `plan_type` to what search_churches() returns, so directory
-- cards can show a "FaithDock Partner" status tag (owner_id set +
-- plan_type != 'free') alongside the existing unclaimed / managed /
-- verified states. plan_type is already in the anon/authenticated
-- column grant on churches (it's read directly by the billing panel
-- and the church page today), so a SECURITY INVOKER function
-- selecting it is fine.
--
-- This is migration 014's function verbatim -- same params, same
-- filtering / distance calc / sorting / pagination -- with `plan_type`
-- added to the `bounded` CTE and the final SELECT, and to the
-- RETURNS TABLE signature. Nothing else changes.
--
-- The RETURNS TABLE shape changes (one new column), so Postgres
-- requires DROP + CREATE -- `create or replace` errors with "cannot
-- change return type of existing function". DROP loses the function's
-- EXECUTE grants, so they're re-added explicitly at the end.

drop function if exists search_churches(text, text[], double precision, double precision, double precision, integer, integer, integer);

create function search_churches(
  p_keyword text default null::text,
  p_denominations text[] default null::text[],
  p_user_lat double precision default null::double precision,
  p_user_lng double precision default null::double precision,
  p_max_distance_miles double precision default null::double precision,
  p_events_within_days integer default null::integer,
  p_limit integer default 24,
  p_offset integer default 0
)
returns table(
  id uuid, name text, denomination text, address text, lat double precision, lng double precision,
  logo_url text, description text, website text, phone text, facebook_url text, instagram_url text,
  verification_status text, owner_id uuid, plan_type text, distance_miles double precision, total_count bigint
)
language sql
security invoker
as $$
  with bounded as (
    select
      c.id, c.name, c.denomination, c.address, c.lat, c.lng, c.logo_url, c.description, c.website,
      c.phone, c.facebook_url, c.instagram_url, c.verification_status, c.owner_id, c.plan_type,
      case when p_user_lat is not null and c.lat is not null and c.lng is not null then
        3958.8 * acos(least(1, greatest(-1,
          cos(radians(p_user_lat)) * cos(radians(c.lat)) * cos(radians(c.lng) - radians(p_user_lng))
          + sin(radians(p_user_lat)) * sin(radians(c.lat))
        )))
      else null end as computed_distance_miles
    from churches c
    where
      (p_keyword is null or p_keyword = '' or c.name ilike '%' || p_keyword || '%' or c.description ilike '%' || p_keyword || '%')
      and (p_denominations is null or c.denomination = any(p_denominations))
      and (
        p_user_lat is null or p_max_distance_miles is null or p_max_distance_miles <= 0
        or (
          c.lat is not null and c.lng is not null
          and c.lat between p_user_lat - (p_max_distance_miles / 69.0) and p_user_lat + (p_max_distance_miles / 69.0)
          and c.lng between p_user_lng - (p_max_distance_miles / (69.0 * cos(radians(p_user_lat)))) and p_user_lng + (p_max_distance_miles / (69.0 * cos(radians(p_user_lat))))
        )
      )
      and (
        p_events_within_days is null or exists (
          select 1 from events e
          where e.church_id = c.id
          and e.start_at between now() and now() + (p_events_within_days || ' days')::interval
        )
      )
  ),
  final as (
    select * from bounded
    where p_user_lat is null or p_max_distance_miles is null or p_max_distance_miles <= 0
      or computed_distance_miles is null or computed_distance_miles <= p_max_distance_miles
  )
  select
    f.id, f.name, f.denomination, f.address, f.lat, f.lng, f.logo_url, f.description, f.website, f.phone,
    f.facebook_url, f.instagram_url, f.verification_status, f.owner_id, f.plan_type, f.computed_distance_miles,
    count(*) over() as total_count
  from final f
  order by
    case when p_user_lat is not null then f.computed_distance_miles end asc nulls last,
    f.name asc
  limit p_limit offset p_offset;
$$;

-- Re-grant EXECUTE (DROP above removed the originals). search_churches
-- is called unauthenticated from the public directory, so anon needs it.
grant execute on function search_churches(text, text[], double precision, double precision, double precision, integer, integer, integer) to anon, authenticated;

notify pgrst, 'reload schema';
