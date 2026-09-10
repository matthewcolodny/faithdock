-- Run in Supabase SQL Editor.
--
-- Adds churches.is_hidden -- a church flagged hidden is kept fully
-- usable by its owner (dashboard, My Churches, event creation, direct
-- #church/<name> URL) but drops off every PUBLIC discovery surface:
-- the directory grid, the homepage "Churches near you" strip, and all
-- church search (search_churches), plus -- once migration 019 lands
-- with the search_events patch -- the homepage "Upcoming events" and
-- the Events page.
--
-- Purpose: the 5 churches currently in the directory are all
-- test/internal entries (Lorem ipsum descriptions, test.com sites,
-- "Test N" names, "Isis" as a denomination, no connected payout
-- account). This hides them without deleting them, so they stay
-- available for testing.

alter table churches add column if not exists is_hidden boolean not null default false;

-- search_churches is SECURITY INVOKER; its WHERE now reads is_hidden,
-- so anon/authenticated need column-level SELECT on it (same
-- privilege-model lesson as the churches.* / stripe-column lockdown).
grant select (is_hidden) on churches to anon, authenticated;

-- Platform-admin-only toggle. A church's normal UPDATE RLS is
-- owner/permitted-staff only, so an admin who doesn't own the church
-- can't flip this directly -- it needs a SECURITY DEFINER RPC, same
-- pattern as review_church_verification / admin_delete_unclaimed_church.
create or replace function admin_set_church_hidden(target_church_id uuid, hidden boolean)
returns void
language plpgsql
security definer
as $$
begin
  if not exists (select 1 from profiles where id = auth.uid() and is_platform_admin = true) then
    raise exception 'You do not have permission to change a church''s visibility.';
  end if;
  update churches set is_hidden = hidden where id = target_church_id;
end;
$$;

grant execute on function admin_set_church_hidden(uuid, boolean) to authenticated;

-- Hide the current test/internal churches.
update churches set is_hidden = true where id in (
  '4b2cb761-3d49-4d47-ac7f-81c98308daee',  -- Catholic Church of San Antonio
  'eecf143e-ee26-4383-bcd4-3cd49f38687d',  -- Church of Isis
  '3ebef06e-eb4a-4674-a232-6c80abfa5683',  -- Test 2
  'acd1af32-0dde-499f-8f26-f9e9a121324c',  -- Test 2 church
  'ce5fc05e-4b02-4489-acfb-da672c5391f4'   -- Test 4
);

-- search_churches: migration 017's body verbatim + one WHERE clause
-- ("and c.is_hidden = false"). Return shape is unchanged, so
-- CREATE OR REPLACE is fine here (no DROP needed).
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

notify pgrst, 'reload schema';
