-- Run in Supabase SQL Editor. WRITES DATA. Cleanup below is its pair.
--
-- Seeds Test 7 (ce5fc05e-4b02-4489-acfb-da672c5391f4) with the smallest
-- set of rows that can actually disprove something, then leaves the
-- verification script something to check.
--
-- Zeros cannot verify anything: 0 = 0 matches whether or not the SQL is
-- right. Every row here exists to make one specific figure non-trivial,
-- and several are chosen so a plausible mistake would produce a
-- different answer than a correct implementation.
--
-- SCOPE. Everything is attached to objects created here and named with
-- the SEED- prefix, except donations, which carry a
-- stripe_checkout_session_id beginning 'SEED-verify-insights' -- the
-- only free text column on that table, and a UNIQUE one, so each row
-- gets its own suffix. cleanup_test7.sql matches that prefix, scoped
-- to Test 7's id as well, and removes exactly these and nothing else.
--
-- ONE THING IT CHANGES THAT IT DID NOT CREATE: the single existing
-- profile's age_range, which is currently null, is set so the two
-- by-age charts have anything in them at all. Cleanup sets it back to
-- null. If cleanup is never run, that value stays changed -- it is the
-- only row in this file that is not simply deleted afterwards.

do $seed$
declare
  v_church uuid := 'ce5fc05e-4b02-4489-acfb-da672c5391f4';
  v_user   uuid;
  v_user2  uuid;
  v_group  uuid;
  v_house  uuid;
  v_ev1    uuid;
  v_ev2    uuid;
