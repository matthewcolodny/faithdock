-- Run in the Supabase SQL Editor.
--
-- Records when somebody stops being a member, so "joins and leaves over
-- time" has a second line to draw.
--
-- WHY THERE IS NOTHING TO CHART TODAY. Removing a member deletes the
-- church_memberships row (migration 035's remove_church_member), and
-- dropping your own church home just unsets is_permanent. Either way
-- the fact of leaving is not written down anywhere -- the row simply
-- stops describing a member. The Directory's joins chart says so
-- rather than drawing a flat zero line, which would read as "nobody
-- has ever left".
--
-- THIS ONLY WORKS GOING FORWARD. Nothing can reconstruct past
-- departures; the evidence was deleted. Every month before this
-- migration ran has no leaves data, and that is different from having
-- zero leaves. The client is told when logging started
-- (departures_logging_started_at below) so it can draw the line from
-- there instead of from the beginning of the chart.
--
-- WHAT COUNTS AS LEAVING. Somebody who WAS a member -- is_permanent and
-- status 'approved', the same definition used everywhere else -- and is
-- no longer, whether that happened by:
--
--   * the row being deleted            -> the church removed them, or
--                                         they were cascaded away
--   * is_permanent going false         -> they dropped their church home
--   * status leaving 'approved'        -> the church revoked it
--
-- A pending request that is rejected is NOT a departure. They were
-- never a member, and counting it would turn an unanswered enquiry into
-- someone the church lost.
--
-- 'left' vs 'removed' is decided by who did it: if auth.uid() is the
-- member themselves it is 'left', otherwise 'removed'. A cascade or a
-- backend job has no auth.uid() and records 'removed' with a null
-- actor, which is honest -- something happened to them rather than
-- something they did.

-- ---------------------------------------------------------------------
-- Preflight.
-- ---------------------------------------------------------------------
do $preflight$
declare
  missing text := '';
begin
  if not exists (select 1 from information_schema.tables
                 where table_schema='public' and table_name='church_memberships') then
    missing := missing || 'church_memberships ';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='church_memberships' and column_name='is_permanent') then
    missing := missing || 'church_memberships.is_permanent ';
  end if;
  if to_regprocedure('public.can_manage_church_members(uuid)') is null then
    missing := missing || 'can_manage_church_members(uuid) ';
  end if;
  if missing <> '' then
    raise exception 'VERIFY FAILED: missing %. Nothing was changed.', missing;
  end if;
  raise notice 'Preflight OK.';
end
$preflight$;

-- ---------------------------------------------------------------------
-- The log.
-- ---------------------------------------------------------------------
create table if not exists church_membership_departures (
  id         uuid primary key default gen_random_uuid(),
  church_id  uuid not null references churches(id) on delete cascade,
  -- ON DELETE CASCADE to auth.users on purpose. If somebody deletes
  -- their FaithDock account their departure record goes with it, which
  -- costs a church one row on a chart and is the right trade: this
  -- table exists for reporting, not for keeping a file on people who
  -- have left and then asked to be forgotten.
  user_id    uuid not null references auth.users(id) on delete cascade,
  left_at    timestamptz not null default now(),
  -- Carried across from the row being destroyed, because afterwards
  -- there is nothing left to compute tenure from.
  joined_at  timestamptz,
  kind       text not null check (kind in ('left', 'removed')),
  actor_id   uuid
);

create index if not exists idx_membership_departures_church_left
  on church_membership_departures (church_id, left_at desc);

alter table church_membership_departures enable row level security;

-- Read: whoever may manage that church's members. No insert, update or
-- delete policy at all -- rows arrive only through the trigger below,
-- which is SECURITY DEFINER. A log that its subjects can edit is not a
-- log.
drop policy if exists "Membership managers read their own departures" on church_membership_departures;
create policy "Membership managers read their own departures"
  on church_membership_departures for select
  using (can_manage_church_members(church_id));

grant select on church_membership_departures to authenticated;

