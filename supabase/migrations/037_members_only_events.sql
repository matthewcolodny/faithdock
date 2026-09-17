-- Run in Supabase SQL Editor. Requires migrations 035/036 (membership
-- approval), since "member" here means an APPROVED member.
--
-- Members-only events, in the three modes that were asked for:
--
--   1. Public              -- anyone can see it, anyone can register.
--   2. Members only, listed -- anyone can SEE it, only members can
--                              register. The incentive case: outsiders
--                              can tell what they're missing.
--   3. Members only, hidden -- non-members can't see it at all.
--
-- Stored as two existing-shaped columns rather than one four-valued
-- enum, because the two questions really are independent and already
-- have homes: `visibility` answers "who can SEE this" (it already has
-- public/private/draft) and the new members_only_registration answers
-- "who can SIGN UP". Mode 2 is genuinely a public listing -- pretending
-- otherwise by giving it its own visibility value would mean teaching
-- every existing visibility check about a new value that, for seeing
-- purposes, behaves exactly like 'public'.
--
--   mode 1: visibility='public',  members_only_registration=false
--   mode 2: visibility='public',  members_only_registration=true
--   mode 3: visibility='private', members_only_registration=true
--
-- Defaults to false, so every existing event stays exactly as public as
-- it is today.

alter table events add column if not exists members_only_registration boolean not null default false;

-- === Seeing: members can now actually see their church's private events ===
-- Today `e.visibility = 'public'` hides 'private' events from everyone,
-- members included, which makes mode 3 useless -- the events exist and
-- nobody can ever see them. Widened so a private event is visible to an
-- approved member of the church that owns it.
--
-- Left as INVOKER (not SECURITY DEFINER) deliberately: the membership
-- subquery only ever reads the CALLER's own rows (cm.user_id =
-- auth.uid()), which any sane policy already allows, so this needs no
-- elevated rights and shouldn't take any. A SECURITY DEFINER search
-- function is a much bigger thing to get wrong.
--
-- DROP first because the return table gains a column -- CREATE OR
-- REPLACE cannot change a function's OUT-parameter row type (42P13).
-- This is also why the parameter list below must match exactly: getting
-- it wrong leaves a second overload behind, which is precisely what
-- broke the homepage and church Events tabs when migration 022 added
-- p_keyword (fixed in 034). After 034 there is exactly one overload;
-- this keeps it that way.

drop function if exists public.search_events(
  timestamp with time zone, timestamp with time zone, boolean[], text[], uuid[],
  double precision, double precision, double precision, integer, integer, text[], text
);

CREATE OR REPLACE FUNCTION public.search_events(p_from_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_registration_required boolean[] DEFAULT NULL::boolean[], p_tags text[] DEFAULT NULL::text[], p_church_ids uuid[] DEFAULT NULL::uuid[], p_user_lat double precision DEFAULT NULL::double precision, p_user_lng double precision DEFAULT NULL::double precision, p_max_distance_miles double precision DEFAULT NULL::double precision, p_limit integer DEFAULT 24, p_offset integer DEFAULT 0, p_category_tags text[] DEFAULT NULL::text[], p_keyword text DEFAULT NULL::text)
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

-- === Registering: enforced in the database, not just the UI ===
-- The client will hide the Register button for a non-member, but that is
-- a courtesy, not a control -- the whole point of this feature is that a
-- church can rely on it, and anything enforced only in the browser can
-- be skipped by anyone willing to call the API directly. Same reasoning
-- the existing capacity trigger already embodies, and the same
-- fixed-message convention (EVENT_CAPACITY_FULL / EVENT_GUESTS_FULL) so
-- the client can show localized copy instead of a raw database string.
create or replace function enforce_event_members_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_requires_membership boolean;
  v_church_id uuid;
begin
  -- A cancellation or any non-confirmed row isn't someone taking a
  -- spot, so it has nothing to prove.
  if new.status is distinct from 'confirmed' then
    return new;
  end if;

  select e.church_id,
         (e.members_only_registration or e.visibility = 'private')
    into v_church_id, v_requires_membership
    from events e where e.id = new.event_id;

  if not coalesce(v_requires_membership, false) then
    return new;
  end if;

  -- Service-role callers (edge functions completing a paid checkout,
  -- for instance) have already done their own checking and have no
  -- auth.uid() to test against.
  if auth.uid() is null then
    return new;
  end if;

  if not exists (
    select 1 from church_memberships cm
    where cm.church_id = v_church_id
      and cm.user_id = new.user_id
      and cm.status = 'approved'
  ) then
    raise exception 'EVENT_MEMBERS_ONLY';
  end if;

  return new;
end;
$$;

drop trigger if exists event_registrations_members_only on event_registrations;
create trigger event_registrations_members_only
  before insert or update on event_registrations
  for each row execute function enforce_event_members_only();

notify pgrst, 'reload schema';