begin
  select owner_id into v_user from churches where id = v_church;
  if v_user is null then
    raise exception 'Test 7 has no owner; nothing to attach rows to.';
  end if;

  -- A second person, if the database has one at all. Several checks
  -- need two people to be meaningful -- "meetings tracked counts
  -- (group, date) pairs, not rows" is indistinguishable from counting
  -- rows when every meeting has exactly one attendee. Borrowed from
  -- wherever, since group_attendance.user_id references auth.users and
  -- not this church's membership, and removed again by cleanup.
  select id into v_user2 from profiles where id <> v_user order by id limit 1;

  -- ---- Events, in the past, so attendance sees them ------------------
  -- Draft on purpose: these must not appear in a public listing while
  -- they exist.
  insert into events (church_id, title, start_at, end_at, visibility, registration_required)
  values (v_church, 'SEED- past event one', now() - interval '21 days', now() - interval '21 days' + interval '2 hours', 'draft', true)
  returning id into v_ev1;

  insert into events (church_id, title, start_at, end_at, visibility, registration_required)
  values (v_church, 'SEED- past event two', now() - interval '14 days', now() - interval '14 days' + interval '2 hours', 'draft', true)
  returning id into v_ev2;

  -- ---- Registrations -------------------------------------------------
  -- THE SAME PERSON CHECKED INTO BOTH EVENTS. This is the point: if
  -- attendance-by-age counts check-ins, the age bucket shows 2 while the
  -- church contains one such human. If somebody ever "fixes" it to count
  -- distinct people, this drops to 1 and the change is visible rather
  -- than silent.
  insert into event_registrations (event_id, user_id, status, checked_in_at)
  values (v_ev1, v_user, 'confirmed', now() - interval '21 days'),
         (v_ev2, v_user, 'confirmed', now() - interval '14 days');

  -- Registered and did NOT turn up, so checked-in and registered differ
  -- and the rate is not trivially 100%. A guest row: user_id null is
  -- allowed here, and it also exercises the age denominator, which
  -- counts only check-ins that have a user.
  insert into event_registrations (event_id, user_id, status, checked_in_at, guest_name)
  values (v_ev1, null, 'confirmed', null, 'SEED- guest who did not come');

  -- ---- A group, with two meetings ------------------------------------
  insert into groups (church_id, name, created_by)
  values (v_church, 'SEED- verify insights group', v_user)
  returning id into v_group;

  insert into group_members (group_id, user_id, status)
  values (v_group, v_user, 'active');

  -- Two dates. Present once, absent once, so "marks present" and "marks
  -- total" cannot be confused with each other.
  insert into group_attendance (group_id, meeting_date, user_id, attended)
  values (v_group, (now() - interval '14 days')::date, v_user, true),
         (v_group, (now() - interval '7 days')::date,  v_user, false);

  -- If a second person exists, add them to ONE of those dates. Now one
  -- meeting has two marks: meetings_tracked = 2 but marks total = 3.
  -- Counting rows instead of distinct pairs would say 3, and the
  -- verification script would catch it.
  if v_user2 is not null then
    insert into group_members (group_id, user_id, status)
    values (v_group, v_user2, 'active');
    insert into group_attendance (group_id, meeting_date, user_id, attended)
    values (v_group, (now() - interval '14 days')::date, v_user2, true);
  end if;

  -- ---- A household ---------------------------------------------------
  insert into households (church_id, name)
  values (v_church, 'SEED- verify insights household')
  returning id into v_house;

  -- relationship deliberately omitted. It is nullable, it carries a
  -- CHECK constraint whose allowed values are not in this repo, and
  -- nothing being verified reads it -- household slots counts rows and
  -- people in households counts distinct users. Guessing at an
  -- enumeration to fill a column nobody looks at is how the first
  -- attempt failed on 23514.
  insert into household_members (household_id, user_id)
  values (v_house, v_user);

  -- ---- Donations -----------------------------------------------------
  -- Distinctive amounts, so a wrong sum is obvious rather than
  -- plausible. Total: 1234+2345+3456+4567+5678 = 17280 cents.
  --
  -- The donor mix is chosen so the two donor definitions MUST disagree:
  --   one with a donor_id            -> counted by both
  --   two with only an email         -> counted by giving, not by people
  --   two with neither               -> giving folds both into 'unknown'
  -- so giving sees 1 + 2 + 1 = 4 donors and people sees 1. Any
  -- implementation that accidentally used the same rule for both would
  -- report the same number twice and be caught.
  -- stripe_checkout_session_id is UNIQUE, so the marker cannot be the
  -- same string on every row -- it is a real Stripe session id in
  -- normal use, and Stripe never reuses one. Suffixed instead, and
  -- cleanup matches the prefix rather than the exact value.
  insert into donations (church_id, donor_id, donor_email, amount_cents, status, created_at, stripe_checkout_session_id)
  values
    (v_church, v_user, null,              1234, 'succeeded', now() - interval '3 days',  'SEED-verify-insights-1'),
    (v_church, null,   'seed-a@example.com', 2345, 'succeeded', now() - interval '5 days',  'SEED-verify-insights-2'),
    (v_church, null,   'seed-b@example.com', 3456, 'succeeded', now() - interval '9 days',  'SEED-verify-insights-3'),
    (v_church, null,   null,              4567, 'succeeded', now() - interval '40 days', 'SEED-verify-insights-4'),

    -- THE BOUNDARY CASE, and the reason p_tz exists at all.
    -- 2026-09-01 04:30 UTC is 2026-08-31 23:30 in America/Chicago. A
    -- month chart built in UTC puts this gift in SEPTEMBER; one built in
    -- the reader's zone puts it in AUGUST, which is where the church's
    -- own books have it. The verification script prints the month rows
    -- so this can be read directly.
    (v_church, null, null, 5678, 'succeeded', timestamptz '2026-09-01 04:30:00+00', 'SEED-verify-insights-5');

  -- ---- Age, so the by-age charts are not empty -----------------------
  -- The only row here that modifies something this script did not
  -- create. Cleanup restores it to null.
  update profiles set age_range = '25_39' where id = v_user and age_range is null;

  raise notice 'Seeded Test 7. Owner %, second person %, group %, events % and %.',
    v_user, coalesce(v_user2::text, '(none found)'), v_group, v_ev1, v_ev2;
end
$seed$;


-- ---------------------------------------------------------------------
-- What the verification script should now show. Read this before
-- running it, so the check is against a stated expectation rather than
-- against whatever it happens to print.
--
--   giving: total cents        17280
--   giving: donations          5
--   giving: donors             4      (id + 2 emails + 1 'unknown')
--   people: donors (id only)   1
--   attendance: registered     3      (2 check-ins + 1 no-show)
--   attendance: checked in     2
--   attendance: age denom.     2      (check-ins that have a user)
--   attendance by age 25_39    2      CHECK-INS, not people -- one human
--   people by age 25_39        1      the same human, counted once
--   groups: total              1
--   groups: meetings tracked   2      two dates
--   groups: marks total        3 if a second person was found, else 2
--   groups: marks present      2 if a second person was found, else 1
--   groups: households         1
--   groups: household slots    1
--   giving by month            AUGUST holds 5678, not September
--
-- The attendance-by-age row being 2 while people-by-age is 1, from a
-- church containing one person, is the whole demonstration that those
-- two charts measure different things.
-- ---------------------------------------------------------------------
