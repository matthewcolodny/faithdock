-- Run in Supabase SQL Editor. Reads only; changes nothing.
--
-- Does the SQL added in 077/078 produce the same numbers the JavaScript
-- it replaced produced?
--
-- This is not a test of the RPCs against themselves. The right-hand side
-- of every comparison is written independently, from what the OLD
-- browser code did, and by a different route where one exists. Two
-- expressions that agree by construction agree about nothing.
--
-- ONE query, on purpose. The SQL Editor shows only the last statement
-- that returns rows, so the earlier version -- five separate SELECTs --
-- computed the comparison table and then quietly discarded it, showing
-- whichever small breakdown happened to come last. Everything below
-- now arrives in a single result.
--
-- HOW TO USE
--   1. Put the church's id in the one place marked below.
--   2. Run the whole file.
--   3. Read the `verdict` column. Rows are ordered so anything wrong is
--      at the top. Report a DIFFERS with BOTH numbers -- the old code is
--      what people have been reading, so it does not automatically lose.
--
-- The first row is a guard: it says whether the id pasted below is
-- actually a church. A church with no giving and no check-ins shows
-- 0 = 0 everywhere, which matches and proves nothing -- use the busiest
-- church available.

with params as (
  -- ====================================================================
  --                    PUT THE CHURCH ID HERE
  -- ====================================================================
  select 'ce5fc05e-4b02-4489-acfb-da672c5391f4'::uuid as church_id   -- Test 7
  -- ====================================================================
),

rpc as (
  select get_giving_insights((select church_id from params), 'America/Chicago') as giving,
         get_attendance_insights((select church_id from params))                as attendance,
         get_groups_insights((select church_id from params))                    as groups,
         get_people_stats((select church_id from params))                       as people
),

-- ---- Independently computed, the way the old client did ---------------
d as (
  select amount_cents, donor_id, donor_email
  from donations, params
  where donations.church_id = params.church_id and status = 'succeeded'
),
reg as (
  select er.checked_in_at, er.user_id
  from event_registrations er
  join events e on e.id = er.event_id, params
  where e.church_id = params.church_id and er.status = 'confirmed'
),
grp as (select g.id from groups g, params where g.church_id = params.church_id),
gm as (
  select m.group_id, m.user_id
  from group_members m
  where m.status = 'active' and m.group_id in (select id from grp)
),
ga as (
  select group_id, meeting_date, attended
  from group_attendance
  where group_id in (select id from grp)
),
hh as (select h.id from households h, params where h.church_id = params.church_id),
hm as (select x.user_id from household_members x where x.household_id in (select id from hh)),

-- The four-source union the old getChurchPeopleIds built in the
-- browser. UNION ALL + DISTINCT rather than UNION, so this is not the
-- same expression as church_people_ids().
ppl as (
  select distinct user_id from (
    select cm.user_id from church_memberships cm, params
      where cm.church_id = params.church_id and cm.status = 'approved' and cm.user_id is not null
    union all
    select s.user_id from church_staff s, params
      where s.church_id = params.church_id and s.user_id is not null
    union all
    select er.user_id from event_registrations er join events e on e.id = er.event_id, params
      where e.church_id = params.church_id and er.user_id is not null
    union all
    select gmm.user_id from group_members gmm join groups g on g.id = gmm.group_id, params
      where g.church_id = params.church_id and gmm.user_id is not null
  ) u
),

expected as (
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
    (select count(*) from church_memberships cm, params where cm.church_id = params.church_id and cm.status = 'approved') as members,
    (select count(*) from church_staff s, params where s.church_id = params.church_id) as staff,
    -- donor_id only, no email fallback: People Statistics counted it
    -- this way and the giving page did not. They are meant to differ.
    (select count(distinct donor_id) from d where donor_id is not null)              as people_donor_count
),

