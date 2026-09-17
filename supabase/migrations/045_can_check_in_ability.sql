-- Run in Supabase SQL Editor. Requires migrations 035 and 044.
--
-- Adds can_check_in, so working a check-in desk stops requiring the
-- ability to manage events.
--
-- The motivating case is concrete: check-in is usually run by rotating
-- volunteers on a shared tablet at a door. Before this, the only way to
-- let someone check people in was can_manage_events -- which also lets
-- them edit and delete the event they are standing at. That is a bad
-- trade, and it is why 044 deliberately did NOT gate on a new column:
-- adding one defaulting to false in the same migration that repaired
-- check-in would have locked every existing staff member out on the spot.
--
-- === The permission rule, and why it is an OR ===
--   owner  OR  can_manage_events  OR  can_check_in
--
-- can_check_in is a LESSER permission, not a replacement. Someone who
-- manages events keeps check-in implicitly, because taking it away from
-- them would be a surprising regression nobody would think to fix by
-- granting a new flag. can_check_in grants check-in AND NOTHING ELSE,
-- which is the entire point: it is what a door volunteer gets.
--
-- Because event managers keep access through the existing clause, this
-- migration needs no backfill and cannot remove anyone's access.

alter table church_staff add column if not exists can_check_in boolean not null default false;
-- Mirrored on invites, as every other ability already is (035): an
-- invite carries the abilities the person will have on acceptance, so an
-- ability that exists on staff but not on invites can never be granted
-- to someone who has not joined yet.
alter table church_staff_invites add column if not exists can_check_in boolean not null default false;

-- === The gate itself ===
-- Only the permission clause changes from 044; the rest is carried over
-- unmodified.
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

  if not (
    exists (select 1 from churches c where c.id = v_church_id and c.owner_id = auth.uid())
    or exists (
      select 1 from church_staff cs
      where cs.church_id = v_church_id
        and cs.user_id = auth.uid()
        and (coalesce(cs.can_manage_events, false) or coalesce(cs.can_check_in, false))
    )
  ) then
    raise exception 'NOT_PERMITTED_TO_CHECK_IN';
  end if;

  v_new_value := case when p_checked_in then now() else null end;

  update event_registrations
     set checked_in_at = v_new_value
   where id = p_registration_id;

  return v_new_value;
end;
$fn$;

revoke execute on function set_registration_checked_in(uuid, boolean) from anon;

-- === Staff roster read ===
-- The return type gains a column, so CREATE OR REPLACE cannot do it
-- (42P13) -- the function must be dropped first. Same constraint that
-- forced the DROP in 037 and 039.
drop function if exists get_church_staff_detail(uuid);

create or replace function get_church_staff_detail(target_church_id uuid)
returns table (
  staff_id uuid,
  user_id uuid,
  full_name text,
  can_manage_events boolean,
  can_manage_giving boolean,
  can_edit_profile boolean,
  can_manage_groups boolean,
  can_manage_messages boolean,
  is_manager boolean,
  receives_contact_messages boolean,
  can_manage_members boolean,
  can_check_in boolean
)
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not (
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or is_church_staff_member(target_church_id)
  ) then
    raise exception 'Not authorized to view staff for this church.';
  end if;

  return query
    select cs.id, cs.user_id, p.full_name,
      cs.can_manage_events, cs.can_manage_giving, cs.can_edit_profile,
      cs.can_manage_groups, cs.can_manage_messages, cs.is_manager,
      cs.receives_contact_messages, cs.can_manage_members, cs.can_check_in
    from church_staff cs
    left join profiles p on p.id = cs.user_id
    where cs.church_id = target_church_id;
end;
$fn$;

-- === Granting the ability ===
-- One more parameter means a new signature, so the previous 10-argument
-- overload has to go or PostgREST cannot choose between them. Exactly
-- the hazard 035 called out when it added can_manage_members, and the
-- one that broke search_events in 022.
drop function if exists update_staff_abilities(
  uuid, uuid, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean
);

create or replace function update_staff_abilities(
  target_staff_id uuid,
  target_church_id uuid,
  p_can_manage_events boolean,
  p_can_manage_giving boolean,
  p_can_edit_profile boolean,
  p_can_manage_groups boolean,
  p_can_manage_messages boolean,
  p_is_manager boolean,
  p_receives_contact_messages boolean,
  p_can_manage_members boolean,
  p_can_check_in boolean
) returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_is_owner boolean;
  v_is_manager boolean;
  v_target_is_manager boolean;
  v_tier_allows_manager boolean;
