-- CAPTURED FROM THE LIVE DATABASE, 2026-09-18. Not a migration.
--
-- The three helpers the other captured functions call. With these, every
-- RPC the client invokes and every helper those RPCs depend on has its
-- source somewhere in this repo.
--
-- === Worth knowing ===
--
-- is_church_staff_member is membership of church_staff, full stop. It
-- does NOT consider abilities (can_manage_events and the rest), so
-- every function gated on it treats "on the team" as sufficient. That
-- is deliberate for the directory and people functions, which is where
-- it is used -- but it is not a permission check, and it should not be
-- reached for as if it were one.
--
-- is_group_leader requires role = 'leader' AND status = 'active', so
-- somebody removed from a group stops being its leader immediately.
--
-- compute_involvement_snapshot_internal draws its `church_people` from
-- `church_memberships` with NO status filter, so a person who merely
-- ASKED to join is counted among a church's people and scored. They
-- will score 0 and land in 'disengaged'. That is the same shape as the
-- bug 040 fixed in get_directory_people and 064 fixed in
-- get_mass_email_recipients -- but unlike those two, this is a metric
-- rather than an audience, and whether a pending request should count
-- as somebody to track is a judgement about what the number means, not
-- an obvious defect. Left as it is, recorded here rather than changed
-- silently.

CREATE OR REPLACE FUNCTION public.is_church_staff_member(target_church_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from church_staff
    where church_id = target_church_id and user_id = auth.uid()
  );
$function$;

CREATE OR REPLACE FUNCTION public.is_group_leader(target_group_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from group_members
    where group_id = target_group_id and user_id = auth.uid()
    and role = 'leader' and status = 'active'
  );
$function$;

CREATE OR REPLACE FUNCTION public.compute_involvement_snapshot_internal(target_church_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  window_start timestamptz := now() - interval '30 days';
  window_end timestamptz := now();
  this_period_month date := date_trunc('month', now())::date;
  affected_count integer := 0;
begin
  with church_people as (
    select distinct user_id from church_memberships where church_id = target_church_id
    union
    select user_id from church_staff where church_id = target_church_id
    union
    select er.user_id from event_registrations er join events e on e.id = er.event_id where e.church_id = target_church_id and er.user_id is not null
    union
    select gm.user_id from group_members gm join groups g on g.id = gm.group_id where g.church_id = target_church_id
  ),
  checkins as (
    select er.user_id, count(*) as checkin_count
    from event_registrations er
    join events e on e.id = er.event_id
    where e.church_id = target_church_id and er.checked_in_at between window_start and window_end
    group by er.user_id
  ),
  giving as (
    select donor_id as user_id, count(*) as gift_count
    from donations
    where church_id = target_church_id and status = 'succeeded' and created_at between window_start and window_end and donor_id is not null
    group by donor_id
  ),
  active_groups as (
    select distinct gm.user_id
    from group_members gm join groups g on g.id = gm.group_id
    where g.church_id = target_church_id and gm.status = 'active'
  ),
  first_seen as (
    select user_id, min(seen_at) as first_at from (
      select user_id, joined_at as seen_at from church_memberships where church_id = target_church_id
      union all
      select cs.user_id, cs.created_at from church_staff cs where cs.church_id = target_church_id
      union all
      select er.user_id, er.created_at from event_registrations er join events e on e.id = er.event_id where e.church_id = target_church_id and er.user_id is not null
      union all
      select gm.user_id, gm.joined_at from group_members gm join groups g on g.id = gm.group_id where g.church_id = target_church_id
    ) x
    group by user_id
  ),
  scored as (
    select
      cp.user_id,
      least(coalesce(ch.checkin_count, 0), 6)
        + (case when coalesce(gv.gift_count, 0) > 0 then 3 else 0 end)
        + (case when ag.user_id is not null then 3 else 0 end) as score,
      fs.first_at
    from church_people cp
    left join checkins ch on ch.user_id = cp.user_id
    left join giving gv on gv.user_id = cp.user_id
    left join active_groups ag on ag.user_id = cp.user_id
    left join first_seen fs on fs.user_id = cp.user_id
  ),
  categorized as (
    select
      user_id, score,
      case
        when first_at >= window_start then 'new'
        when score = 0 then 'disengaged'
        when score <= 3 then 'sporadic'
        when score <= 7 then 'active'
        else 'very_active'
      end as category
    from scored
  ),
  inserted as (
    insert into involvement_snapshots (church_id, user_id, period_month, score, category)
    select target_church_id, user_id, this_period_month, score, category from categorized
    on conflict (church_id, user_id, period_month) do update set score = excluded.score, category = excluded.category, computed_at = now()
    returning 1
  )
  select count(*) into affected_count from inserted;

  return affected_count;
end;
$function$;