-- ---- Everything to show, as one set ----------------------------------
-- verdict_override is null wherever the generic "do these two agree"
-- rule applies, and set where the row means something else (a guard, a
-- breakdown, a deliberate mismatch).
rows_out as (

  -- The guard. Zeros everywhere usually mean this line says 0.
  select 0 as ord, 'setup' as section, 'church id resolves to a church' as label,
         (select count(*) from churches c, params where c.id = params.church_id)::text as from_rpc,
         '1'::text as expected,
         (case when (select count(*) from churches c, params where c.id = params.church_id) = 1
               then 'ok' else '*** NO SUCH CHURCH -- set the id at the top ***' end)::text as verdict_override
  from params

  union all select 1, 'giving', 'total cents',        (giving->>'total_cents')::text,      giving_total_cents::text,    null::text from rpc, expected
  union all select 1, 'giving', 'donations',          (giving->>'donation_count')::text,   giving_donation_count::text, null::text from rpc, expected
  union all select 1, 'giving', 'donors',             (giving->>'donor_count')::text,      giving_donor_count::text,    null::text from rpc, expected
  union all select 1, 'attendance', 'checked in',     (attendance->>'total_checked_in')::text,  att_checked_in::text,   null::text from rpc, expected
  union all select 1, 'attendance', 'registered',     (attendance->>'total_registered')::text,  att_registered::text,   null::text from rpc, expected
  union all select 1, 'attendance', 'age denominator',(attendance->>'aged_total')::text,   att_aged_total::text,        null::text from rpc, expected
  union all select 1, 'groups', 'total',              (groups->>'total_groups')::text,     groups_total::text,          null::text from rpc, expected
  union all select 1, 'groups', 'active',             (groups->>'active_groups')::text,    groups_active::text,         null::text from rpc, expected
  union all select 1, 'groups', 'people in groups',   (groups->>'people_in_groups')::text, groups_people::text,         null::text from rpc, expected
  union all select 1, 'groups', 'meetings tracked',   (groups->>'meetings_tracked')::text, groups_meetings::text,       null::text from rpc, expected
  union all select 1, 'groups', 'marks present',      (groups->>'attendance_present')::text, groups_present::text,      null::text from rpc, expected
  union all select 1, 'groups', 'marks total',        (groups->>'attendance_total')::text, groups_att_total::text,      null::text from rpc, expected
  union all select 1, 'groups', 'households',         (groups->>'households')::text,       households::text,            null::text from rpc, expected
  union all select 1, 'groups', 'household slots',    (groups->>'household_slots')::text,  household_slots::text,       null::text from rpc, expected
  union all select 1, 'groups', 'in a household',     (groups->>'people_in_households')::text, people_in_households::text, null::text from rpc, expected
  union all select 1, 'groups', 'total people',       (groups->>'total_people')::text,     total_people::text,          null::text from rpc, expected
  union all select 1, 'people', 'total people',       (people->>'total_people')::text,     total_people::text,          null::text from rpc, expected
  union all select 1, 'people', 'members',            (people->>'members')::text,          members::text,               null::text from rpc, expected
  union all select 1, 'people', 'staff (raw)',        (people->>'staff')::text,            staff::text,                 null::text from rpc, expected
  union all select 1, 'people', 'groups',             (people->>'groups')::text,           groups_total::text,          null::text from rpc, expected
  union all select 1, 'people', 'households',         (people->>'households')::text,       households::text,            null::text from rpc, expected
  union all select 1, 'people', 'household slots',    (people->>'household_slots')::text,  household_slots::text,       null::text from rpc, expected
  union all select 1, 'people', 'total given',        (people->>'total_given_cents')::text, giving_total_cents::text,   null::text from rpc, expected
  union all select 1, 'people', 'donors (id only)',   (people->>'donors')::text,           people_donor_count::text,    null::text from rpc, expected

  -- Breakdowns, for reading rather than asserting: what is worth
  -- checking in these is the DEFINITION, not the arithmetic.
  union all
  select 2, 'giving by month', m.value->>'month_start', (m.value->>'cents')::text, null::text, 'read'::text
  from rpc, jsonb_array_elements(giving->'months') m

  union all
  select 2, 'attendance by age (CHECK-INS, not people)', key, value, null::text, 'read'::text
  from rpc, jsonb_each_text(attendance->'by_age')

  union all
  select 2, 'people by age', key, value, null::text, 'read'::text
  from rpc, jsonb_each_text(people->'by_age')

  -- The two donor counts side by side. They are SUPPOSED to differ:
  -- giving counts donor-or-email and folds every anonymous gift into
  -- one, People Statistics counts signed-in donors only. The only rule
  -- is that giving can never be the lower of the two.
  union all
  select 3, 'donor definitions', 'giving page vs people report',
         (giving->>'donor_count')::text, (people->>'donors')::text,
         (case when (giving->>'donor_count')::bigint >= (people->>'donors')::bigint
               then 'expected' else '*** giving should never be lower ***' end)::text
  from rpc
),

-- The verdict is settled once, here, so the final SELECT and the ORDER
-- BY cannot disagree about what counts as a pass -- and so ORDER BY
-- never has to mention an alias from its own SELECT list, which is what
-- broke the first version of this file.
judged as (
  select ord, section, label, from_rpc, expected,
         coalesce(verdict_override,
                  -- IS NOT DISTINCT FROM rather than =, so a NULL on
                  -- either side reports as a difference instead of
                  -- evaluating to NULL and reaching the else branch for
                  -- the wrong reason.
                  case when from_rpc is not distinct from expected
                       then 'match' else '*** DIFFERS ***' end) as verdict
  from rows_out
)

select section, label, from_rpc, expected, verdict
from judged
order by
  -- Anything wrong first, whatever section it is in.
  (verdict in ('match', 'ok', 'expected', 'read')),
  ord, section, label;
