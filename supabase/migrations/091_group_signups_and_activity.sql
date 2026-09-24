-- Run in the Supabase SQL Editor.
--
-- Two things, both answered by supabase/checks/reports_schema_probe.sql
-- rather than remembered:
--
-- 1. THE DIRECTORY IS MISSING PEOPLE, and one of its filters has never
--    worked. get_directory_people does not return has_group_signup --
--    the client reads person.has_group_signup and filters on it, and
--    that property is set nowhere in the entire file, so the "Group
--    sign-ups" filter has always matched nobody. Worse, the function's
--    WHERE clause lists members, staff, owners and confirmed
--    registrants but not group members, so somebody who only ever
--    joined a group is absent from the directory altogether. The probe
--    counted 2 such people.
--
-- 2. ENGAGEMENT NEEDS A LAST-ACTIVITY DATE. get_people_activity returns
--    the most recent check-in, registration, group join and donation
--    per person, plus the latest of the four, in one round trip.
--
-- COLUMN NAMES ARE THE PROBE'S, NOT MY RECOLLECTION:
--   group_members.joined_at exists; group_members.created_at does NOT
--   donations uses donor_id (not user_id), and status 'succeeded'
--     -- which is what all three of the client's own donation queries
--     filter on, so this cannot drift from what the app treats as paid
--
-- STATUS FILTERS mirror the ones already in this function: a confirmed
-- registration counts, a pending one does not; by the same rule an
-- ACTIVE group membership counts and a pending request does not.
-- group_members.status is 'active' or 'pending' in this app.
--
-- THE BODY OF get_directory_people BELOW IS MIGRATION 089'S, VERBATIM,
-- with three additions marked NEW. That is deliberate: it is a SECURITY
-- DEFINER function deciding who may read a church's member list, and a
-- first draft of 089 rewritten from memory got five of its rules wrong.
-- Copied, not recalled.

-- ---------------------------------------------------------------------
-- Preflight: fail by name before anything is created.
-- ---------------------------------------------------------------------
do $preflight$
declare
  missing text := '';
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='group_members' and column_name='joined_at') then
    missing := missing || 'group_members.joined_at ';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='group_members' and column_name='status') then
    missing := missing || 'group_members.status ';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='donations' and column_name='donor_id') then
    missing := missing || 'donations.donor_id ';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='donations' and column_name='status') then
    missing := missing || 'donations.status ';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='groups' and column_name='church_id') then
    missing := missing || 'groups.church_id ';
  end if;

  if missing <> '' then
    raise exception 'VERIFY FAILED: needs columns that do not exist: %. Nothing was changed.', missing;
  end if;
  raise notice 'Preflight OK.';
end
$preflight$;

-- ---------------------------------------------------------------------
-- 1. get_directory_people: group sign-ups counted, and included.
-- ---------------------------------------------------------------------
drop function if exists get_directory_people(uuid);

