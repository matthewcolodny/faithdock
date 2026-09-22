-- Run in Supabase SQL Editor. Reads only; changes nothing.
--
-- Does the SQL added in 077/078 produce the same numbers the JavaScript
-- it replaced produced?
--
-- This is not a test of the RPCs against themselves. The right-hand side
-- of every comparison below is written independently, from what the OLD
-- browser code did, and deliberately by a different route where one
-- exists -- counting distinct users through a different join, summing
-- before filtering rather than after. Two expressions that agree by
-- construction agree about nothing.
--
-- HOW TO USE
--   1. Put the church's id in the one place marked below.
--   2. Run the whole file.
--   3. Read the `verdict` column. Anything not 'match' is worth telling
--      Claude about WITH BOTH NUMBERS -- the old code is what people
--      have been reading, so it does not automatically lose.
--
-- A church with no giving, no check-ins or no groups will show 0 = 0 on
-- those rows, which is a match and proves nothing. Run it against the
-- busiest church available.

-- ======================================================================
--                    PUT THE CHURCH ID HERE
-- ======================================================================
create temporary view _v_params as
  select '00000000-0000-0000-0000-000000000000'::uuid as church_id;
-- ======================================================================


-- ---- The three RPCs, called once each ---------------------------------
create temporary view _v_rpc as
  select get_giving_insights((select church_id from _v_params), 'America/Chicago') as giving,
         get_attendance_insights((select church_id from _v_params))                as attendance,
         get_groups_insights((select church_id from _v_params))                    as groups,
         get_people_stats((select church_id from _v_params))                       as people;


-- ---- Independently computed, the way the old client did ---------------
create temporary view _v_expected as
with p as (select church_id from _v_params),

-- Giving. The old code pulled every succeeded donation and reduced in
-- JS: sum of amount_cents; count of rows; distinct of
-- (donor_id || donor_email || 'unknown').
d as (
  select amount_cents, donor_id, donor_email
  from donations, p
  where donations.church_id = p.church_id and status = 'succeeded'
),

-- Attendance. Confirmed registrations on this church's events. The old
-- code counted check-ins as rows where checked_in_at was not null.
reg as (
  select er.checked_in_at, er.user_id
  from event_registrations er
  join events e on e.id = er.event_id, p
  where e.church_id = p.church_id and er.status = 'confirmed'
),

-- Groups. Note active_groups counted DISTINCT group_id among active
-- members, not groups with a flag set.
grp as (select g.id from groups g, p where g.church_id = p.church_id),
gm  as (
  select m.group_id, m.user_id
  from group_members m
  where m.status = 'active' and m.group_id in (select id from grp)
),
ga as (
  select group_id, meeting_date, attended
  from group_attendance
  where group_id in (select id from grp)
),

-- Households.
hh as (select h.id from households h, p where h.church_id = p.church_id),
hm as (select x.user_id from household_members x where x.household_id in (select id from hh)),

-- "Our people": the four-source union the old getChurchPeopleIds built
-- in the browser. Written here with UNION ALL + DISTINCT rather than
-- UNION, so it is not the same expression as church_people_ids().
ppl as (
  select distinct user_id from (
    select cm.user_id from church_memberships cm, p
      where cm.church_id = p.church_id and cm.status = 'approved' and cm.user_id is not null
    union all
    select s.user_id from church_staff s, p where s.church_id = p.church_id and s.user_id is not null
    union all
    select er.user_id from event_registrations er join events e on e.id = er.event_id, p
      where e.church_id = p.church_id and er.user_id is not null
    union all
    select gmm.user_id from group_members gmm join groups g on g.id = gmm.group_id, p
      where g.church_id = p.church_id and gmm.user_id is not null
  ) u
)

select
  (select coalesce(sum(amount_cents), 0) from d)                                   as giving_total_cents,
  (select count(*) from d)                                                         as giving_donation_count,
  (select count(distinct coalesce(donor_id::text, donor_email, 'unknown')) from d) as giving_donor_count,

  (select count(*) filter (where checked_in_at is not null) from reg)              as att_checked_in,
  (select count(*) from reg)                                                       as att_registered,
  (select count(*) from reg where checked_in_at is not null and user_id is not null) as att_aged_total,

  (select count(*) from grp)                                                       as groups_total,
  (select count(distinct group_id) from gm)                                        as groups_active,
  (select count(distinct user_id) from gm)                                         as groups_people,
  (select count(*) from (select distinct group_id, meeting_date from ga) x)        as groups_meetings,
  (select count(*) filter (where attended) from ga)                                as groups_present,
  (select count(*) from ga)                                                        as groups_att_total,
  (select count(*) from hh)                                                        as households,
  (select count(*) from hm)                                                        as household_slots,
  (select count(distinct user_id) from hm)                                         as people_in_households,

  (select count(*) from ppl)                                                       as total_people,
  (select count(*) from church_memberships cm, p where cm.church_id = p.church_id and cm.status = 'approved') as members,
  (select count(*) from church_staff s, p where s.church_id = p.church_id)         as staff,
  -- donor_id only, no email fallback: People Statistics counted it this
  -- way and the giving page did not. They are SUPPOSED to differ.
  (select count(distinct donor_id) from d where donor_id is not null)              as people_donor_count;