begin
  select exists(select 1 from churches where id = target_church_id and owner_id = auth.uid()) into v_is_owner;
  v_is_manager := is_church_manager(target_church_id);

  if not v_is_owner and not v_is_manager then
    raise exception 'Not authorized to manage staff for this church.';
  end if;

  select is_manager into v_target_is_manager
    from church_staff where id = target_staff_id and church_id = target_church_id;
  if v_target_is_manager is null then
    raise exception 'Staff member not found.';
  end if;

  if not v_is_owner then
    if v_target_is_manager then
      raise exception 'Only the church owner can edit another Manager''s abilities.';
    end if;
    if p_is_manager then
      raise exception 'Only the church owner can grant the Manager role.';
    end if;
  end if;

  if p_is_manager and not v_target_is_manager then
    select pt.can_assign_manager into v_tier_allows_manager
      from churches c join plan_tiers pt on pt.plan_type = c.plan_type
      where c.id = target_church_id;
    if not coalesce(v_tier_allows_manager, false) then
      raise exception 'This church''s plan does not include the Manager role.';
    end if;
  end if;

  update church_staff set
    can_manage_events = p_can_manage_events,
    can_manage_giving = p_can_manage_giving,
    can_edit_profile = p_can_edit_profile,
    can_manage_groups = p_can_manage_groups,
    can_manage_messages = p_can_manage_messages,
    is_manager = p_is_manager,
    receives_contact_messages = p_receives_contact_messages,
    can_manage_members = p_can_manage_members,
    can_check_in = p_can_check_in
  where id = target_staff_id and church_id = target_church_id;

  return found;
end;
$fn$;

-- === Carrying it through an invite ===
-- Body unchanged from 035 apart from the new column in the insert and
-- in the conflict update.
create or replace function accept_staff_invite(invite_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_invite church_staff_invites%rowtype;
  v_user_email text;
  v_tier_allows_manager boolean;
  v_final_is_manager boolean;
begin
  select email into v_user_email from auth.users where id = auth.uid();
  if v_user_email is null then
    raise exception 'Not authenticated.';
  end if;

  select * into v_invite from church_staff_invites where id = invite_id and status = 'pending';
  if not found then
    raise exception 'This invite is no longer available.';
  end if;
  if lower(v_invite.email) <> lower(v_user_email) then
    raise exception 'This invite was not addressed to you.';
  end if;

  v_final_is_manager := v_invite.is_manager;
  if v_final_is_manager then
    select pt.can_assign_manager into v_tier_allows_manager
      from churches c join plan_tiers pt on pt.plan_type = c.plan_type
      where c.id = v_invite.church_id;
    if not coalesce(v_tier_allows_manager, false) then
      v_final_is_manager := false;
    end if;
  end if;

  insert into church_staff (
    church_id, user_id, invited_by,
    can_manage_events, can_manage_giving, can_manage_groups, can_manage_messages, can_edit_profile, is_manager,
    receives_contact_messages, can_manage_members, can_check_in
  ) values (
    v_invite.church_id, auth.uid(), v_invite.invited_by,
    v_invite.can_manage_events, v_invite.can_manage_giving, v_invite.can_manage_groups, v_invite.can_manage_messages, v_invite.can_edit_profile, v_final_is_manager,
    v_invite.receives_contact_messages, v_invite.can_manage_members, v_invite.can_check_in
  )
  on conflict (church_id, user_id) do update set
    can_manage_events = excluded.can_manage_events,
    can_manage_giving = excluded.can_manage_giving,
    can_manage_groups = excluded.can_manage_groups,
    can_manage_messages = excluded.can_manage_messages,
    can_edit_profile = excluded.can_edit_profile,
    is_manager = excluded.is_manager,
    receives_contact_messages = excluded.receives_contact_messages,
    can_manage_members = excluded.can_manage_members,
    can_check_in = excluded.can_check_in;

  update church_staff_invites set status = 'accepted', responded_at = now() where id = invite_id;
  return true;
end;
$fn$;

notify pgrst, 'reload schema';

-- Confirm exactly one overload of each survives, or PGRST203 is coming:
-- select oid::regprocedure from pg_proc
-- where proname in ('update_staff_abilities','get_church_staff_detail','set_registration_checked_in');
