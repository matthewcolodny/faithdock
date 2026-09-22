-- Run in Supabase SQL Editor.
--
-- The remaining three Insights loaders, aggregated in the database.
-- Companion to 077, same reasoning and the same security stance.
--
-- Between them, attendance, groups and people statistics made about
-- nineteen round trips and downloaded every confirmed registration,
-- every group attendance mark and every donation a church had ever
-- recorded, to render perhaps forty numbers. The work was never the
-- problem; shipping the rows to do it was.
--
-- EVERY function here is SECURITY INVOKER -- the default, stated by
-- omission and asserted in the verify block at the bottom. These read
-- donations, registrations, attendance and profiles, and the caller
-- must keep seeing exactly what RLS already permits. A DEFINER function
-- would mean restating each of those tables' access rules here, where a
-- subtle mistake shows up as one church reading another's giving. The
-- point of all of this is to move arithmetic, never privilege.

-- ---------------------------------------------------------------------
-- Everyone connected to a church.
--
-- Four sources, unioned and de-duplicated: approved members, staff,
-- anyone who registered for one of its events, anyone in one of its
-- groups. It exists as a function because three callers needed the same
-- definition and previously each rebuilt it -- and a "who counts as one
-- of our people" rule that lives in three places is a rule that will
-- eventually mean three things.
-- ---------------------------------------------------------------------
create or replace function church_people_ids(target_church_id uuid)
returns table (user_id uuid)
language sql
stable
as $fn$
  select cm.user_id from church_memberships cm
    where cm.church_id = target_church_id and cm.status = 'approved' and cm.user_id is not null
  union
  select s.user_id from church_staff s
    where s.church_id = target_church_id and s.user_id is not null
  union
  select er.user_id from event_registrations er
    join events e on e.id = er.event_id
    where e.church_id = target_church_id and er.user_id is not null
  union
  select gm.user_id from group_members gm
    join groups g on g.id = gm.group_id
    where g.church_id = target_church_id and gm.user_id is not null;
$fn$;

-- ---------------------------------------------------------------------
-- Attendance.
--
-- The chart is the last 8 past events; the headline rate is every past
-- event. That difference is deliberate in the original and kept here --
-- a recent-trend snapshot next to the full picture, not two views of
-- the same window.
-- ---------------------------------------------------------------------
create or replace function get_attendance_insights(target_church_id uuid)
returns jsonb
language sql
stable
as $fn$
  with recent_events as (
    select e.id, e.start_at
    from events e
    where e.church_id = target_church_id
      and e.start_at < now()
    order by e.start_at desc
    limit 8
  ),
  recent_counts as (
    select re.id, re.start_at,
           count(*) filter (where er.checked_in_at is not null)::bigint as checked_in
    from recent_events re
    left join event_registrations er
      on er.event_id = re.id and er.status = 'confirmed'
    group by re.id, re.start_at
  ),
  all_regs as (
    select er.checked_in_at, er.user_id
    from event_registrations er
    join events e on e.id = er.event_id
    where e.church_id = target_church_id
      and er.status = 'confirmed'
  ),
  -- Counts REGISTRATIONS, not people: somebody who attends ten events
  -- contributes ten. That is what the previous code measured, and it is
  -- the right measure for "who fills the room" -- but it is not a
  -- headcount, and the two are easy to confuse.
  aged as (
    select p.age_range
    from all_regs r
    join profiles p on p.id = r.user_id
    where r.checked_in_at is not null
      and r.user_id is not null
      and p.age_range in ('under_18','18_24','25_39','40_59','60_79','80_plus')
  ),
  aged_denominator as (
    select count(*)::bigint as n from all_regs
    where checked_in_at is not null and user_id is not null
  )
  select jsonb_build_object(
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object('start_at', start_at, 'checked_in', checked_in) order by start_at)
      from recent_counts), '[]'::jsonb),
    'total_checked_in', (select count(*) filter (where checked_in_at is not null)::bigint from all_regs),
    'total_registered', (select count(*)::bigint from all_regs),
    'by_age',       coalesce((select jsonb_object_agg(age_range, n) from (select age_range, count(*)::bigint as n from aged group by age_range) x), '{}'::jsonb),
    'aged_count',   coalesce((select count(*)::bigint from aged), 0),
    'aged_total',   (select n from aged_denominator)
  );
$fn$;