-- ======================================================================
--  The comparison. Read the verdict column.
-- ======================================================================
select
  label,
  from_rpc,
  expected,
  -- IS NOT DISTINCT FROM, not =, so a NULL on either side counts as a
  -- difference rather than evaluating to NULL and quietly landing in
  -- the else branch for the wrong reason.
  case when from_rpc is not distinct from expected then 'match' else '*** DIFFERS ***' end as verdict
from (
  select 'giving: total cents'            as label, (giving->>'total_cents')::bigint    as from_rpc, giving_total_cents     as expected from _v_rpc, _v_expected
  union all select 'giving: donations',        (giving->>'donation_count')::bigint,  giving_donation_count from _v_rpc, _v_expected
  union all select 'giving: donors',           (giving->>'donor_count')::bigint,     giving_donor_count    from _v_rpc, _v_expected
  union all select 'attendance: checked in',   (attendance->>'total_checked_in')::bigint, att_checked_in   from _v_rpc, _v_expected
  union all select 'attendance: registered',   (attendance->>'total_registered')::bigint, att_registered   from _v_rpc, _v_expected
  union all select 'attendance: age denominator', (attendance->>'aged_total')::bigint, att_aged_total      from _v_rpc, _v_expected
  union all select 'groups: total',            (groups->>'total_groups')::bigint,    groups_total          from _v_rpc, _v_expected
  union all select 'groups: active',           (groups->>'active_groups')::bigint,   groups_active         from _v_rpc, _v_expected
  union all select 'groups: people in groups', (groups->>'people_in_groups')::bigint, groups_people        from _v_rpc, _v_expected
  union all select 'groups: meetings tracked', (groups->>'meetings_tracked')::bigint, groups_meetings      from _v_rpc, _v_expected
  union all select 'groups: marks present',    (groups->>'attendance_present')::bigint, groups_present     from _v_rpc, _v_expected
  union all select 'groups: marks total',      (groups->>'attendance_total')::bigint, groups_att_total     from _v_rpc, _v_expected
  union all select 'groups: households',       (groups->>'households')::bigint,      households            from _v_rpc, _v_expected
  union all select 'groups: household slots',  (groups->>'household_slots')::bigint, household_slots       from _v_rpc, _v_expected
  union all select 'groups: in a household',   (groups->>'people_in_households')::bigint, people_in_households from _v_rpc, _v_expected
  union all select 'groups: total people',     (groups->>'total_people')::bigint,    total_people          from _v_rpc, _v_expected
  union all select 'people: total people',     (people->>'total_people')::bigint,    total_people          from _v_rpc, _v_expected
  union all select 'people: members',          (people->>'members')::bigint,         members               from _v_rpc, _v_expected
  union all select 'people: staff (raw)',      (people->>'staff')::bigint,           staff                 from _v_rpc, _v_expected
  union all select 'people: groups',           (people->>'groups')::bigint,          groups_total          from _v_rpc, _v_expected
  union all select 'people: households',       (people->>'households')::bigint,      households            from _v_rpc, _v_expected
  union all select 'people: household slots',  (people->>'household_slots')::bigint, household_slots       from _v_rpc, _v_expected
  union all select 'people: total given',      (people->>'total_given_cents')::bigint, giving_total_cents  from _v_rpc, _v_expected
  union all select 'people: donors (id only)', (people->>'donors')::bigint,          people_donor_count    from _v_rpc, _v_expected
) cmp
-- Ordered by the underlying columns, not by the verdict alias:
-- Postgres accepts a bare output alias in ORDER BY but not an alias
-- inside an expression, so (verdict = ...) is a 42703 here.
-- False sorts first, which puts any mismatch at the top.
order by (from_rpc is not distinct from expected), label;


-- ======================================================================
--  Breakdowns to read by eye. No verdict, because these are the figures
--  whose DEFINITION is the thing worth checking, not their arithmetic.
-- ======================================================================

-- Giving by month. Check the edges: a gift late on the last day of a
-- month should land in that month for a reader in America/Chicago, not
-- the next one. If the church is not in US Central, change the zone in
-- the _v_rpc view above to theirs and run again -- the totals must not
-- move, only the month a boundary gift falls in.
select 'giving by month' as section, m.value->>'month_start' as month, (m.value->>'cents')::bigint as cents
from _v_rpc, jsonb_array_elements(giving->'months') m
order by month;

-- The two donor counts, side by side, so the difference is visible
-- rather than alarming. Giving counts donor-or-email and folds every
-- anonymous gift into one; People Statistics counts signed-in donors
-- only. The first should be >= the second, always.
select 'donor definitions' as section,
       (giving->>'donor_count')::bigint as giving_page_donors,
       (people->>'donors')::bigint      as people_report_donors,
       case when (giving->>'donor_count')::bigint >= (people->>'donors')::bigint
            then 'expected' else '*** giving should never be lower ***' end as sanity
from _v_rpc;

-- Attendance by age counts CHECK-INS, not people: somebody who came to
-- ten events contributes ten. So this total can exceed the headcount,
-- and that is correct rather than a bug.
select 'attendance by age' as section, key as age_range, value::bigint as check_ins
from _v_rpc, jsonb_each_text(attendance->'by_age')
order by age_range;

select 'people by age' as section, key as age_range, value::bigint as people
from _v_rpc, jsonb_each_text(people->'by_age')
order by age_range;

-- Cleanup, so re-running in the same session starts fresh.
drop view if exists _v_expected;
drop view if exists _v_rpc;
drop view if exists _v_params;
