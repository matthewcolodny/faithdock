-- Run in Supabase SQL Editor.
--
-- Church-home membership becomes something a church approves rather
-- than something anyone can grant themselves. Requested directly, as
-- "the prime way that churches can secure their membership and control
-- registration so it's constrained to approved members."
--
-- Today, clicking "Make this my Church Home" upserts a church_memberships
-- row instantly and that person is a member, full stop. A church can see
-- who joined and remove them after the fact (the Recently Joined panel),
-- but has no say before. This adds the missing step: request -> approve
-- or reject, plus a staff ability for who may decide.
--
-- WHAT EXISTS ALREADY, and is reused rather than rebuilt:
--   * church_memberships (user_id, church_id, is_permanent, joined_at,
--     flagged_at), unique on (user_id, church_id). is_permanent = true
--     is what "church home" means everywhere in the app.
--   * church_member_invites (church_id, email) plus a whole email-invite
--     flow and an accept prompt. An invited person is one the church has
--     ALREADY vouched for, so accepting an invite must not land them in
--     a review queue -- handled in the trigger below.
-- Neither table's original definition is in this repo (both predate
-- migration tracking, same gap as churches/event_registrations), so
-- everything here is additive and makes no assumption about what
-- policies already exist on them.

-- === Approval state ===
-- Default 'pending' so anything created from here on must be decided on.
-- The backfill immediately after is what grandfathers everyone who is
-- already a member: at the moment this migration runs, every existing
-- row is by definition pre-existing, so a blanket update is exactly the
-- "leave current members alone" behaviour that was asked for. Adding the
-- column first and updating second (rather than defaulting to 'approved'
-- and trying to be clever) keeps that explicit and readable.

alter table church_memberships add column if not exists status text not null default 'pending';

update church_memberships set status = 'approved' where status <> 'approved';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'church_memberships_status_check'
  ) then
    alter table church_memberships
      add constraint church_memberships_status_check
      check (status in ('pending', 'approved', 'rejected'));
  end if;
end;
$$;

create index if not exists church_memberships_church_status_idx
  on church_memberships (church_id, status);

-- === Who may decide ===
-- New grantable staff ability, following the exact pattern migrations
-- 029 and 032 established (invite-time checkbox, editable afterward via
-- update_staff_abilities, mirrored on church_staff_invites, surfaced in
-- get_church_staff_detail). Deliberately its own ability rather than
-- reusing is_manager: deciding who counts as a member of the
-- congregation is a different kind of trust than managing staff, and a
-- church may well want a membership secretary who is not a manager.

alter table church_staff add column if not exists can_manage_members boolean not null default false;
alter table church_staff_invites add column if not exists can_manage_members boolean not null default false;

