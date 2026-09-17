-- Run in Supabase SQL Editor.
--
-- One definition of "who may run check-in".
--
-- The rule -- owner OR can_manage_events OR can_check_in -- has lived
-- in two places since 052: inline in set_registration_checked_in()
-- (from 044, widened by 045) and in can_run_event_checkin(), which
-- 052 added because it needed the same test in four policies. 052 said
-- outright that consolidating was worth doing on its own rather than
-- in passing, because replacing this function is replacing the only
-- thing that makes check-in work at all. This is that migration.
--
-- Two copies of an authorization rule is not a tidiness problem. It is
-- a rule that can be changed in one place and not the other, and the
-- half that keeps the old answer is the half nobody is looking at.

-- === Refuse to run if the live function is not what this expects ===
-- This repo's migrations are tracked, but "tracked" is not "verified":
-- nothing prevents a function from having been edited directly in the
-- dashboard, and silently reverting such an edit is exactly the kind
-- of damage a consolidation is supposed to avoid.
--
-- So the replacement below is conditional on the live body still
-- containing the 045 predicate it claims to be replacing. If it does,
-- swapping it for can_run_event_checkin() is a substitution of equals.
-- If it does not, this migration stops and changes nothing.
do $guard$
declare
  v_def text;
  v_oid oid := to_regprocedure('set_registration_checked_in(uuid, boolean)');
begin
  if v_oid is null then
    raise exception 'set_registration_checked_in(uuid, boolean) does not exist -- run 044 and 045 first.';
  end if;

  v_def := pg_get_functiondef(v_oid);

  -- Already consolidated -- re-running this file must be a harmless
  -- no-op rather than an abort with a misleading message about a
  -- missing rule. Checked FIRST for that reason: the fragments below
  -- are legitimately absent once the swap has happened.
  if position('can_run_event_checkin' in v_def) > 0 then
    raise notice 'Already consolidated; replacing again is a no-op.';
  else
    -- The three fragments that together ARE the rule being replaced.
    -- Checked individually so the error names the missing part rather
    -- than just reporting that something differs.
    if position('c.owner_id = auth.uid()' in v_def) = 0 then
      raise exception 'ABORTED: live set_registration_checked_in has no owner check. Paste its current definition before consolidating.';
    end if;
    if position('cs.can_manage_events' in v_def) = 0 then
      raise exception 'ABORTED: live set_registration_checked_in has no can_manage_events check. Paste its current definition before consolidating.';
    end if;
    if position('cs.can_check_in' in v_def) = 0 then
      raise exception 'ABORTED: live set_registration_checked_in has no can_check_in check -- 045 may not have run. Paste its current definition before consolidating.';
    end if;
  end if;
end
$guard$;

-- The helper must exist before anything depends on it. 052 created it;
-- repeated here so this migration stands alone if they are ever run
-- out of order, and so the single definition is visible in the same
-- file as the thing that now calls it.
create or replace function can_run_event_checkin(p_church_id uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $fn$
  select exists (
      select 1 from churches c
       where c.id = p_church_id and c.owner_id = auth.uid()
    ) or exists (
      select 1 from church_staff cs
       where cs.church_id = p_church_id
         and cs.user_id = auth.uid()
         and (coalesce(cs.can_manage_events, false) or coalesce(cs.can_check_in, false))
    );
$fn$;

revoke all on function can_run_event_checkin(uuid) from public;
grant execute on function can_run_event_checkin(uuid) to authenticated;

-- === The function, with the rule called rather than restated ===
-- Everything else is byte-for-byte what 045 left behind. The only
-- change is the `if not (...)` block becoming a function call, which
-- is what makes this reviewable: a diff of one condition, not a
-- rewritten function that happens to look similar.
create or replace function set_registration_checked_in(
  p_registration_id uuid,
  p_checked_in boolean
)
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_church_id uuid;
  v_new_value timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated.';
  end if;

  select e.church_id into v_church_id
    from event_registrations er
    join events e on e.id = er.event_id
    where er.id = p_registration_id;

  if v_church_id is null then
    raise exception 'REGISTRATION_NOT_FOUND';
  end if;

  -- Was an inline owner/can_manage_events/can_check_in test. Same
  -- rule, one definition, shared with the link policies in 052.
  if not can_run_event_checkin(v_church_id) then
    raise exception 'NOT_PERMITTED_TO_CHECK_IN';
  end if;

  v_new_value := case when p_checked_in then now() else null end;

  update event_registrations
     set checked_in_at = v_new_value
   where id = p_registration_id;

  -- Returned so the client can show the real stored time rather than
  -- the one it optimistically guessed, and so "nothing happened" is
  -- impossible to mistake for success at the call site.
  return v_new_value;
end;
$fn$;

revoke execute on function set_registration_checked_in(uuid, boolean) from anon;

-- === Confirm the swap actually took ===
-- CREATE OR REPLACE succeeding is not evidence the body is what was
-- intended; 049 ran clean and did nothing. Cheap to check, and the
-- alternative is finding out at a check-in desk.
do $verify$
declare
  v_def text := pg_get_functiondef(to_regprocedure('set_registration_checked_in(uuid, boolean)'));
begin
  if position('can_run_event_checkin' in v_def) = 0 then
    raise exception 'VERIFY FAILED: set_registration_checked_in does not call can_run_event_checkin.';
  end if;
  if position('cs.can_manage_events' in v_def) > 0 then
    raise exception 'VERIFY FAILED: the inline rule is still present -- there would now be three copies.';
  end if;
  raise notice 'OK: check-in rule now has one definition.';
end
$verify$;

notify pgrst, 'reload schema';

-- === Deliberately NOT changed ===
-- The SELECT policy from 044, "church staff can view registrations for
-- their church events", is wider than this rule: ANY staff member can
-- read registrations, not only those who can check people in. That
-- asymmetry is correct and must stay. Attendance Insights, the
-- involvement panel and the member reports all read these rows, and
-- narrowing the read to check-in staff would blank those panels for,
-- say, a treasurer with can_manage_giving and nothing else. Reading
-- your own church's registrations and marking someone present are
-- different permissions, and only the second one is this rule.
