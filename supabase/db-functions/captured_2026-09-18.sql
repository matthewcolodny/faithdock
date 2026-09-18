-- CAPTURED FROM THE LIVE DATABASE, 2026-09-18. Not a migration.
--
-- Sixteen RPCs the client calls that had no source anywhere in this
-- repo. Verbatim output of pg_get_functiondef. Do not run this file;
-- see this folder's README.
--
-- === Findings from reading them, recorded here so they are not
-- === re-discovered from scratch later
--
-- 1. get_person_group_signups DOES NOT EXIST. index.html calls it from
--    the directory person modal, logs the error to the console and
--    renders "No group sign-ups yet." -- so somebody in three groups
--    shows as being in none. Created by migration 062.
--
-- 2. directory_visibility and members_see_contact_details (migration
--    059) are WRITTEN AND NEVER READ. get_directory_people below is
--    owner-or-staff only, with no reference to either column, so
--    "Staff and approved members" does nothing and neither does the
--    contact-details switch. See GOTCHAS.md.
--
-- 3. get_mass_email_recipients' 'members' branch filters
--    is_permanent = true but NOT status = 'approved',
--    while get_directory_people filters on both. The two disagree
--    about who a member is.
--
-- 4. get_user_id_by_email's permission check is "owns ANY church, or is
--    staff of ANY church, or leads any group" -- not scoped to a
--    church. Any staff member anywhere can resolve any email address to
--    a user id.
--
-- 5. search_events is the only one here that is NOT security definer.
--    That is correct -- it is the public event feed and RLS should
--    apply as the caller -- but worth knowing before anyone "fixes" it.
--
-- 6. get_my_plan_and_usage derives the account's plan as the HIGHEST
--    ranked plan among churches owned. Transferring a church away can
--    therefore lower the account's own limits.
--
-- === Still not captured ===
-- is_church_staff_member, is_group_leader,
-- compute_involvement_snapshot_internal -- all referenced below, none
-- in this repo. Next sweep.


