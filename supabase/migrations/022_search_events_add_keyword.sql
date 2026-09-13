-- Run in Supabase SQL Editor BEFORE (or in the same deploy as) the
-- front-end build that adds the new Events-page keyword search box.
--
-- The front end now calls search_events() with an extra p_keyword
-- named argument. Supabase/PostgREST RPC calls fail outright when a
-- named argument doesn't match any parameter the function declares,
-- so deploying that front-end change without first running this
-- migration would break the Events page entirely (every search_events
-- call errors, not just keyword searches).
--
-- This is the live search_events definition (from migration 019)
-- verbatim, with:
--   1. A new p_keyword text default null parameter appended at the
--      end (appending, not inserting, keeps this a backward-
--      compatible CREATE OR REPLACE for any other caller still on the
--      old signature).
--   2. One added predicate in the bounded CTE's WHERE, matching
--      search_churches' own keyword predicate (migration 018): a
--      case-insensitive substring match against title or description,
--      short-circuited to "no filter" when p_keyword is null/empty.
--
-- Return-table shape is unchanged, so CREATE OR REPLACE is fine (no
-- DROP) and existing EXECUTE grants are preserved.

CREATE OR REPLACE FUNCTION public.search_events(p_from_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_registration_required boolean[] DEFAULT NULL::boolean[], p_tags text[] DEFAULT NULL::text[], p_church_ids uuid[] DEFAULT NULL::uuid[], p_user_lat double precision DEFAULT NULL::double precision, p_user_lng double precision DEFAULT NULL::double precision, p_max_distance_miles double precision DEFAULT NULL::double precision, p_limit integer DEFAULT 24, p_offset integer DEFAULT 0, p_category_tags text[] DEFAULT NULL::text[], p_keyword text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, title text, description text, start_at timestamp with time zone, end_at timestamp with time zone, location text, registration_required boolean, image_url text, tags text[], audience text, allow_volunteers boolean, max_participants integer, max_volunteers integer, contacts jsonb, price_cents integer, category_tags text[], confirmed_participant_count bigint, church_id uuid, church_name text, church_plan_type text, distance_miles double precision, total_count bigint)
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
      case when p_user_lat is not null and c.lat is not null and c.lng is not null then
        3958.8 * acos(least(1, greatest(-1,
          cos(radians(p_user_lat)) * cos(radians(c.lat)) * cos(radians(c.lng) - radians(p_user_lng))
          + sin(radians(p_user_lat)) * sin(radians(c.lat))
        )))
      else null end as computed_distance_miles
    from events e
    left join churches c on c.id = e.church_id
    where
      e.visibility = 'public'
      and coalesce(c.is_hidden, false) = false
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
    count(*) over() as total_count
  from final f
  order by f.start_at asc
  limit p_limit offset p_offset;
$function$;

notify pgrst, 'reload schema';
