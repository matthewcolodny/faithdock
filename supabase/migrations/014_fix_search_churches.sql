-- Run in Supabase SQL Editor. Urgent -- this fixes the live "Something
-- went wrong loading churches: permission denied for table churches"
-- error, breaking the directory search for everyone right now.
--
-- Root cause: search_churches's `bounded` CTE did `select c.*` --
-- every column of churches, including stripe_customer_id and
-- stripe_subscription_id -- even though the function only ever
-- returns a small subset of columns in its final SELECT. This
-- function is SECURITY INVOKER (confirmed: "Invoker" in the
-- Supabase dashboard), meaning it runs with the CALLER's own
-- privileges, not elevated ones -- so it's bound by the same
-- anon/authenticated column grant as any direct client query. When
-- churches was locked down earlier this session to an explicit
-- public-safe column allowlist (excluding just those two Stripe
-- billing ids), this function broke: Postgres checks column-level
-- privilege for every column a query touches anywhere, including
-- ones pulled in by `c.*` and immediately discarded -- it doesn't
-- matter that the final output never includes them.
--
-- Fix: replace `c.*` with the exact columns this function actually
-- uses (its own WHERE/distance-calc logic only ever touches
-- id/name/denomination/description/lat/lng, and its final SELECT
-- already lists every other column it returns) -- the same
-- explicit-column-list pattern already used everywhere else this
-- session, rather than reopening the churches grant. No behavior
-- changes: the function's actual output columns, filtering, sorting,
-- and pagination are all identical to what was pasted -- only the
-- internal `c.*` becomes an explicit list.

create or replace function search_churches(
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
  verification_status text, owner_id uuid, distance_miles double precision, total_count bigint
)
language sql
security invoker
as $$
  with bounded as (
    select
      c.id, c.name, c.denomination, c.address, c.lat, c.lng, c.logo_url, c.description, c.website,
      c.phone, c.facebook_url, c.instagram_url, c.verification_status, c.owner_id,
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
    f.facebook_url, f.instagram_url, f.verification_status, f.owner_id, f.computed_distance_miles,
    count(*) over() as total_count
  from final f
  order by
    case when p_user_lat is not null then f.computed_distance_miles end asc nulls last,
    f.name asc
  limit p_limit offset p_offset;
$$;
