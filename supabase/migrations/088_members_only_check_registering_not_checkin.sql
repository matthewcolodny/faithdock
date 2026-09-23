-- Run in the Supabase SQL Editor.
--
-- Checking someone in stops being blocked by a members-only event.
--
-- REPORTED: tapping a row on the Check-In page raised
--
--   Could not update check-in status: EVENT_MEMBERS_ONLY
--
-- on a person who was already registered and already sitting on the
-- roster.
--
-- WHY
--
-- Migration 037 added enforce_event_members_only() to keep non-members
-- out of a members-only event. Correct, and it belongs in the database
-- rather than the browser. But the trigger is:
--
--   before insert OR UPDATE on event_registrations
--
-- and checking somebody in is an UPDATE of that row -- it sets
-- checked_in_at. So the membership test ran again, at the door, against
-- somebody whose registration already existed, and refused to mark them
-- present.
--
-- The rule is about who may TAKE A PLACE. It is not about whether the
-- person standing in front of you arrived. Once a registration exists,
-- every later question about that row -- did they turn up, did they pay,
-- were they moved to the waitlist -- is a different question.
--
-- HOW IT HAPPENS. The two only disagree once something changes after
-- the registration was made, and several ordinary things do:
--
--   * the event is switched to members-only, or to private, after
--     people have already signed up
--   * somebody registers as a member and then leaves the church
--   * the row was written by a service-role caller (a paid checkout
--     completing through an edge function), which 037 deliberately
--     exempts on insert -- and then nobody can ever check that person
--     in, because the exemption does not apply to the update
--
-- In all three the registration is real and the person is at the door.
--
-- THE CHANGE. On UPDATE, the test is skipped unless the registration is
-- actually being re-pointed at a different person or a different event
-- -- which is the only kind of update that could smuggle somebody into
-- a members-only event. INSERT is untouched, so the rule this function
-- exists for is exactly as strong as it was.

create or replace function enforce_event_members_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_requires_membership boolean;
  v_church_id uuid;
begin
  -- An update that leaves the person and the event alone is not somebody
  -- taking a place; it is a fact about a place already taken. Checking
  -- in, recording a payment, moving to the waitlist -- none of them are
  -- this function's business.
  if tg_op = 'UPDATE'
     and new.user_id is not distinct from old.user_id
     and new.event_id is not distinct from old.event_id then
    return new;
  end if;

  -- A cancellation or any non-confirmed row isn't someone taking a
  -- spot, so it has nothing to prove.
  if new.status is distinct from 'confirmed' then
    return new;
  end if;

  select e.church_id,
         (e.members_only_registration or e.visibility = 'private')
    into v_church_id, v_requires_membership
    from events e where e.id = new.event_id;

  if not coalesce(v_requires_membership, false) then
    return new;
  end if;

  -- Service-role callers (edge functions completing a paid checkout,
  -- for instance) have already done their own checking and have no
  -- auth.uid() to test against.
  if auth.uid() is null then
    return new;
  end if;

  if not exists (
    select 1 from church_memberships cm
    where cm.church_id = v_church_id
      and cm.user_id = new.user_id
      and cm.status = 'approved'
  ) then
    raise exception 'EVENT_MEMBERS_ONLY';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Verify.
--
-- Structural, deliberately. The behavioural test would need a
-- members-only event, a non-member, and a registration row that
-- already exists -- which means INSERTING one, and a verify block that
-- writes a fake registration into a live table is a worse idea than a
-- weaker check. The editor commits on success, so anything created
-- here would stay.
--
-- So this confirms the guard is in the function that is now installed,
-- and the real proof is the one already available: tap a row on the
-- Check-In page for the event that was failing.
-- ---------------------------------------------------------------------
do $verify$
declare
  v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'enforce_event_members_only';

  if v_src is null then
    raise exception 'VERIFY FAILED: enforce_event_members_only() does not exist.';
  end if;
  if position('tg_op = ''UPDATE''' in v_src) = 0 then
    raise exception 'VERIFY FAILED: the installed function has no UPDATE guard -- the old version is still in place.';
  end if;
  if position('EVENT_MEMBERS_ONLY' in v_src) = 0 then
    raise exception 'VERIFY FAILED: the members-only check itself is missing. INSERT would no longer be protected.';
  end if;

  raise notice 'OK: the UPDATE guard is installed and the INSERT check is intact.';
end
$verify$;

-- The last statement returning rows is what the editor shows.
select
  'enforce_event_members_only' as function_name,
  (select count(*) from pg_trigger where tgname = 'event_registrations_members_only') as trigger_present,
  (select position('tg_op = ''UPDATE''' in pg_get_functiondef(p.oid)) > 0
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'enforce_event_members_only') as update_guard_present;
