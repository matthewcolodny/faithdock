-- Run in the Supabase SQL Editor.
--
-- The directory learns when each person became connected to the church.
--
-- REQUESTED: the person card should say "Joined on <date>" near the top.
-- get_directory_people returns nine columns and not one of them is a
-- date, so there was nothing to show.
--
-- WHAT "JOINED" MEANS HERE, since it has to mean the same thing
-- everywhere it is displayed: the earliest moment this person became
-- connected to THIS church, taken as the earlier of
--
--   * church_memberships.joined_at -- when they became a member, which
--     is the real answer when there is one
--   * their first confirmed registration for one of this church's
--     events -- how somebody who never asked to be a member still gets
--     a sensible date, and usually the first time the church heard of
--     them at all
--
-- DELIBERATELY NOT staff start dates or group sign-ups. Both would be
-- reasonable inputs, and I have not confirmed either table carries a
-- timestamp. church_memberships.joined_at is documented in migration
-- 035 and event_registrations.created_at in 085; guessing at the other
-- two would mean a migration that either fails on a column that is not
-- there or quietly returns null. The preflight checks the two this uses
-- by name before anything is created.
--
-- NULL is a real answer. Somebody added by an import, or staff with no
-- membership row and no registrations, has no date, and the card says
-- so rather than inventing one.
--
-- THE BODY BELOW IS MIGRATION 063'S, VERBATIM, with one expression
-- added. That is not incidental: this is a SECURITY DEFINER function
-- whose entire job is deciding who may see a church's directory, and
-- the rules in it are exact -- membership means is_permanent AND
-- status='approved', visibility must equal 'members' rather than merely
-- not being 'staff_only', email comes from auth.users and not profiles,
-- has_registered_event counts confirmed registrations only. A first
-- draft of this migration rewrote that body from memory and got five of
-- those wrong, which would have changed who can read the list. So it is
-- copied, not recalled.

-- ---------------------------------------------------------------------
-- Preflight: fail by name, before creating anything.
-- ---------------------------------------------------------------------
do $preflight$
declare
  missing text := '';
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'church_memberships'
                   and column_name = 'joined_at') then
    missing := missing || 'church_memberships.joined_at ';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'event_registrations'
                   and column_name = 'created_at') then
    missing := missing || 'event_registrations.created_at ';
  end if;

  if missing <> '' then
    raise exception 'VERIFY FAILED: this migration needs columns that do not exist: %. Nothing was changed.', missing;
  end if;
  raise notice 'Preflight OK: both source columns exist.';
end
$preflight$;

-- A function's return type cannot be changed by CREATE OR REPLACE, so
-- the old one has to go first. The grants below put back what the drop
-- takes away.
drop function if exists get_directory_people(uuid);

create or replace function get_directory_people(target_church_id uuid)
returns table(user_id uuid, full_name text, email text, phone text,
              avatar_url text, is_member boolean, is_staff boolean,
              is_owner boolean, has_registered_event boolean,
              joined_at timestamptz)
language plpgsql
stable security definer
set search_path = public, pg_temp
as $fn$
declare
  v_privileged   boolean;
  v_visibility   text;
  v_show_contact boolean;
