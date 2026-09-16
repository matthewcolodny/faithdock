-- Run in Supabase SQL Editor.
--
-- Adds owner-togglable Give/Message controls per church, requested
-- directly along with "remove message and give from all unclaimed
-- churches": unclaimed churches never show either (enforced client-side
-- in populateChurchPage(), same as the existing unclaimed banner), and
-- once claimed, the owner can additionally switch each off entirely from
-- Settings. Messaging also gets a recipient list -- the owner (togglable
-- for themselves) plus any staff member specifically granted the new
-- receives_contact_messages ability, following the exact same grantable-
-- ability pattern migration 029 already established for
-- can_manage_events/giving/groups/messages/is_manager (invite-time
-- checkbox, editable afterward via update_staff_abilities(), mirrored on
-- church_staff_invites, surfaced in get_church_staff_detail()).
--
-- Naming note: "receives_contact_messages" (not "can_manage_messages",
-- which already exists) -- can_manage_messages gates the *outbound*
-- Messages/announcements dashboard feature (composing and sending to
-- members). This is a different, *inbound* concept: whether this staffer
-- gets a copy of messages visitors submit through the public "Message"
-- button on the church's own page. Conflating the two would have meant
-- every staffer already trusted to send announcements automatically
-- starting to receive every visitor contact-form submission too, whether
-- or not that's actually who should be fielding those.

-- === churches: per-church Give/Message master switches ===

alter table churches add column if not exists giving_enabled boolean not null default true;
alter table churches add column if not exists messaging_enabled boolean not null default true;
-- Whether the OWNER personally receives contact-form messages -- separate
-- from messaging_enabled (the master on/off for the feature as a whole).
-- An owner who'd rather hand this off entirely to specific staff can turn
-- this off without disabling messaging church-wide.
alter table churches add column if not exists owner_receives_messages boolean not null default true;

-- ADDED after actually running this migration and hitting a real, live
-- "permission denied for table churches" (42501) trying to read the new
-- columns as anon -- churches uses COLUMN-level SELECT grants for anon/
-- authenticated, not a blanket table-level one (confirmed by checking
-- migrations 018_church_is_hidden.sql and 023_denomination_tags.sql,
-- which both explicitly grant their own new column the same way; a
-- table-level grant would have covered these new columns automatically,
-- a column-level one does not). Missed entirely the first time this
-- migration was written -- every ALTER TABLE ADD COLUMN on churches
-- needs its own matching grant, confirmed as the actual, established
-- pattern here, not assumed. giving_enabled/messaging_enabled go to
-- both anon and authenticated -- they gate a public church page's
-- Message/Give buttons for any visitor, signed in or not. UPDATE isn't
-- separately granted here, matching 023's own precedent -- churches
-- already has a working blanket UPDATE grant to authenticated (the
-- existing owner-only RLS policy is what actually restricts WHICH rows
-- get updated, not a column-level grant).
grant select (giving_enabled) on churches to anon, authenticated;
grant select (messaging_enabled) on churches to anon, authenticated;
-- authenticated only, deliberately -- this one is never meant to be
-- publicly readable (same reasoning PUBLIC_CHURCH_COLUMNS in index.html
-- already excludes it for), only needed by the owner's own Settings
-- page fetch and by the Edge Function (which uses the service-role key
-- and bypasses grants/RLS entirely, so doesn't need this either way).
grant select (owner_receives_messages) on churches to authenticated;

-- === church_staff / church_staff_invites: new grantable ability ===

alter table church_staff add column if not exists receives_contact_messages boolean not null default false;
alter table church_staff_invites add column if not exists receives_contact_messages boolean not null default false;

-- === get_church_staff_detail(): surface the new ability ===
-- Same function migration 029 created. CORRECTED after actually running
-- this migration and hitting it for real: unlike search_churches/
-- search_events's PARAMETER-list hazard (migrations 023/031, fixed there
-- with the same drop-then-create), this is a RETURN-type hazard --
-- Postgres refuses to CREATE OR REPLACE a `returns table(...)` function
-- with a different OUT-parameter row type at all, even just appending a
-- column, full stop (42P13: "cannot change return type of existing
-- function... Use DROP FUNCTION get_church_staff_detail(uuid) first").
-- The comment that used to be here claimed appending columns was safe --
-- it wasn't, confirmed by the actual error, not assumed the second time.
-- Also explains why NONE of this migration's earlier statements (the
-- churches/church_staff alter table adds) appeared to take effect either
-- when first run: the SQL Editor runs a pasted script as one transaction,
-- so this error rolled back everything before it too, not just this
-- function.

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
  receives_contact_messages boolean
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
      cs.receives_contact_messages
    from church_staff cs
    left join profiles p on p.id = cs.user_id
    where cs.church_id = target_church_id;
end;
$$;

-- === accept_staff_invite(): carry the new ability through on accept ===
-- Same function migration 030_staff_invites_require_acceptance.sql
-- created -- it copies church_staff_invites' ability columns onto the
-- real church_staff row the moment someone accepts. Without adding
-- receives_contact_messages here too, checking that box on the invite
-- form would silently do nothing: the invite row would carry it
-- correctly (inviteStaffToOneChurch() already writes it), but it would
-- never make it onto the real church_staff row once accepted.
-- Signature (invite_id uuid) is unchanged, so a plain CREATE OR REPLACE
-- is safe here -- no drop-then-create needed.

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
    receives_contact_messages
  ) values (
    v_invite.church_id, auth.uid(), v_invite.invited_by,
    v_invite.can_manage_events, v_invite.can_manage_giving, v_invite.can_manage_groups, v_invite.can_manage_messages, v_invite.can_edit_profile, v_final_is_manager,
    v_invite.receives_contact_messages
  )
  on conflict (church_id, user_id) do update set
    can_manage_events = excluded.can_manage_events,
    can_manage_giving = excluded.can_manage_giving,
    can_manage_groups = excluded.can_manage_groups,
    can_manage_messages = excluded.can_manage_messages,
    can_edit_profile = excluded.can_edit_profile,
    is_manager = excluded.is_manager,
    receives_contact_messages = excluded.receives_contact_messages;

  update church_staff_invites set status = 'accepted', responded_at = now() where id = invite_id;
  return true;
end;
$$;

-- === update_staff_abilities(): accept/set the new ability ===
-- New parameter appended at the end with no default -- this changes the
-- function's signature, so (same hazard as search_churches/search_events
-- in migrations 023/031) the OLD 8-argument overload has to be dropped
-- explicitly or PostgREST's RPC call becomes ambiguous between the two.

drop function if exists update_staff_abilities(
  uuid, uuid, boolean, boolean, boolean, boolean, boolean, boolean
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
  p_receives_contact_messages boolean
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
    receives_contact_messages = p_receives_contact_messages
  where id = target_staff_id and church_id = target_church_id;

  return found;
end;
$$;

notify pgrst, 'reload schema';
