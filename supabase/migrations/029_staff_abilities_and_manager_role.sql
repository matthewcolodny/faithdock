-- Run in Supabase SQL Editor.
--
-- Reworks church_staff's permission model per the account-owner/staff/
-- manager design: billing and church deletion become owner-only with no
-- exceptions (removing the can_manage_billing ability entirely, and
-- adding an explicit owner-only DELETE policy on churches that no
-- existing migration ever defined); two new grantable abilities
-- (can_manage_groups, can_manage_messages); and a new is_manager ability,
-- gated to standard/premium/multi_church tiers, that lets a staff member
-- invite/remove OTHER (non-manager) staff and edit their non-Manager
-- abilities -- but never grant/edit the Manager role itself, and never
-- touch billing or church deletion. Only the owner can do those.
--
-- Renumbered 028 -> 029: 028 is already taken in this repo by
-- message_delivery_tracking.sql. That migration (not 027, despite what
-- an earlier disconnected draft of this prompt assumed) is what actually
-- created message_batches/message_log and their RLS policies -- confirmed
-- by grepping supabase/migrations/*.sql before writing this file. The
-- DROP POLICY names below match what 028_message_delivery_tracking.sql
-- actually created, verified the same way.
--
-- SCOPE NOTE: can_manage_groups is added as a real, grantable, visible
-- ability (shows in the staff profile UI, stored and readable) but this
-- migration does NOT touch any RLS on groups/group_members tables --
-- that schema hasn't been reviewed yet this pass. Wiring real group-CRUD
-- enforcement to this flag is follow-up work, not done here.
-- can_manage_events and can_manage_giving are untouched -- their existing
-- enforcement (wherever it lives) is not modified by this migration.

-- === church_staff ability columns ===

alter table church_staff add column if not exists can_manage_groups boolean not null default false;
alter table church_staff add column if not exists can_manage_messages boolean not null default false;
alter table church_staff add column if not exists is_manager boolean not null default false;

-- Breaking, deliberate: billing becomes owner-only with no exceptions.
-- Any staff row that currently has can_manage_billing = true loses that
-- ability the moment this runs -- there is no replacement flag, this is
-- an intentional lockdown per the new design, not an oversight.
alter table church_staff drop column if exists can_manage_billing;

-- === plan_tiers: which tiers can have a Manager at all ===

alter table plan_tiers add column if not exists can_assign_manager boolean not null default false;
update plan_tiers set can_assign_manager = true where plan_type in ('standard', 'premium', 'multi_church');

-- === Helpers ===

-- Mirrors is_church_staff_member()'s existing shape/signature (see
-- GOTCHAS.md) but scoped to staff rows with is_manager = true.
--
-- SECURITY DEFINER is required here, not optional: this function is used
-- directly inside RLS policies below (not just nested inside the two
-- SECURITY DEFINER RPCs above). Called as a plain invoker-rights function,
-- its own internal SELECT against church_staff would itself be subject to
-- RLS for whichever role is currently evaluating it -- and there is no
-- policy that lets a manager see their own church_staff row (only the
-- owner's blanket policy and the manager policies below, none of which
-- are a plain self-select) -- so the check would silently and always
-- evaluate false for the very people it's supposed to authorize. Caught
-- by testing this against a real non-superuser role locally, not assumed.
create or replace function is_church_manager(target_church_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from church_staff
    where church_id = target_church_id
    and user_id = auth.uid()
    and is_manager = true
  );
$$;

-- Owner always has full messaging access; staff needs the specific
-- ability now, not just any staff membership (message_batches/
-- message_log's RLS below is tightened to use this instead of the
-- blanket is_church_staff_member() check it shipped with earlier).
-- SECURITY DEFINER for the same reason as is_church_manager above.
create or replace function can_manage_church_messages(target_church_id uuid)
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
      and can_manage_messages = true
    );
$$;

-- === Tighten message_batches / message_log RLS ===
-- (from migration 028_message_delivery_tracking.sql -- replaces the
-- blanket "any staff" check with the specific can_manage_messages
-- ability now that it exists)

drop policy if exists "Owner or staff can view their church's message batches" on message_batches;
create policy "Owner or staff-with-messages-ability can view message batches"
  on message_batches for select
  using (can_manage_church_messages(message_batches.church_id));

drop policy if exists "Owner or staff can view their church's message log" on message_log;
create policy "Owner or staff-with-messages-ability can view message log"
  on message_log for select
  using (can_manage_church_messages(message_log.church_id));

-- === Owner-only church deletion ===
-- No migration in this repo ever defined a DELETE policy for churches --
-- the existing owner "Delete this church" button in Settings has been
-- relying on something not visible here. Adding this explicitly so it's
-- verified, not assumed: owner only, no exceptions, matching the design.

drop policy if exists "Owner can delete their own church" on churches;
create policy "Owner can delete their own church"
  on churches for delete
  to authenticated
  using (owner_id = auth.uid());

-- === Manager can add/remove/update REGULAR (non-manager) staff ===
-- Additive policies -- these don't touch, replace, or need to know about
-- whatever owner-side policies already exist on these tables (not backed
-- up in this repo); Postgres RLS OR's permissive policies together, so
-- this only ever ADDS manager access, never narrows the owner's.

drop policy if exists "Manager can add regular staff" on church_staff;
create policy "Manager can add regular staff"
  on church_staff for insert
  to authenticated
  with check (is_church_manager(church_id) and is_manager = false);

drop policy if exists "Manager can update regular staff abilities" on church_staff;
create policy "Manager can update regular staff abilities"
  on church_staff for update
  to authenticated
  using (is_church_manager(church_id) and is_manager = false)
  with check (is_church_manager(church_id) and is_manager = false);

drop policy if exists "Manager can remove regular staff" on church_staff;
create policy "Manager can remove regular staff"
  on church_staff for delete
  to authenticated
  using (is_church_manager(church_id) and is_manager = false);

drop policy if exists "Manager can invite regular staff" on church_staff_invites;
create policy "Manager can invite regular staff"
  on church_staff_invites for insert
  to authenticated
  with check (is_church_manager(church_id));

drop policy if exists "Manager can cancel staff invites" on church_staff_invites;
create policy "Manager can cancel staff invites"
  on church_staff_invites for delete
  to authenticated
  using (is_church_manager(church_id));

-- === New RPCs (new names -- get_staff_with_permissions and
-- update_staff_permissions stay live and untouched; their source was
-- never available in this repo to safely edit in place, and their shape
-- doesn't fit the new ability set anyway) ===

-- Read: every staff row for a church, full ability flags. Callable by
-- the owner or ANY staff member of that church (not manager-only) --
-- matches today's get_staff_with_permissions being owner-callable only
-- from the client, but this one is written to also work for the
-- non-owner "see my team" read your existing client code already does
-- via a plain table select -- consolidating both into one RPC.
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
  is_manager boolean
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
      cs.can_manage_groups, cs.can_manage_messages, cs.is_manager
    from church_staff cs
    left join profiles p on p.id = cs.user_id
    where cs.church_id = target_church_id;
end;
$$;

-- Write: owner can edit anyone (including granting/revoking is_manager,
-- subject to the target church's tier allowing it). A Manager can edit
-- any REGULAR staff member's non-Manager abilities, but is blocked
-- outright from touching a row that is currently a Manager, and blocked
-- from setting is_manager = true on anyone -- both checked explicitly
-- here (not left to RLS alone) so the error message is clear about why.
create or replace function update_staff_abilities(
  target_staff_id uuid,
  target_church_id uuid,
  p_can_manage_events boolean,
  p_can_manage_giving boolean,
  p_can_edit_profile boolean,
  p_can_manage_groups boolean,
  p_can_manage_messages boolean,
  p_is_manager boolean
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
    is_manager = p_is_manager
  where id = target_staff_id and church_id = target_church_id;

  return found;
end;
$$;

notify pgrst, 'reload schema';
