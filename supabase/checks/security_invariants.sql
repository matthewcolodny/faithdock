-- Standing security invariants. Runs read-only, inside a transaction
-- that is rolled back. RAISES on failure rather than printing.
--
-- HOW THIS DIFFERS FROM EVERY OTHER FILE IN THIS FOLDER. The rest are
-- probes: they print numbers for a person to read, they were written to
-- answer one question, and most of those questions are long since
-- answered. This one asserts. It is meant to run unattended, on a
-- schedule, and to be silent until something regresses.
--
-- WHY IT EXISTS. Two holes were found in one session:
--   * members-only events were readable by the entire internet
--     (5 rows returned as anon)
--   * after that was closed, they were still readable by ANY signed-in
--     account that held a membership row for ANY church
-- The second one is the instructive one. It was missed because the
-- verification was run signed OUT, where auth.uid() is null -- a test
-- structurally incapable of catching a membership-keyed bypass. The
-- lesson written into this file: assert the OUTCOME for each role that
-- matters, not the shape of the policy.
--
-- HOW TO RUN
--   Supabase SQL Editor: paste and run. Success is "Success. No rows
--   returned." A failure is a red error naming the invariant.
--   psql:  psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f this-file
--
-- RUN IT BY HAND ONCE before trusting the schedule.

begin;

do $invariants$
declare
  n            int;
  missing      text;
  -- An identity that is authenticated but is a member of nothing. A
  -- random uuid is exactly right here: no real account is needed, and
  -- using one would tie the test to a row somebody might delete.
  stranger     uuid := '00000000-0000-0000-0000-0000000000ff';
  expected_events_select_policies constant int := 1;
begin
  -- ==================================================================
  -- 1. RLS is switched on where the whole model depends on it.
  -- ==================================================================
  -- The anon key is public by design. RLS is the only thing between it
  -- and every row. A table with RLS off is not "permissive", it is open.
  select string_agg(t, ', ' order by t) into missing
  from unnest(array['events','churches','church_memberships','profiles']) as t
  where to_regclass('public.' || t) is not null
    and not (select c.relrowsecurity from pg_class c
             join pg_namespace ns on ns.oid = c.relnamespace
             where ns.nspname = 'public' and c.relname = t);
  if missing is not null then
    raise exception 'INVARIANT FAILED: row-level security is disabled on: %', missing;
  end if;

  -- ==================================================================
  -- 2. Only one SELECT policy on events.
  -- ==================================================================
  -- Permissive policies OR together, so the LOOSEST wins. The original
  -- hole was a second policy nobody remembered. This is a tripwire, not
  -- a law: if a second policy is added deliberately, read it carefully,
  -- satisfy yourself it cannot widen private visibility, then raise the
  -- expected count above.
  select count(*) into n
  from pg_policy p
  join pg_class c on c.oid = p.polrelid
  join pg_namespace ns on ns.oid = c.relnamespace
  where ns.nspname = 'public' and c.relname = 'events'
    and p.polcmd in ('r', '*');
  if n <> expected_events_select_policies then
    raise exception
      'INVARIANT FAILED: events has % SELECT-capable policies, expected %. Permissive policies OR together, so a new one can only widen access. Review it, then update expected_events_select_policies.',
      n, expected_events_select_policies;
  end if;

  -- ==================================================================
  -- 3. Signed out, private events are invisible.
  -- ==================================================================
  set local role anon;
  select count(*) into n from events where visibility = 'private';
  reset role;
  if n <> 0 then
    raise exception 'INVARIANT FAILED: anon can read % private event(s). Members-only events are public.', n;
  end if;

  -- ==================================================================
  -- 4. Signed in but a member of nothing, private events are invisible.
  -- ==================================================================
  -- THIS IS THE ONE THE ORIGINAL VERIFICATION COULD NOT CATCH. Signing
  -- up is free, so "only logged-out users are blocked" is barely a
  -- control at all.
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000ff","role":"authenticated"}';
  select count(*) into n from events where visibility = 'private';
  reset role;
  reset request.jwt.claims;
  if n <> 0 then
    raise exception 'INVARIANT FAILED: an authenticated non-member can read % private event(s).', n;
  end if;

  -- ==================================================================
  -- 5. Draft events are not public either.
  -- ==================================================================
  set local role anon;
  select count(*) into n from events where visibility = 'draft';
  reset role;
  if n <> 0 then
    raise exception 'INVARIANT FAILED: anon can read % draft event(s).', n;
  end if;

  -- ==================================================================
  -- 6. The departures log is not readable by anon.
  -- ==================================================================
  -- It records who left a church and when, including 'removed' and
  -- 'deceased'. Migration 095 revoked anon; this checks it stayed that
  -- way. Guarded on existence so this file still runs against a
  -- database where 094/095 have not been applied.
  if to_regclass('public.church_membership_departures') is not null then
    if has_table_privilege('anon', 'public.church_membership_departures', 'SELECT') then
      raise exception 'INVARIANT FAILED: anon holds SELECT on church_membership_departures.';
    end if;
  end if;

  raise notice 'All security invariants hold.';
end
$invariants$;

rollback;