-- Owner always qualifies; staff need the specific ability. Same shape
-- and same SECURITY DEFINER reasoning as can_manage_church_messages in
-- migration 029 -- it is used inside a trigger and inside RPCs, where an
-- invoker-rights function's own read of church_staff would itself be
-- subject to RLS and could silently evaluate false for the very people
-- it is meant to authorize.
create or replace function can_manage_church_members(target_church_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or exists (
      select 1 from church_staff
      where church_id = target_church_id
      and user_id = auth.uid()
      and can_manage_members = true
    );
$$;

-- === Enforcement ===
-- A trigger, NOT an RLS policy, and that choice is the important part.
-- This table's existing policies aren't visible from this repo, and
-- permissive policies OR together -- so if some existing policy already
-- lets a person update their own membership row, adding a stricter
-- policy here would not take that away, and anyone could simply set
-- their own status to 'approved' and self-approve. A BEFORE trigger runs
-- for every statement regardless of which policy allowed it, so it can
-- actually hold the line. RLS decides which rows you may touch; this
-- decides what you may turn them into.
create or replace function enforce_church_membership_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_can_manage boolean;
  v_user_email text;
  v_has_invite boolean;
begin
  -- Service-role / backend callers (edge functions) have no auth.uid()
  -- and are already trusted; leave whatever they set alone rather than
  -- forcing their writes into 'pending'.
  if auth.uid() is null then
    return new;
  end if;

  v_actor_can_manage := can_manage_church_members(new.church_id);

  if tg_op = 'INSERT' then
    -- The church adding someone directly is itself the approval, so an
    -- authorized actor's explicit value is taken at face value.
    if v_actor_can_manage then
      return new;
    end if;

    -- Someone joining on their own account. Already-invited people skip
    -- the queue: the church went out of its way to ask them, so making
    -- them wait for a second approval would be nonsense. Matched on
    -- email because that is all an invite has to go on before signup --
    -- the same basis the existing accept-invite prompt uses.
    select email into v_user_email from auth.users where id = auth.uid();
    select exists (
      select 1 from church_member_invites cmi
      where cmi.church_id = new.church_id
        and lower(cmi.email) = lower(coalesce(v_user_email, ''))
    ) into v_has_invite;

    new.status := case when v_has_invite then 'approved' else 'pending' end;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    -- Everything else about your own membership row stays yours to
    -- change (unsetting is_permanent to drop your church home, for
    -- instance). Only the approval decision is reserved.
    if new.status is distinct from old.status and not v_actor_can_manage then
      -- One deliberate exception: asking again after being turned down.
      -- The row already exists, so a fresh request arrives as an UPDATE,
      -- not an INSERT -- without this it would be silently ignored (the
      -- upsert would touch no status, leave 'rejected' in place, and the
      -- person would click "Request to join" forever with nothing
      -- happening and no error). Only rejected -> pending is allowed;
      -- nothing here can move a row toward 'approved'.
      if old.status = 'rejected' and new.status = 'pending' then
        return new;
      end if;
      raise exception 'Only the church can change a membership''s approval status.';
    end if;
    return new;
  end if;

  return new;
end;
$$;

drop trigger if exists church_memberships_enforce_status on church_memberships;
create trigger church_memberships_enforce_status
  before insert or update on church_memberships
  for each row execute function enforce_church_membership_status();

-- === Church-side reads and decisions ===

-- Pending first, then most recent -- a review queue should open on the
-- thing that needs deciding. Email is included because a church often
-- recognises the address when the display name means nothing to them;
-- the same church already sees member emails in its Directory panel, so
-- this exposes nothing new.
create or replace function get_church_membership_requests(target_church_id uuid)
returns table (
  user_id uuid,
  full_name text,
  email text,
  status text,
  is_permanent boolean,
  joined_at timestamptz,
  flagged_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not can_manage_church_members(target_church_id) then
    raise exception 'Not authorized to manage members for this church.';
  end if;

  return query
    select cm.user_id, p.full_name, u.email::text, cm.status,
      cm.is_permanent, cm.joined_at, cm.flagged_at
    from church_memberships cm
    left join profiles p on p.id = cm.user_id
    left join auth.users u on u.id = cm.user_id
    where cm.church_id = target_church_id
    order by (cm.status = 'pending') desc, cm.joined_at desc;
end;
$$;

create or replace function set_church_membership_status(
  target_church_id uuid,
  target_user_id uuid,
  new_status text
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not can_manage_church_members(target_church_id) then
    raise exception 'Not authorized to manage members for this church.';
  end if;
  if new_status not in ('pending', 'approved', 'rejected') then
    raise exception 'Invalid membership status.';
  end if;

  update church_memberships
    set status = new_status
    where church_id = target_church_id and user_id = target_user_id;

  return found;
end;
$$;

-- Removing a member is a separate verb from rejecting one: reject leaves
-- a decided row behind (so a repeat request is visibly a repeat), remove
-- deletes it outright as though they had never asked. The existing
-- Recently Joined panel deletes directly from the client, which depends
-- on an RLS policy this repo can't see -- exactly the shape of silent
-- zero-row failure that made unregistering look like it worked for weeks
-- (migration 033). Going through an RPC means authorization is explicit
-- and the caller gets a real answer either way.
create or replace function remove_church_member(
  target_church_id uuid,
  target_user_id uuid
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not can_manage_church_members(target_church_id) then
    raise exception 'Not authorized to manage members for this church.';
  end if;

  delete from church_memberships
    where church_id = target_church_id and user_id = target_user_id;

  return found;
end;
$$;

-- === Staff plumbing for the new ability ===
-- get_church_staff_detail gains a column, which means its OUT-parameter
-- row type changes -- CREATE OR REPLACE cannot do that (42P13), it has
-- to be dropped first. Learned the hard way in migration 032; not
-- repeated here.

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
  can_manage_members boolean
)
language plpgsql
security definer
set search_path = public
as $$
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
      cs.receives_contact_messages, cs.can_manage_members
    from church_staff cs
    left join profiles p on p.id = cs.user_id
    where cs.church_id = target_church_id;
end;
$$;

-- Signature unchanged, so a plain CREATE OR REPLACE is safe here.
create or replace function accept_staff_invite(invite_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
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
    receives_contact_messages, can_manage_members
  ) values (
    v_invite.church_id, auth.uid(), v_invite.invited_by,
    v_invite.can_manage_events, v_invite.can_manage_giving, v_invite.can_manage_groups, v_invite.can_manage_messages, v_invite.can_edit_profile, v_final_is_manager,
    v_invite.receives_contact_messages, v_invite.can_manage_members
  )
  on conflict (church_id, user_id) do update set
    can_manage_events = excluded.can_manage_events,
    can_manage_giving = excluded.can_manage_giving,
    can_manage_groups = excluded.can_manage_groups,
    can_manage_messages = excluded.can_manage_messages,
    can_edit_profile = excluded.can_edit_profile,
    is_manager = excluded.is_manager,
    receives_contact_messages = excluded.receives_contact_messages,
    can_manage_members = excluded.can_manage_members;

  update church_staff_invites set status = 'accepted', responded_at = now() where id = invite_id;
  return true;
end;
$$;

-- One more parameter means a new signature, so the previous 9-argument
-- overload has to go or PostgREST can't choose between them. Same hazard
-- as migrations 023/031/032 -- and exactly what broke search_events for
-- the homepage and church Events tabs when it was missed in 022.

drop function if exists update_staff_abilities(
  uuid, uuid, boolean, boolean, boolean, boolean, boolean, boolean, boolean
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
  p_can_manage_members boolean
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
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
    can_manage_members = p_can_manage_members
  where id = target_staff_id and church_id = target_church_id;

  return found;
end;
$$;

notify pgrst, 'reload schema';