-- ---------------------------------------------------------------------
-- The trigger.
-- ---------------------------------------------------------------------
create or replace function log_church_membership_departure()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_was_member boolean;
  v_is_member  boolean;
begin
  -- Every path returns null. This is an AFTER trigger, so the return
  -- value is discarded -- and coalesce(new, old) on record types is not
  -- something plpgsql reliably does, which would have turned a logging
  -- concern into a failed delete.
  v_was_member := coalesce(old.is_permanent, false) and old.status = 'approved';
  if not v_was_member then
    -- Never a member, so nothing was lost. A rejected request is not a
    -- departure.
    return null;
  end if;

  if tg_op = 'UPDATE' then
    v_is_member := coalesce(new.is_permanent, false) and new.status = 'approved';
    if v_is_member then
      return null;   -- still a member; nothing happened
    end if;
  end if;

  -- Wrapped so that a fault in the logging can never block the removal
  -- it is observing. Somebody asking to be taken off a church's list
  -- must not be held up by this table being full, locked, or wrong.
  begin
    insert into church_membership_departures (church_id, user_id, joined_at, kind, actor_id)
    values (
      old.church_id,
      old.user_id,
      old.joined_at,
      case when auth.uid() is not distinct from old.user_id then 'left' else 'removed' end,
      auth.uid()
    );
  exception when others then
    raise warning 'church_membership_departures insert failed for user % at church %: %',
      old.user_id, old.church_id, sqlerrm;
  end;

  return null;
end;
$fn$;

drop trigger if exists church_memberships_log_departure on church_memberships;
create trigger church_memberships_log_departure
  after delete or update on church_memberships
  for each row execute function log_church_membership_departure();

-- ---------------------------------------------------------------------
-- When logging started, so the client can draw the line from the right
-- month instead of showing zeros for months it knows nothing about.
-- ---------------------------------------------------------------------
-- A plain constant, not the table's creation time from the catalogue:
-- reading that needs pg_stat_file and superuser on some deployments,
-- which is a lot of dependency for one date. If this migration is ever
-- re-run the date must NOT move -- it marks when records began, and a
-- later date would silently blank months that do have data.
create or replace function departures_logging_started_at()
returns timestamptz
language sql
immutable
as $fn$
  select timestamptz '2026-09-24 00:00:00+00';
$fn$;

revoke all on function departures_logging_started_at() from public;
grant execute on function departures_logging_started_at() to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Verify.
-- ---------------------------------------------------------------------
do $verify$
begin
  if not exists (select 1 from pg_trigger
                 where tgname = 'church_memberships_log_departure' and not tgisinternal) then
    raise exception 'VERIFY FAILED: the trigger is not there.';
  end if;
  if not exists (select 1 from pg_policy p join pg_class c on c.oid = p.polrelid
                 where c.relname = 'church_membership_departures' and p.polcmd = 'r') then
    raise exception 'VERIFY FAILED: no SELECT policy on church_membership_departures.';
  end if;
  if exists (select 1 from pg_policy p join pg_class c on c.oid = p.polrelid
             where c.relname = 'church_membership_departures' and p.polcmd in ('a','w','d')) then
    raise exception 'VERIFY FAILED: there is a write policy on the log. Rows must only arrive via the trigger.';
  end if;
  if not (select relrowsecurity from pg_class where relname = 'church_membership_departures') then
    raise exception 'VERIFY FAILED: RLS is not enabled on church_membership_departures.';
  end if;
  raise notice 'OK.';
end
$verify$;

select
  (select relrowsecurity from pg_class where relname='church_membership_departures')   as rls_on,
  exists (select 1 from pg_trigger where tgname='church_memberships_log_departure'
            and not tgisinternal)                                                       as trigger_present,
  (select count(*) from pg_policy p join pg_class c on c.oid=p.polrelid
    where c.relname='church_membership_departures')::text                               as policies_on_log,
  has_table_privilege('authenticated','church_membership_departures','SELECT')          as authenticated_can_read,
  has_table_privilege('anon','church_membership_departures','SELECT')                   as anon_can_read,
  departures_logging_started_at()::date::text                                           as logging_starts;
