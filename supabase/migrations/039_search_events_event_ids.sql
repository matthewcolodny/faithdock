-- Run in Supabase SQL Editor. Requires migrations 037 and 038.
--
-- Adds p_event_ids to search_events(), so the Events page can offer an
-- "Events I follow" filter the same way it already offers "Churches I
-- follow" -- which needed exactly this treatment on the church side,
-- where migration 031 added p_church_ids to search_churches().
--
-- Filtering client-side instead was the obvious shortcut and is wrong
-- here: search_events paginates and returns total_count, so throwing
-- rows away after the fact would give a wrong count, a "Load more"
-- button that lies, and pages that come back part-empty. The filter has
-- to happen where the LIMIT does.
--
-- An empty array means "no events match", not "no filter" -- deliberate,
-- and the same semantics p_church_ids already has. `= any('{}')` is
-- false for every row, which is the right answer to "show me the events
-- I follow" when you follow none. The client hides the checkbox in that
-- case anyway, so it shouldn't come up, but the RPC shouldn't depend on
-- the client remembering to.

-- DROP first, then recreate. CREATE OR REPLACE cannot add a parameter:
-- it would leave the 12-argument version in place and create a SECOND
-- 13-argument function beside it. PostgREST then can't tell which one a
-- call means and raises PGRST203 -- which is exactly what migration 022
-- did to this same function (adding p_keyword with CREATE OR REPLACE),
-- silently breaking the homepage preview and the church Events tabs for
-- weeks until 034 dropped the stale overload. Not repeating it.
--
-- This signature must match 037's exactly or the DROP silently matches
-- nothing and we end up with the two-overload problem anyway.
drop function if exists public.search_events(
  timestamp with time zone, timestamp with time zone, boolean[], text[], uuid[],
  double precision, double precision, double precision, integer, integer, text[], text
);

CREATE OR REPLACE FUNCTION public.search_events(p_from_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_registration_required boolean[] DEFAULT NULL::boolean[], p_tags text[] DEFAULT NULL::text[], p_church_ids uuid[] DEFAULT NULL::uuid[], p_user_lat double precision DEFAULT NULL::double precision, p_user_lng double precision DEFAULT NULL::double precision, p_max_distance_miles double precision DEFAULT NULL::double precision, p_limit integer DEFAULT 24, p_offset integer DEFAULT 0, p_category_tags text[] DEFAULT NULL::text[], p_keyword text DEFAULT NULL::text, p_event_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS TABLE(id uuid, title text, description text, start_at timestamp with time zone, end_at timestamp with time zone, location text, registration_required boolean, image_url text, tags text[], audience text, allow_volunteers boolean, max_participants integer, max_volunteers integer, contacts jsonb, price_cents integer, category_tags text[], confirmed_participant_count bigint, church_id uuid, church_name text, church_plan_type text, distance_miles double precision, members_only_registration boolean, total_count bigint)
 LANGUAGE sql
 STABLE
AS $function$
  with bounded as (
    select
      e.id, e.title, e.description, e.start_at, e.end_at, e.location,
      e.registration_required, e.image_url, e.tags, e.audience,
      e.allow_volunteers, e.max_participants, e.max_volunteers, e.contacts, e.price_cents,
      e.category_tags,
      (select count(*) from event_registrations er where er.event_id = e.id and er.status = 'confirmed' and er.role = 'participant') as confirmed_participant_count,
      c.id as church_id, c.name as church_name, c.plan_type as church_plan_type,
      e.members_only_registration,
      case when p_user_lat is not null and c.lat is not null and c.lng is not null then
        3958.8 * acos(least(1, greatest(-1,
          cos(radians(p_user_lat)) * cos(radians(c.lat)) * cos(radians(c.lng) - radians(p_user_lng))
          + sin(radians(p_user_lat)) * sin(radians(c.lat))
        )))
      else null end as computed_distance_miles
    from events e
    left join churches c on c.id = e.church_id
    where
      (
        e.visibility = 'public'
        or (
          e.visibility = 'private'
          and exists (
            select 1 from church_memberships cm
            where cm.church_id = e.church_id
              and cm.user_id = auth.uid()
              and cm.status = 'approved'
          )
        )
      )
      and coalesce(c.is_hidden, false) = false
      -- The one new clause. Restrictive like every other filter here:
      -- it intersects with the rest rather than adding events back in,
      -- so "Events I follow" + a date range means followed events IN
      -- that range, not one or the other.
      and (p_event_ids is null or e.id = any(p_event_ids))
      and (p_from_date is null or e.start_at >= p_from_date)
      and (p_to_date is null or e.start_at <= p_to_date)
      and (p_registration_required is null or e.registration_required = any(p_registration_required))
      and (p_church_ids is null or e.church_id = any(p_church_ids))
      and (
        p_tags is null
        or e.tags is null or array_length(e.tags, 1) is null
        or e.tags && p_tags
      )
      and (
        p_category_tags is null
        or e.category_tags is null or array_length(e.category_tags, 1) is null
        or e.category_tags && p_category_tags
      )
      and (
        p_keyword is null or p_keyword = ''
        or e.title ilike '%' || p_keyword || '%'
        or e.description ilike '%' || p_keyword || '%'
      )
      and (
        p_user_lat is null or p_max_distance_miles is null or p_max_distance_miles <= 0
        or (
          c.lat is not null and c.lng is not null
          and c.lat between p_user_lat - (p_max_distance_miles / 69.0) and p_user_lat + (p_max_distance_miles / 69.0)
          and c.lng between p_user_lng - (p_max_distance_miles / (69.0 * cos(radians(p_user_lat)))) and p_user_lng + (p_max_distance_miles / (69.0 * cos(radians(p_user_lat))))
        )
      )
  ),
  final as (
    select * from bounded
    where p_user_lat is null or p_max_distance_miles is null or p_max_distance_miles <= 0
      or computed_distance_miles is null or computed_distance_miles <= p_max_distance_miles
  )
  select
    f.id, f.title, f.description, f.start_at, f.end_at, f.location,
    f.registration_required, f.image_url, f.tags, f.audience,
    f.allow_volunteers, f.max_participants, f.max_volunteers, f.contacts, f.price_cents,
    f.category_tags, f.confirmed_participant_count,
    f.church_id, f.church_name, f.church_plan_type, f.computed_distance_miles,
    f.members_only_registration,
    count(*) over() as total_count
  from final f
  order by f.start_at asc
  limit p_limit offset p_offset
$function$;

notify pgrst, 'reload schema';

-- After running, confirm there is exactly ONE overload left. Expect a
-- single row; two means the DROP above didn't match and PGRST203 is
-- coming.
-- select oid::regprocedure from pg_proc where proname = 'search_events';