-- ============================================================
-- Directory and people
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_directory_people(target_church_id uuid)
 RETURNS TABLE(user_id uuid, full_name text, email text, phone text, avatar_url text, is_member boolean, is_staff boolean, is_owner boolean, has_registered_event boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not (
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or is_church_staff_member(target_church_id)
  ) then
    return;
  end if;

  return query
  select
    p.id as user_id,
    p.full_name::text,
    u.email::text,
    p.phone::text,
    p.avatar_url::text,
    coalesce(cm.is_permanent, false) as is_member,
    (cs.id is not null) as is_staff,
    coalesce(c.owner_id = p.id, false) as is_owner,
    exists(
      select 1 from event_registrations er
      join events e on e.id = er.event_id
      where er.user_id = p.id and e.church_id = target_church_id and er.status = 'confirmed'
    ) as has_registered_event
  from profiles p
  join auth.users u on u.id = p.id
  left join church_memberships cm on cm.user_id = p.id and cm.church_id = target_church_id and cm.is_permanent = true and cm.status = 'approved'
  left join church_staff cs on cs.user_id = p.id and cs.church_id = target_church_id
  left join churches c on c.id = target_church_id and c.owner_id = p.id
  where cm.id is not null
     or cs.id is not null
     or c.owner_id = p.id
     or exists(
       select 1 from event_registrations er2
       join events e2 on e2.id = er2.event_id
       where er2.user_id = p.id and e2.church_id = target_church_id and er2.status = 'confirmed'
     );
end;
$function$;

CREATE OR REPLACE FUNCTION public.find_church_people_by_email(target_church_id uuid, target_emails text[])
 RETURNS TABLE(user_id uuid, email text, full_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not (
    exists (select 1 from churches c where c.id = target_church_id and c.owner_id = auth.uid())
    or exists (select 1 from church_staff cs where cs.church_id = target_church_id and cs.user_id = auth.uid())
  ) then
    raise exception 'You do not have permission to view this church''s directory.';
  end if;

  return query
    select distinct u.id, u.email::text, p.full_name
    from auth.users u
    join profiles p on p.id = u.id
    where lower(u.email::text) in (select lower(unnest(target_emails)))
      and u.id in (
        select cm.user_id from church_memberships cm where cm.church_id = target_church_id
        union
        select cs2.user_id from church_staff cs2 where cs2.church_id = target_church_id
        union
        select er.user_id from event_registrations er join events e on e.id = er.event_id where e.church_id = target_church_id and er.user_id is not null
        union
        select gm.user_id from group_members gm join groups g on g.id = gm.group_id where g.church_id = target_church_id
      );
end;
$function$;

CREATE OR REPLACE FUNCTION public.find_possible_duplicate_members(target_church_id uuid)
 RETURNS TABLE(person1_id uuid, person1_name text, person1_email text, person2_id uuid, person2_name text, person2_email text, match_reason text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not (
    exists (select 1 from churches c where c.id = target_church_id and c.owner_id = auth.uid())
    or exists (select 1 from church_staff cs where cs.church_id = target_church_id and cs.user_id = auth.uid())
  ) then
    raise exception 'You do not have permission to view this church''s directory.';
  end if;

  return query
    with church_people as (
      select distinct u.id, p.full_name, u.email::text as email
      from auth.users u
      join profiles p on p.id = u.id
      where u.id in (
        select user_id from church_memberships where church_id = target_church_id
        union
        select user_id from church_staff where church_id = target_church_id
        union
        select er.user_id from event_registrations er join events e on e.id = er.event_id where e.church_id = target_church_id and er.user_id is not null
        union
        select gm.user_id from group_members gm join groups g on g.id = gm.group_id where g.church_id = target_church_id
      )
    )
    select
      a.id, a.full_name, a.email,
      b.id, b.full_name, b.email,
      case when a.email = b.email then 'Same email' else 'Similar name' end
    from church_people a
    join church_people b on a.id < b.id
    where (a.email = b.email and a.email is not null)
       or (a.full_name is not null and b.full_name is not null and similarity(a.full_name, b.full_name) > 0.5)
    order by 7 desc, 2;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_person_event_signups(target_church_id uuid, target_user_id uuid)
 RETURNS TABLE(title text, start_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not (
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or is_church_staff_member(target_church_id)
  ) then
    return;
  end if;

  return query
  select e.title::text, e.start_at
  from event_registrations er
  join events e on e.id = er.event_id
  where er.user_id = target_user_id and e.church_id = target_church_id and er.status = 'confirmed'
  order by e.start_at desc;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_person_giving_history(target_church_id uuid, target_user_id uuid)
 RETURNS TABLE(amount_cents integer, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not (
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or is_church_staff_member(target_church_id)
  ) then
    return;
  end if;

  return query
  select d.amount_cents, d.created_at
  from donations d
  where d.donor_id = target_user_id and d.church_id = target_church_id and d.status = 'succeeded'
  order by d.created_at desc;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_user_id_by_email(lookup_email text)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if auth.uid() is null then
    raise exception 'permission denied';
  end if;

  -- is_group_leader() is the existing helper; going through it rather
  -- than reading a role column directly means this keeps agreeing with
  -- however group leadership is defined elsewhere, instead of becoming
  -- a second, drifting definition of the same idea.
  if not (
    exists (select 1 from churches c where c.owner_id = auth.uid())
    or exists (select 1 from church_staff cs where cs.user_id = auth.uid())
    or exists (
      select 1 from group_members gm
      where gm.user_id = auth.uid() and is_group_leader(gm.group_id)
    )
  ) then
    raise exception 'permission denied';
  end if;

  return (select u.id from auth.users u where u.email = lookup_email limit 1);
end;
$function$;


-- ============================================================
-- Events, groups, giving
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_event_registration_counts(p_event_id uuid)
 RETURNS TABLE(participant_count bigint, volunteer_count bigint)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    count(*) filter (where role is distinct from 'volunteer') as participant_count,
    count(*) filter (where role = 'volunteer') as volunteer_count
  from event_registrations
  where event_id = p_event_id and status = 'confirmed';
$function$;

-- NOT security definer, deliberately: this is the public event feed and
-- RLS should apply as the caller.
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

-- NOTE: the 'members' branch filters is_permanent but NOT
-- status = 'approved', unlike get_directory_people. See finding 3.
CREATE OR REPLACE FUNCTION public.get_mass_email_recipients(target_church_id uuid, audience_type text, audience_ref_id uuid DEFAULT NULL::uuid)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  recipient_emails text[];
begin
  if not (
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or is_church_staff_member(target_church_id)
  ) then
    return array[]::text[];
  end if;

  if audience_type = 'members' then
    select array_agg(distinct u.email) into recipient_emails
    from church_memberships cm
    join auth.users u on u.id = cm.user_id
    where cm.church_id = target_church_id and cm.is_permanent = true;

  elsif audience_type = 'staff' then
    select array_agg(distinct u.email) into recipient_emails
    from (
      select user_id from church_staff where church_id = target_church_id
      union
      select owner_id as user_id from churches where id = target_church_id
    ) people
    join auth.users u on u.id = people.user_id;

  elsif audience_type = 'group' then
    select array_agg(distinct u.email) into recipient_emails
    from group_members gm
    join groups g on g.id = gm.group_id
    join auth.users u on u.id = gm.user_id
    where g.id = audience_ref_id and g.church_id = target_church_id and gm.status = 'active';

  elsif audience_type = 'event' then
    select array_agg(distinct u.email) into recipient_emails
    from event_registrations er
    join events e on e.id = er.event_id
    join auth.users u on u.id = er.user_id
    where e.id = audience_ref_id and e.church_id = target_church_id and er.status = 'confirmed';
  end if;

  return coalesce(recipient_emails, array[]::text[]);
end;
$function$;

CREATE OR REPLACE FUNCTION public.compute_involvement_snapshot(target_church_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not (
    exists (select 1 from churches c where c.id = target_church_id and c.owner_id = auth.uid())
    or exists (select 1 from church_staff cs where cs.church_id = target_church_id and cs.user_id = auth.uid())
  ) then
    raise exception 'You do not have permission to compute this for this church.';
  end if;

  return compute_involvement_snapshot_internal(target_church_id);
end;
$function$;


-- ============================================================
-- Plans
-- ============================================================

-- The account's plan is the HIGHEST ranked plan among churches owned,
-- so transferring a church away can lower the account's own limits.
CREATE OR REPLACE FUNCTION public.get_my_plan_and_usage()
 RETURNS TABLE(plan_type text, display_name text, max_churches integer, max_events_per_month integer, max_groups integer, max_staff integer, has_full_analytics boolean, has_ai_copy_help boolean, churches_owned bigint)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with owned as (
    select c.plan_type,
           case c.plan_type
             when 'multi_church' then 5
             when 'premium'      then 4
             when 'standard'     then 3
             when 'starter'      then 2
             else 1
           end as rank
    from churches c
    where c.owner_id = auth.uid()
  ),
  effective as (
    select coalesce(
      (select o.plan_type from owned o order by o.rank desc limit 1),
      'free'
    ) as plan_type
  )
  select
    pt.plan_type, pt.display_name, pt.max_churches, pt.max_events_per_month,
    pt.max_groups, pt.max_staff, pt.has_full_analytics, pt.has_ai_copy_help,
    (select count(*) from churches c where c.owner_id = auth.uid()) as churches_owned
  from effective e
  join plan_tiers pt on pt.plan_type = e.plan_type;
$function$;


-- ============================================================
-- Profile
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_profile_name(new_name text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  last_changed timestamptz;
  next_allowed timestamptz;
begin
  if new_name is null or trim(new_name) = '' then
    raise exception 'Name can''t be empty.';
  end if;

  -- Scoped to whoever is actually calling this (auth.uid()), never a
  -- passed-in id — otherwise this could be used to rename someone
  -- else's profile.
  select full_name_changed_at into last_changed from profiles where id = auth.uid();

  if last_changed is not null and now() < last_changed + interval '60 days' then
    next_allowed := last_changed + interval '60 days';
    raise exception 'You can change your name again on %.', to_char(next_allowed, 'FMMonth FMDD, YYYY');
  end if;

  update profiles set full_name = trim(new_name), full_name_changed_at = now() where id = auth.uid();
end;
$function$;


-- ============================================================
-- Platform admin
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_platform_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((select is_platform_admin from profiles where id = auth.uid()), false);
$function$;

CREATE OR REPLACE FUNCTION public.get_pending_verifications()
 RETURNS TABLE(church_id uuid, name text, address text, website text, denomination text, requested_at timestamp with time zone, owner_name text, owner_email text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not is_platform_admin() then
    return;
  end if;
  return query
  select c.id, c.name::text, c.address::text, c.website::text, c.denomination::text, c.verification_requested_at,
    p.full_name::text, u.email::text
  from churches c
  join profiles p on p.id = c.owner_id
  join auth.users u on u.id = c.owner_id
  where c.verification_status = 'pending'
  order by c.verification_requested_at asc;
end;
$function$;

CREATE OR REPLACE FUNCTION public.review_church_verification(target_church_id uuid, new_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can review verification requests.';
  end if;
  if new_status not in ('verified', 'rejected') then
    raise exception 'Invalid status.';
  end if;
  update churches set verification_status = new_status, verification_reviewed_at = now() where id = target_church_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_recent_client_errors(p_limit integer DEFAULT 30, p_offset integer DEFAULT 0)
 RETURNS TABLE(id uuid, message text, stack text, url text, user_email text, occurred_at timestamp with time zone, total_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not public.is_platform_admin() then
    raise exception 'Only platform administrators can view client error logs.';
  end if;

  return query
    select l.id, l.message, l.stack, l.url, u.email::text, l.occurred_at, count(*) over() as total_count
    from client_error_logs l
    left join auth.users u on u.id = l.user_id
    order by l.occurred_at desc
    limit p_limit offset p_offset;
end;
$function$;