create or replace function get_directory_people(target_church_id uuid)
returns table(user_id uuid, full_name text, email text, phone text,
              avatar_url text, is_member boolean, is_staff boolean,
              is_owner boolean, has_registered_event boolean,
              has_group_signup boolean,
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
  v_privileged := (
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or is_church_staff_member(target_church_id)
  );

  select c.directory_visibility, c.members_see_contact_details
    into v_visibility, v_show_contact
    from churches c
   where c.id = target_church_id;

  if not v_privileged then
    if coalesce(v_visibility, 'staff') <> 'members' then
      return;
    end if;
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
    -- NEW (1). The flag the client has always read and nothing has ever
    -- set. 'active' only, matching the 'confirmed' rule on the line
    -- above: a pending request to join is not a sign-up yet.
    exists(
      select 1 from group_members gm
      join groups g on g.id = gm.group_id
      where gm.user_id = p.id and g.church_id = target_church_id and gm.status = 'active'
    ) as has_group_signup,
    -- NEW (2). A group join is now one of the dates "joined" can be.
    --
    -- 089 left it out on purpose -- not because it was wrong, but
    -- because group_members' timestamp column was unconfirmed and
    -- guessing would have meant a migration that either failed or
    -- quietly returned null. The probe has now confirmed joined_at.
    -- Leaving it out would also mean every group-only person added by
    -- NEW (3) below showing "Join date not recorded".
    least(
      cm.joined_at,
      (select min(er3.created_at)
         from event_registrations er3
         join events e3 on e3.id = er3.event_id
        where er3.user_id = p.id
          and e3.church_id = target_church_id
          and er3.status = 'confirmed'),
      (select min(gm3.joined_at)
         from group_members gm3
         join groups g3 on g3.id = gm3.group_id
        where gm3.user_id = p.id
          and g3.church_id = target_church_id
          and gm3.status = 'active')
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
     )
     -- NEW (3). Somebody whose only connection is a group was not in
     -- the directory at all. The probe counted 2 of them.
     or exists(
       select 1 from group_members gm2
       join groups g2 on g2.id = gm2.group_id
       where gm2.user_id = p.id and g2.church_id = target_church_id and gm2.status = 'active'
     );
end;
$fn$;

revoke all on function get_directory_people(uuid) from public;
revoke all on function get_directory_people(uuid) from anon;
grant execute on function get_directory_people(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 2. get_people_activity: when each person last did anything.
--
-- STAFF ONLY, unlike the directory. "Who has gone quiet" is a pastoral
-- judgement about named people; a church that opens its directory to
-- members is not thereby telling every member who has stopped turning
-- up. No members-can-see branch at all.
-- ---------------------------------------------------------------------
create or replace function get_people_activity(target_church_id uuid)
returns table(user_id uuid,
              last_checkin_at timestamptz,
              last_registration_at timestamptz,
              last_group_join_at timestamptz,
              last_donation_at timestamptz,
              last_activity_at timestamptz)
language plpgsql
stable security definer
set search_path = public, pg_temp
as $fn$
begin
  if not (
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or is_church_staff_member(target_church_id)
  ) then
    return;
  end if;

  return query
  with checkins as (
    select er.user_id as uid, max(er.checked_in_at) as at
      from event_registrations er
      join events e on e.id = er.event_id
     where e.church_id = target_church_id and er.checked_in_at is not null
     group by er.user_id
  ),
  regs as (
    select er.user_id as uid, max(er.created_at) as at
      from event_registrations er
      join events e on e.id = er.event_id
     where e.church_id = target_church_id and er.status = 'confirmed'
     group by er.user_id
  ),
  joins as (
    select gm.user_id as uid, max(gm.joined_at) as at
      from group_members gm
      join groups g on g.id = gm.group_id
     where g.church_id = target_church_id and gm.status = 'active'
     group by gm.user_id
  ),
  gifts as (
    select d.donor_id as uid, max(d.created_at) as at
      from donations d
     where d.church_id = target_church_id
       and d.donor_id is not null
       and d.status = 'succeeded'
     group by d.donor_id
  ),
  everyone as (
    select uid from checkins
    union select uid from regs
    union select uid from joins
    union select uid from gifts
  )
  select e.uid,
         c.at, r.at, j.at, g.at,
         -- greatest() ignores nulls in Postgres, the same way least()
         -- does, so somebody with only one kind of activity gets that
         -- one rather than null.
         greatest(c.at, r.at, j.at, g.at) as last_activity_at
    from everyone e
    left join checkins c on c.uid = e.uid
    left join regs     r on r.uid = e.uid
    left join joins    j on j.uid = e.uid
    left join gifts    g on g.uid = e.uid;
end;
$fn$;

revoke all on function get_people_activity(uuid) from public;
revoke all on function get_people_activity(uuid) from anon;
grant execute on function get_people_activity(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Indexes for the two lookups above that had none.
-- ---------------------------------------------------------------------
create index if not exists idx_group_members_user_id on group_members(user_id);
create index if not exists idx_donations_church_donor
  on donations(church_id, donor_id) where donor_id is not null;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Verify. The grants matter most: a drop-and-recreate that left EXECUTE
-- with PUBLIC would hand every signed-out visitor a member list.
-- ---------------------------------------------------------------------
do $verify$
begin
  if not exists (
    select 1 from information_schema.parameters pm
    join information_schema.routines r on r.specific_name = pm.specific_name
    where r.routine_schema='public' and r.routine_name='get_directory_people'
      and pm.parameter_name='has_group_signup'
  ) then
    raise exception 'VERIFY FAILED: get_directory_people has no has_group_signup.';
  end if;
  if not has_function_privilege('authenticated','get_directory_people(uuid)','EXECUTE') then
    raise exception 'VERIFY FAILED: authenticated cannot run get_directory_people -- the directory would be empty for everyone.';
  end if;
  if has_function_privilege('anon','get_directory_people(uuid)','EXECUTE') then
    raise exception 'VERIFY FAILED: anon can run get_directory_people.';
  end if;
  if has_function_privilege('anon','get_people_activity(uuid)','EXECUTE') then
    raise exception 'VERIFY FAILED: anon can run get_people_activity.';
  end if;
  raise notice 'OK.';
end
$verify$;

select
  has_function_privilege('authenticated','get_directory_people(uuid)','EXECUTE') as dir_authenticated,
  has_function_privilege('anon','get_directory_people(uuid)','EXECUTE')          as dir_anon,
  has_function_privilege('authenticated','get_people_activity(uuid)','EXECUTE')  as activity_authenticated,
  has_function_privilege('anon','get_people_activity(uuid)','EXECUTE')           as activity_anon,
  exists (select 1 from information_schema.parameters pm
          join information_schema.routines r on r.specific_name = pm.specific_name
          where r.routine_schema='public' and r.routine_name='get_directory_people'
            and pm.parameter_name='has_group_signup')                            as group_flag_returned,
  -- The 2 the probe found. Run in the SQL Editor auth.uid() is null,
  -- so calling get_directory_people here would return nothing and
  -- prove nothing; this counts the same people the WHERE clause now
  -- admits, and should read 0 once they are all reachable some other
  -- way too -- it is the BEFORE number that mattered.
  (select count(distinct gm.user_id)
     from group_members gm
     join groups g on g.id = gm.group_id
    where gm.status = 'active'
      and not exists (select 1 from church_memberships cm
                       where cm.user_id = gm.user_id and cm.church_id = g.church_id
                         and cm.is_permanent = true and cm.status = 'approved')
      and not exists (select 1 from church_staff cs
                       where cs.user_id = gm.user_id and cs.church_id = g.church_id)
      and not exists (select 1 from churches c
                       where c.id = g.church_id and c.owner_id = gm.user_id)
      and not exists (select 1 from event_registrations er
                       join events e on e.id = er.event_id
                      where er.user_id = gm.user_id and e.church_id = g.church_id
                        and er.status = 'confirmed'))::text                       as group_only_people_now_visible;
