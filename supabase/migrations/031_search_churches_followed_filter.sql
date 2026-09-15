-- Run in Supabase SQL Editor.
--
-- Adds p_church_ids to search_churches(), mirroring the parameter
-- search_events() already has (see 019_search_events_exclude_hidden.sql /
-- 022_search_events_add_keyword.sql: "and (p_church_ids is null or
-- e.church_id = any(p_church_ids))") -- needed so the Directory page's
-- new "Churches I follow" filter checkbox can narrow results
-- server-side, the same way the Events page's own "Churches I follow"
-- filter already does. Without this, search_churches had no way to
-- restrict to a specific set of church ids at all.
--
-- IMPORTANT, same hazard migration 023 already documented and hit for
-- real: Postgres identifies a function by name + full parameter
-- signature. Adding a parameter does NOT get treated as "replacing"
-- the existing 9-parameter version by CREATE OR REPLACE -- it creates a
-- second overloaded search_churches alongside it, and
-- `select * from search_churches()` / PostgREST's RPC call then fails
-- outright with "function search_churches() is not unique". The old
-- 9-parameter overload (migration 023's version, the current one as of
-- this migration) must be dropped explicitly first.

drop function if exists search_churches(
  text, text[], text[], double precision, double precision, double precision, integer, integer, integer
);

create or replace function search_churches(
  p_keyword text default null::text,
  p_denominations text[] default null::text[],
  p_tradition_tags text[] default null::text[],
  p_user_lat double precision default null::double precision,
  p_user_lng double precision default null::double precision,
  p_max_distance_miles double precision default null::double precision,
  p_events_within_days integer default null::integer,
  p_limit integer default 24,
  p_offset integer default 0,
  p_church_ids uuid[] default null::uuid[]
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
      c.is_hidden = false
      and (p_keyword is null or p_keyword = '' or c.name ilike '%' || p_keyword || '%' or c.description ilike '%' || p_keyword || '%')
      and (p_denominations is null or c.denomination = any(p_denominations))
      and (p_tradition_tags is null or c.denomination_tags && p_tradition_tags)
      and (p_church_ids is null or c.id = any(p_church_ids))
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

grant execute on function search_churches(
  text, text[], text[], double precision, double precision, double precision, integer, integer, integer, uuid[]
) to anon, authenticated;

notify pgrst, 'reload schema';
