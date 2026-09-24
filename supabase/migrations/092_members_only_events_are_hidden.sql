-- Run in the Supabase SQL Editor.
--
-- "Members only -- hidden from everyone except your members" now
-- actually hides the event.
--
-- THE BUG, verified against production before writing this. The event
-- form offers four visibilities, and the third reads, in the app's own
-- words:
--
--     Members only -- hidden from everyone except your members
--
-- It stores visibility = 'private'. The SELECT policy on events
-- (migration 081) is:
--
--     visibility <> 'draft' or owner or staff_beyond_checkin(...)
--
-- so 'private' falls straight through the first branch. Signed out,
-- with nothing but the anon key that ships in the page, a request for
--
--     /rest/v1/events?visibility=eq.private&select=id,title,start_at,venue_name
--
-- returned 200 and five full rows: titles, dates, venues. Drafts
-- correctly returned none. The "Members only" badge was a label in the
-- client with nothing behind it.
--
-- Not a personal-data leak -- no names or contact details are exposed
-- by this -- but the app makes a specific promise and the database
-- does not keep it.
--
-- WHO MAY STILL READ A MEMBERS-ONLY EVENT. Each of these is a path
-- that exists today and must not break:
--
--   * approved members of that church            -- the point of it
--   * anyone already registered for it           -- or their own
--                                                   registrations list
--                                                   breaks under them
--   * check-in volunteers, at the door           -- migration 088 was
--                                                   about exactly this
--   * the owner and full staff                   -- unchanged
--
-- Anonymous check-in LINKS are unaffected either way: checkin_link_open
-- is SECURITY DEFINER and never consults this policy.
--
-- WHY TWO NEW HELPER FUNCTIONS instead of subqueries in the policy.
-- A policy's USING clause is evaluated as the caller, and RLS on any
-- table it reads applies too. event_registrations' own policy
-- (migration 044) references events -- so an events policy that
-- selected from event_registrations would recurse. Both lookups go
-- through SECURITY DEFINER functions, the same way staff_beyond_checkin
-- already does.
--
-- Both are granted to anon as well as authenticated. For anon
-- auth.uid() is null and they return false, which is the point: a
-- MISSING grant does not return fewer rows, it errors the entire query
-- for that role. That is what broke public event browsing until
-- migration 085, and it is not being repeated here.

-- ---------------------------------------------------------------------
-- Preflight.
-- ---------------------------------------------------------------------
do $preflight$
declare
  missing text := '';
begin
  if to_regprocedure('public.staff_beyond_checkin(uuid)') is null then
    missing := missing || 'staff_beyond_checkin(uuid) ';
  end if;
  if to_regprocedure('public.is_checkin_only_staff(uuid)') is null then
    missing := missing || 'is_checkin_only_staff(uuid) ';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='events' and column_name='visibility') then
    missing := missing || 'events.visibility ';
  end if;
  if missing <> '' then
    raise exception 'VERIFY FAILED: missing %. Nothing was changed.', missing;
  end if;
  raise notice 'Preflight OK.';
end
$preflight$;

-- ---------------------------------------------------------------------
-- Helpers.
-- ---------------------------------------------------------------------

-- is_permanent AND status='approved' -- the same definition
-- get_directory_people uses to decide who counts as a member. A pending
-- request is not membership, and must not unlock a hidden event.
create or replace function is_approved_church_member(target_church_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $fn$
  select exists (
    select 1 from church_memberships cm
     where cm.church_id = target_church_id
       and cm.user_id = auth.uid()
       and cm.is_permanent = true
       and cm.status = 'approved'
  );
$fn$;

-- Any registration, not just confirmed ones: somebody whose place is
-- pending or waitlisted still needs to see what they signed up for.
create or replace function is_registered_for_event(p_event_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $fn$
  select exists (
    select 1 from event_registrations er
     where er.event_id = p_event_id
       and er.user_id = auth.uid()
  );
$fn$;

revoke all on function is_approved_church_member(uuid) from public;
revoke all on function is_registered_for_event(uuid) from public;
grant execute on function is_approved_church_member(uuid) to authenticated, anon;
grant execute on function is_registered_for_event(uuid) to authenticated, anon;

-- ---------------------------------------------------------------------
-- The policy.
-- ---------------------------------------------------------------------
drop policy if exists "Drafts are staff-only; everything else is visible" on events;
drop policy if exists "Drafts staff-only; members-only needs membership" on events;

create policy "Drafts staff-only; members-only needs membership"
  on events for select
  using (
    -- Public, and "members only -- anyone can see it" (which stores
    -- visibility='public' with members_only_registration=true, and is
    -- meant to be visible). coalesce so a null visibility stays public
    -- rather than quietly vanishing.
    coalesce(visibility, 'public') not in ('draft', 'private')

    -- Hidden members-only: the church's own members, and anyone who
    -- already has a registration for it.
    or (visibility = 'private' and (
          is_approved_church_member(events.church_id)
          or is_registered_for_event(events.id)
       ))

    -- Check-in volunteers get everything except drafts, which is what
    -- they had before and what a door shift needs.
    or (coalesce(visibility, 'public') <> 'draft' and is_checkin_only_staff(events.church_id))

    -- Owner and full staff: everything, drafts included. Unchanged.
    or exists (select 1 from churches c where c.id = events.church_id and c.owner_id = auth.uid())
    or staff_beyond_checkin(events.church_id)
  );

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Verify. Structural only -- the SQL Editor runs as a role that
-- bypasses RLS, so it cannot prove what anon sees. The real proof is
-- the same signed-out request that found the bug, re-run afterwards.
-- ---------------------------------------------------------------------
do $verify$
begin
  if not exists (
    select 1 from pg_policy p join pg_class c on c.oid = p.polrelid
    where c.relname = 'events' and p.polcmd = 'r'
      and p.polname = 'Drafts staff-only; members-only needs membership'
  ) then
    raise exception 'VERIFY FAILED: the new SELECT policy on events is not there.';
  end if;
  if exists (
    select 1 from pg_policy p join pg_class c on c.oid = p.polrelid
    where c.relname = 'events' and p.polcmd = 'r'
      and p.polname = 'Drafts are staff-only; everything else is visible'
  ) then
    raise exception 'VERIFY FAILED: the old policy is still there. Two permissive SELECT policies OR together, so the old one would keep private events visible.';
  end if;
  if not has_function_privilege('anon', 'is_approved_church_member(uuid)', 'EXECUTE')
     or not has_function_privilege('anon', 'is_registered_for_event(uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon cannot execute the helpers, so every anonymous events query will error instead of returning public events.';
  end if;
  raise notice 'OK.';
end
$verify$;

select
  (select count(*) from pg_policy p join pg_class c on c.oid = p.polrelid
    where c.relname='events' and p.polcmd='r')                                    as select_policies_on_events,
  has_function_privilege('anon','is_approved_church_member(uuid)','EXECUTE')      as anon_can_check_membership,
  has_function_privilege('anon','is_registered_for_event(uuid)','EXECUTE')        as anon_can_check_registration,
  has_function_privilege('authenticated','is_approved_church_member(uuid)','EXECUTE') as auth_can_check_membership,
  (select count(*) from events where visibility = 'private')::text                as private_events_that_should_now_hide;
