-- Run in Supabase SQL Editor. Requires migrations 035, 045 and 046.
--
-- Three abilities for the pages Phase 1b created:
--
--   can_manage_rooms       -- the Facility page
--   can_manage_ministries  -- the Ministries page
--   can_view_revenue       -- the Revenue page
--
-- Until now those two new pages were visible to any staff member
-- regardless of ability, which made the reorganisation tidier without
-- making it correct. This is the part that makes it correct.
--
-- === can_view_revenue is a different KIND of flag ===
-- Every other ability here grants the power to CHANGE something.
-- can_view_revenue grants the power to SEE money. It is listed with
-- them because that is where a permissions UI has to put it, but the
-- client deliberately treats can_manage_giving as implying it: someone
-- who can process giving but cannot see the totals is an incoherent
-- state, and nobody setting up a treasurer would think to tick both.
-- Implication is done in the UI rather than by copying the value here,
-- so the two remain independently revocable in the database.
--
-- Defaults to false, and unlike can_check_in that is safe: these gate
-- pages that did not exist a day ago, so nobody is relying on access
-- that is about to disappear. The one exception is deliberate -- the
-- backfill below.

alter table church_staff add column if not exists can_manage_rooms boolean not null default false;
alter table church_staff add column if not exists can_manage_ministries boolean not null default false;
alter table church_staff add column if not exists can_view_revenue boolean not null default false;

alter table church_staff_invites add column if not exists can_manage_rooms boolean not null default false;
alter table church_staff_invites add column if not exists can_manage_ministries boolean not null default false;
alter table church_staff_invites add column if not exists can_view_revenue boolean not null default false;

-- Rooms and ministries used to live inside Settings, where the only
-- thing standing between a staff member and them was reaching the tab.
-- Anyone who can manage events was already editing them in practice --
-- events are what rooms and ministries are FOR -- so defaulting those
-- people to false would take away access they already had and use.
-- New staff still start at false; this is a one-off backfill of the
-- status quo, not a rule.
update church_staff
   set can_manage_rooms = true, can_manage_ministries = true
 where coalesce(can_manage_events, false) = true;

-- === Staff roster read ===
-- Return type gains three columns, so the function must be dropped
-- first (42P13). Same constraint as 037, 039 and 045.
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
  can_check_in boolean,
  can_manage_rooms boolean,
  can_manage_ministries boolean,
  can_view_revenue boolean
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
      cs.receives_contact_messages, cs.can_manage_members, cs.can_check_in,
      cs.can_manage_rooms, cs.can_manage_ministries, cs.can_view_revenue
    from church_staff cs
    left join profiles p on p.id = cs.user_id
    where cs.church_id = target_church_id;
end;
$fn$;

-- === Granting the abilities ===
-- Three more parameters means a new signature, so the 11-argument
-- version has to go or PostgREST cannot choose between them.
drop function if exists update_staff_abilities(
  uuid, uuid, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean
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
  p_can_check_in boolean,
  p_can_manage_rooms boolean,
  p_can_manage_ministries boolean,
  p_can_view_revenue boolean
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
    can_check_in = p_can_check_in,
    can_manage_rooms = p_can_manage_rooms,
    can_manage_ministries = p_can_manage_ministries,
    can_view_revenue = p_can_view_revenue
  where id = target_staff_id and church_id = target_church_id;

  return found;
end;
$fn$;

-- === Carrying them through an invite ===
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
    receives_contact_messages, can_manage_members, can_check_in,
    can_manage_rooms, can_manage_ministries, can_view_revenue
  ) values (
    v_invite.church_id, auth.uid(), v_invite.invited_by,
    v_invite.can_manage_events, v_invite.can_manage_giving, v_invite.can_manage_groups, v_invite.can_manage_messages, v_invite.can_edit_profile, v_final_is_manager,
    v_invite.receives_contact_messages, v_invite.can_manage_members, v_invite.can_check_in,
    v_invite.can_manage_rooms, v_invite.can_manage_ministries, v_invite.can_view_revenue
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
    can_check_in = excluded.can_check_in,
    can_manage_rooms = excluded.can_manage_rooms,
    can_manage_ministries = excluded.can_manage_ministries,
    can_view_revenue = excluded.can_view_revenue;

  update church_staff_invites set status = 'accepted', responded_at = now() where id = invite_id;
  return true;
end;
$fn$;

notify pgrst, 'reload schema';

-- Confirm exactly one overload of each survives:
-- select oid::regprocedure from pg_proc
-- where proname in ('update_staff_abilities','get_church_staff_detail');
