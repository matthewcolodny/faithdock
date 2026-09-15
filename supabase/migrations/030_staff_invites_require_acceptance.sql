-- Run in Supabase SQL Editor.
--
-- Staff invites now always require an explicit Accept -- an owner (or
-- Manager, see migration 029) picks the invitee's abilities via a
-- checklist UP FRONT, at invite time, not retroactively after they're
-- already on the team. Previously, inviting someone who already had a
-- FaithDock account added them to church_staff instantly with no
-- abilities set and no acceptance step at all; only a not-yet-registered
-- invitee went through church_staff_invites. Both cases now go through
-- the exact same pending-invite-then-accept path.
--
-- Mirrors this repo's existing accept_church_ownership_handoff /
-- decline_church_ownership_handoff pattern (see checkPendingOwnershipHandoff
-- in index.html) rather than inventing a new one: a security-definer RPC
-- is required here, not a plain client-side insert the way
-- church_member_invites' accept works, because creating a church_staff
-- row is a privileged action the invitee has no RLS rights to perform on
-- their own.
--
-- KNOWN RISK, flagged rather than silently assumed away: earlier
-- GOTCHAS.md entries describe an existing, untracked database trigger
-- that auto-accepts a pending church_staff_invites row the instant
-- someone signs up with a matching email -- its source has never been
-- visible from this environment, so it is NOT touched, altered, or
-- assumed-safe here. If that trigger is still active, a brand-new
-- signup could get a bare church_staff row (default/false abilities,
-- no invited_by) from that trigger before ever seeing the new
-- Accept/Decline prompt this migration adds -- silently ignoring
-- whatever abilities the inviter actually selected.
-- accept_staff_invite() below is written defensively against exactly
-- that: it UPSERTs on (church_id, user_id) rather than a plain insert
-- (matching the existing 23505-unique-violation handling already in
-- index.html's inviteStaffToOneChurch, which implies that's the real
-- constraint), so calling it still applies the invite's actual selected
-- abilities even if a bare row already exists. Recommend checking the
-- Supabase dashboard's Database > Triggers for anything referencing
-- church_staff_invites and disabling it, so a brand-new signup goes
-- through the same explicit-accept flow as everyone else rather than
-- being silently added with no abilities by a trigger this migration
-- can't see.

-- === church_staff_invites: same ability shape as church_staff itself ===
-- (can_manage_billing deliberately excluded -- migration 029 made
-- billing owner-only with no exceptions; there is nothing to select here.)

alter table church_staff_invites add column if not exists can_manage_events boolean not null default false;
alter table church_staff_invites add column if not exists can_manage_giving boolean not null default false;
alter table church_staff_invites add column if not exists can_manage_groups boolean not null default false;
alter table church_staff_invites add column if not exists can_manage_messages boolean not null default false;
alter table church_staff_invites add column if not exists can_edit_profile boolean not null default false;
alter table church_staff_invites add column if not exists is_manager boolean not null default false;
alter table church_staff_invites add column if not exists responded_at timestamptz;

-- Invitee needs to be able to see invites addressed to their own email
-- to know they have something to accept. This policy didn't need to
-- exist before now -- only the inviting owner/Manager ever queried this
-- table client-side, always scoped to their own church_id, already
-- covered by whatever owner/Manager policy exists on it.
drop policy if exists "Invitee can view their own pending staff invites" on church_staff_invites;
create policy "Invitee can view their own pending staff invites"
  on church_staff_invites for select
  to authenticated
  using (lower(email) = lower(coalesce(auth.jwt()->>'email', '')));

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

  -- Re-check tier gating at accept time, not just invite time -- the
  -- church's plan may have changed in between. Same rule as
  -- update_staff_abilities() (migration 029): degrade to non-Manager
  -- rather than block the whole invite over just this one flag.
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
    can_manage_events, can_manage_giving, can_manage_groups, can_manage_messages, can_edit_profile, is_manager
  ) values (
    v_invite.church_id, auth.uid(), v_invite.invited_by,
    v_invite.can_manage_events, v_invite.can_manage_giving, v_invite.can_manage_groups, v_invite.can_manage_messages, v_invite.can_edit_profile, v_final_is_manager
  )
  on conflict (church_id, user_id) do update set
    can_manage_events = excluded.can_manage_events,
    can_manage_giving = excluded.can_manage_giving,
    can_manage_groups = excluded.can_manage_groups,
    can_manage_messages = excluded.can_manage_messages,
    can_edit_profile = excluded.can_edit_profile,
    is_manager = excluded.is_manager;

  update church_staff_invites set status = 'accepted', responded_at = now() where id = invite_id;
  return true;
end;
$$;

create or replace function decline_staff_invite(invite_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite church_staff_invites%rowtype;
  v_user_email text;
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

  update church_staff_invites set status = 'declined', responded_at = now() where id = invite_id;
  return true;
end;
$$;

notify pgrst, 'reload schema';