-- ---------------------------------------------------------------------
-- Groups and households.
-- ---------------------------------------------------------------------
create or replace function get_groups_insights(target_church_id uuid)
returns jsonb
language sql
stable
as $fn$
  with g as (
    select id from groups where church_id = target_church_id
  ),
  active_members as (
    select gm.group_id, gm.user_id
    from group_members gm
    join g on g.id = gm.group_id
    where gm.status = 'active'
  ),
  att as (
    select ga.group_id, ga.meeting_date, ga.attended
    from group_attendance ga
    join g on g.id = ga.group_id
  ),
  hh as (
    select h.id from households h where h.church_id = target_church_id
  ),
  hh_members as (
    select hm.user_id from household_members hm join hh on hh.id = hm.household_id
  )
  select jsonb_build_object(
    'total_groups',      (select count(*)::bigint from g),
    -- "Active" means has at least one active member, not a flag on the
    -- group. A group with nobody in it is the thing worth noticing.
    'active_groups',     (select count(distinct group_id)::bigint from active_members),
    'people_in_groups',  (select count(distinct user_id)::bigint from active_members),
    'total_people',      (select count(*)::bigint from church_people_ids(target_church_id)),
    -- One meeting is one (group, date) pair, however many people were
    -- marked at it.
    'meetings_tracked',  (select count(*)::bigint from (select distinct group_id, meeting_date from att) m),
    'attendance_present',(select count(*) filter (where attended)::bigint from att),
    'attendance_total',  (select count(*)::bigint from att),
    'households',        (select count(*)::bigint from hh),
    'household_slots',   (select count(*)::bigint from hh_members),
    'people_in_households', (select count(distinct user_id)::bigint from hh_members)
  );
$fn$;

-- ---------------------------------------------------------------------
-- People statistics, the printable summary.
-- ---------------------------------------------------------------------
create or replace function get_people_stats(target_church_id uuid)
returns jsonb
language sql
stable
as $fn$
  with people as (
    select user_id from church_people_ids(target_church_id)
  ),
  aged as (
    select p.age_range
    from people pe
    join profiles p on p.id = pe.user_id
    where p.age_range in ('under_18','18_24','25_39','40_59','60_79','80_plus')
  ),
  hh as (select h.id from households h where h.church_id = target_church_id)
  select jsonb_build_object(
    'total_people',   (select count(*)::bigint from people),
    'members',        (select count(*)::bigint from church_memberships where church_id = target_church_id and status = 'approved'),
    -- Raw church_staff rows. The caller adds one for the owner, as it
    -- always has; folding that in here would change the number on a
    -- church whose owner is also listed as staff, which is a separate
    -- question from where the arithmetic runs.
    'staff',          (select count(*)::bigint from church_staff where church_id = target_church_id),
    'groups',         (select count(*)::bigint from groups where church_id = target_church_id),
    'households',     (select count(*)::bigint from hh),
    'household_slots',(select count(*)::bigint from household_members hm join hh on hh.id = hm.household_id),
    -- donor_id only, no email fallback -- this report counted signed-in
    -- donors and the giving page counts donor-or-email. They are
    -- different numbers on purpose and both are kept as they were.
    'total_given_cents', coalesce((select sum(amount_cents)::bigint from donations where church_id = target_church_id and status = 'succeeded'), 0),
    'donors',         (select count(distinct donor_id)::bigint from donations where church_id = target_church_id and status = 'succeeded' and donor_id is not null),
    'by_age',         coalesce((select jsonb_object_agg(age_range, n) from (select age_range, count(*)::bigint as n from aged group by age_range) x), '{}'::jsonb),
    'aged_count',     coalesce((select count(*)::bigint from aged), 0)
  );
$fn$;

revoke all on function church_people_ids(uuid) from public, anon;
revoke all on function get_attendance_insights(uuid) from public, anon;
revoke all on function get_groups_insights(uuid) from public, anon;
revoke all on function get_people_stats(uuid) from public, anon;

grant execute on function church_people_ids(uuid) to authenticated;
grant execute on function get_attendance_insights(uuid) to authenticated;
grant execute on function get_groups_insights(uuid) to authenticated;
grant execute on function get_people_stats(uuid) to authenticated;

notify pgrst, 'reload schema';

do $verify$
declare
  fn text;
begin
  foreach fn in array array['church_people_ids','get_attendance_insights','get_groups_insights','get_people_stats'] loop
    if has_function_privilege('anon', fn || '(uuid)', 'EXECUTE') then
      raise exception 'VERIFY FAILED: anon can execute %.', fn;
    end if;
    if not has_function_privilege('authenticated', fn || '(uuid)', 'EXECUTE') then
      raise exception 'VERIFY FAILED: a signed-in person cannot execute %.', fn;
    end if;
    if (select count(*) from pg_proc where proname = fn) <> 1 then
      raise exception 'VERIFY FAILED: % is overloaded.', fn;
    end if;
    -- The entire security argument. DEFINER here would read every
    -- church's giving and attendance regardless of who asked.
    if (select prosecdef from pg_proc where proname = fn) then
      raise exception 'VERIFY FAILED: % is SECURITY DEFINER; it must be INVOKER so RLS applies.', fn;
    end if;
  end loop;

  raise notice 'OK: attendance, groups and people stats aggregate in Postgres, invoker rights, RLS still in force.';
end
$verify$;
