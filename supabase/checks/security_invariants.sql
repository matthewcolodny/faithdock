-- Standing security invariants. Read-only, inside a transaction that is
-- rolled back. Raises on failure rather than printing.
--
-- HOW THIS DIFFERS FROM EVERY OTHER FILE IN THIS FOLDER. The rest are
-- probes: they print numbers for a person to read, they were written to
-- answer one question, and most of those questions are long since
-- answered. This one asserts. It runs unattended, on a schedule, and
-- stays silent until something regresses.
--
-- WHY IT EXISTS. Two holes were found in one session:
--   * members-only events were readable by the entire internet
--     (5 rows returned as anon)
--   * after that was closed, they were still readable by ANY signed-in
--     account that held a membership row for ANY church
-- The second is the instructive one. It was missed because the check
-- was run signed OUT, where auth.uid() is null -- a test structurally
-- incapable of catching a membership-keyed bypass.
--
-- TWO THINGS THE FIRST VERSION OF THIS FILE GOT WRONG, both worth
-- keeping written down because they are easy to repeat:
--
--   1. It raised on the FIRST failure. The first check was a brittle
--      structural one (a policy count), so it aborted before any of the
--      checks that test actual exposure had run. A monitor that hides
--      the answer to the important question behind a guess about the
--      unimportant one is worse than no monitor. Everything is now
--      collected and reported together.
--
--   2. It treated "events has more than one SELECT policy" as a
--      failure. It is not one. Extra policies are worth LOOKING at,
--      because permissive policies OR together and only ever widen
--      access -- but whether they actually widen it is answered
--      directly by the exposure checks below, which are strictly
--      better evidence than counting. The count is now reported, not
--      enforced.
--
-- HOW TO RUN
--   Supabase SQL Editor: paste and run. Passing returns a table of
--   checks and the current events policies. Failing returns a red error
--   listing every failure at once.
--   psql:  psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f this-file
--
-- Run it by hand once before trusting the schedule.

begin;

do $invariants$
declare
  n         int;
  failures  text[] := '{}';
  missing   text;
  -- An identity that is authenticated but a member of nothing. A random
  -- uuid is exactly right: no real account is needed, and using one
  -- would tie the check to a row somebody might delete.
  stranger  constant text := '00000000-0000-0000-0000-0000000000ff';
begin
  -- ==================================================================
  -- 1. RLS is on where the whole model depends on it.
  -- ==================================================================
  -- The anon key is public by design. RLS is the only thing between it
  -- and every row. A table with RLS off is not permissive, it is open.
  select string_agg(t, ', ' order by t) into missing
  from unnest(array['events','churches','church_memberships','profiles']) as t
  where to_regclass('public.' || t) is not null
    and not (select c.relrowsecurity from pg_class c
             join pg_namespace ns on ns.oid = c.relnamespace
             where ns.nspname = 'public' and c.relname = t);
  if missing is not null then
    failures := failures || ('row-level security is DISABLED on: ' || missing);
  end if;

  -- ==================================================================
  -- 2. Signed out, private events are invisible.
  -- ==================================================================
  begin
    set local role anon;
    select count(*) into n from events where visibility = 'private';
    reset role;
    if n <> 0 then
      failures := failures || ('anon can read ' || n || ' PRIVATE event(s) -- members-only events are public');
    end if;
  exception when others then
    reset role;
    failures := failures || ('could not test anon access to private events: ' || sqlerrm);
  end;

  -- ==================================================================
  -- 3. Signed in but a member of nothing, private events are invisible.
  -- ==================================================================
  -- THE ONE THE ORIGINAL VERIFICATION COULD NOT CATCH. Signing up is
  -- free, so "only logged-out visitors are blocked" is barely a control.
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
                       json_build_object('sub', stranger, 'role', 'authenticated')::text,
                       true);
    select count(*) into n from events where visibility = 'private';
    reset role;
    perform set_config('request.jwt.claims', '', true);
    if n <> 0 then
      failures := failures || ('an authenticated NON-MEMBER can read ' || n || ' private event(s)');
    end if;
  exception when others then
    reset role;
    perform set_config('request.jwt.claims', '', true);
    failures := failures || ('could not test authenticated non-member access: ' || sqlerrm);
  end;

  -- ==================================================================
  -- 4. Draft events are not public either.
  -- ==================================================================
  begin
    set local role anon;
    select count(*) into n from events where visibility = 'draft';
    reset role;
    if n <> 0 then
      failures := failures || ('anon can read ' || n || ' DRAFT event(s)');
    end if;
  exception when others then
    reset role;
    failures := failures || ('could not test anon access to draft events: ' || sqlerrm);
  end;

  -- ==================================================================
  -- 5. The departures log is not readable by anon.
  -- ==================================================================
  -- It records who left a church and when, including 'removed' and
  -- 'deceased'. Migration 095 revoked anon; this checks it stayed
  -- revoked. Guarded on existence so the file still runs against a
  -- database where 094/095 were never applied.
  if to_regclass('public.church_membership_departures') is not null
     and has_table_privilege('anon', 'public.church_membership_departures', 'SELECT') then
    failures := failures || 'anon holds SELECT on church_membership_departures';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception E'SECURITY INVARIANTS FAILED (%):\n  - %',
      array_length(failures, 1), array_to_string(failures, E'\n  - ');
  end if;
end
$invariants$;

-- Only reached when every invariant above holds. Not assertions: this
-- is the context a person needs to judge whether the policy set still
-- looks right. Extra permissive policies can only ever WIDEN access, so
-- a new name appearing here is worth reading even though the exposure
-- checks above passed.
select
  p.polname                                           as policy_name,
  case p.polcmd when 'r' then 'SELECT' when '*' then 'ALL' else p.polcmd::text end as command,
  case p.polpermissive when true then 'PERMISSIVE (ORed)'
                       else 'RESTRICTIVE (ANDed)' end as kind,
  coalesce(
    (select string_agg(r.rolname, ', ' order by r.rolname)
       from pg_roles r where r.oid = any(p.polroles)),
    'PUBLIC (every role)')                            as applies_to,
  pg_get_expr(p.polqual, p.polrelid)                  as using_expression
from pg_policy p
join pg_class c on c.oid = p.polrelid
join pg_namespace ns on ns.oid = c.relnamespace
where ns.nspname = 'public' and c.relname = 'events' and p.polcmd in ('r', '*')
order by p.polname;

rollback;