begin
  -- Unchanged from the deployed version: owner or staff of THIS church.
  v_privileged := (
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or is_church_staff_member(target_church_id)
  );

  select c.directory_visibility, c.members_see_contact_details
    into v_visibility, v_show_contact
    from churches c
   where c.id = target_church_id;

  if not v_privileged then
    -- coalesce to the private option: a church whose column is somehow
    -- null must not have its directory opened by that.
    if coalesce(v_visibility, 'staff') <> 'members' then
      return;
    end if;
    -- is_permanent AND status = 'approved', matching what this function
    -- already uses to decide who COUNTS as a member below. A pending or
    -- rejected request is not a member.
    if not exists (
      select 1 from church_memberships cm
       where cm.church_id = target_church_id
         and cm.user_id = auth.uid()
         and cm.is_permanent = true
         and cm.status = 'approved'
    ) then
      return;
    end if;
  end if;

  return query
  select
    p.id as user_id,
    p.full_name::text,
    -- Staff always see contact details; a member only when the church
    -- turned that on. NULL rather than an empty string, so a caller
    -- cannot tell "withheld" from "blank" by the value's type.
    case when v_privileged or coalesce(v_show_contact, false) then u.email::text else null end,
    case when v_privileged or coalesce(v_show_contact, false) then p.phone::text else null end,
    p.avatar_url::text,
    coalesce(cm.is_permanent, false) as is_member,
    (cs.id is not null) as is_staff,
    coalesce(c.owner_id = p.id, false) as is_owner,
    exists(
      select 1 from event_registrations er
      join events e on e.id = er.event_id
      where er.user_id = p.id and e.church_id = target_church_id and er.status = 'confirmed'
    ) as has_registered_event,
    -- THE ONE ADDITION. least() ignores nulls, so somebody with only one
    -- of the two gets that one, and somebody with neither gets null.
    -- cm is already joined on is_permanent AND status='approved', so a
    -- pending request contributes no date -- which is right: they have
    -- not joined anything yet.
    least(
      cm.joined_at,
      (select min(er3.created_at)
         from event_registrations er3
         join events e3 on e3.id = er3.event_id
        where er3.user_id = p.id
          and e3.church_id = target_church_id
          and er3.status = 'confirmed')
    ) as joined_at
  from profiles p
  join auth.users u on u.id = p.id
  left join church_memberships cm on cm.user_id = p.id and cm.church_id = target_church_id and cm.is_permanent = true and cm.status = 'approved'
  left join church_staff cs on cs.user_id = p.id and cs.church_id = target_church_id
  left join churches c on c.id = target_church_id and c.owner_id = p.id
  where cm.id is not null
     or cs.id is not null
     or c.owner_id = p.id
     or exists(
       select 1 from event_registrations er2
       join events e2 on e2.id = er2.event_id
       where er2.user_id = p.id and e2.church_id = target_church_id and er2.status = 'confirmed'
     );
end;
$fn$;

-- The drop removed every grant, so these are doing real work here
-- rather than asserting -- unlike in 063, where CREATE OR REPLACE kept
-- them. Postgres grants EXECUTE to PUBLIC by default on a new function,
-- which is why PUBLIC and anon have to be revoked explicitly.
revoke all on function get_directory_people(uuid) from public;
revoke all on function get_directory_people(uuid) from anon;
grant execute on function get_directory_people(uuid) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Verify. The grants matter more than the new column: a drop-and-
-- recreate that quietly left EXECUTE with PUBLIC would hand every
-- signed-out visitor a church's member list.
-- ---------------------------------------------------------------------
do $verify$
begin
  if not exists (
    select 1 from information_schema.parameters pm
    join information_schema.routines r on r.specific_name = pm.specific_name
    where r.routine_schema = 'public' and r.routine_name = 'get_directory_people'
      and pm.parameter_name = 'joined_at'
  ) then
    raise exception 'VERIFY FAILED: get_directory_people has no joined_at in its output.';
  end if;

  if not has_function_privilege('authenticated', 'get_directory_people(uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: authenticated cannot execute it -- the directory would be empty for everyone.';
  end if;
  if has_function_privilege('anon', 'get_directory_people(uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon can execute it. The drop re-granted PUBLIC and the revoke did not take.';
  end if;

  raise notice 'OK: joined_at present, authenticated may execute, anon may not.';
end
$verify$;

select
  'get_directory_people' as function_name,
  has_function_privilege('authenticated', 'get_directory_people(uuid)', 'EXECUTE') as authenticated_can_run,
  has_function_privilege('anon', 'get_directory_people(uuid)', 'EXECUTE') as anon_can_run,
  exists (
    select 1 from information_schema.parameters pm
    join information_schema.routines r on r.specific_name = pm.specific_name
    where r.routine_schema = 'public' and r.routine_name = 'get_directory_people'
      and pm.parameter_name = 'joined_at'
  ) as joined_at_returned;
