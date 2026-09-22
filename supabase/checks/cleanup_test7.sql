-- Run in Supabase SQL Editor. DELETES the rows seed_test7.sql created.
--
-- Scoped by construction: everything is reached through the SEED- named
-- objects or the 'SEED-verify-insights' marker, and every delete is
-- additionally constrained to Test 7's id. Nothing here can touch a row
-- it did not put there, even if run twice or run against a database
-- where the seed was never applied.
--
-- Run it, then run seed_test7.sql's expectations again: every figure
-- should return to zero. A number that does not go back to zero means
-- something was left behind.

do $cleanup$
declare
  v_church uuid := 'ce5fc05e-4b02-4489-acfb-da672c5391f4';
  v_user   uuid;
  n_reg    int := 0;
  n_att    int := 0;
  n_mem    int := 0;
  n_grp    int := 0;
  n_hm     int := 0;
  n_hh     int := 0;
  n_ev     int := 0;
  n_don    int := 0;
begin
  select owner_id into v_user from churches where id = v_church;

  -- Registrations first, then the events they hang off, rather than
  -- relying on a cascade that may or may not be declared on that
  -- foreign key. Checked rather than assumed.
  delete from event_registrations
  where event_id in (
    select id from events where church_id = v_church and title like 'SEED- %'
  );
  get diagnostics n_reg = row_count;

  delete from group_attendance
  where group_id in (
    select id from groups where church_id = v_church and name like 'SEED- %'
  );
  get diagnostics n_att = row_count;

  delete from group_members
  where group_id in (
    select id from groups where church_id = v_church and name like 'SEED- %'
  );
  get diagnostics n_mem = row_count;

  delete from groups where church_id = v_church and name like 'SEED- %';
  get diagnostics n_grp = row_count;

  delete from household_members
  where household_id in (
    select id from households where church_id = v_church and name like 'SEED- %'
  );
  get diagnostics n_hm = row_count;

  delete from households where church_id = v_church and name like 'SEED- %';
  get diagnostics n_hh = row_count;

  delete from events where church_id = v_church and title like 'SEED- %';
  get diagnostics n_ev = row_count;

  -- Both conditions, deliberately. The marker alone would be enough,
  -- but a stray marker on another church's row must not be deletable
  -- from here.
  delete from donations
  where church_id = v_church and stripe_checkout_session_id like 'SEED-verify-insights%';
  get diagnostics n_don = row_count;

  -- The one field the seed changed rather than created. Only reset if
  -- it still holds the value the seed wrote -- if somebody has since
  -- set a real age on that profile, leave it alone.
  update profiles set age_range = null
  where id = v_user and age_range = '25_39';

  raise notice 'Removed: % registrations, % attendance marks, % group members, % groups, % household members, % households, % events, % donations.',
    n_reg, n_att, n_mem, n_grp, n_hm, n_hh, n_ev, n_don;
end
$cleanup$;


-- Proof it is gone. Every count should be 0.
select 'events left'        as what, count(*) as n from events where church_id = 'ce5fc05e-4b02-4489-acfb-da672c5391f4' and title like 'SEED- %'
union all select 'groups left',       count(*) from groups where church_id = 'ce5fc05e-4b02-4489-acfb-da672c5391f4' and name like 'SEED- %'
union all select 'households left',   count(*) from households where church_id = 'ce5fc05e-4b02-4489-acfb-da672c5391f4' and name like 'SEED- %'
union all select 'donations left',    count(*) from donations where church_id = 'ce5fc05e-4b02-4489-acfb-da672c5391f4' and stripe_checkout_session_id like 'SEED-verify-insights%'
union all select 'age_range left set', count(*) from profiles p join churches c on c.owner_id = p.id where c.id = 'ce5fc05e-4b02-4489-acfb-da672c5391f4' and p.age_range = '25_39';
