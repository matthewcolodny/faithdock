-- Run in Supabase SQL Editor.
--
-- Makes two settings real that have been stored and ignored.
--
-- === What was wrong ===
-- 059 added churches.directory_visibility and
-- churches.members_see_contact_details, and v133 shipped the UI for
-- them. Nothing ever read either column. get_directory_people returned
-- rows only for the owner or staff and referenced neither, so "Staff
-- and approved members" changed nothing and the contact-details switch
-- did nothing at all. A church could pick the more private option and
-- believe they had restricted something.
--
-- The check that was skipped: grep for who READS a column, not just
-- who writes it. A settings page proves only that a value is stored.
--
-- === What this changes ===
--   * An approved, permanent member of the church can read the
--     directory -- but ONLY when that church set directory_visibility
--     to 'members'. Default stays 'staff', so no church's directory
--     opens as a result of running this.
--   * For that member, email and phone come back NULL unless the
--     church also set members_see_contact_details. Two decisions, as
--     059 intended: "members can see who is here" and "members can see
--     how to reach each other" are not the same permission.
--   * Owner and staff are unaffected in both respects.
--
-- === Why the masking is server-side ===
-- Returning contact details and asking the page not to draw them would
-- leave them in the response body, one devtools panel away, for a
-- church that explicitly said no. The row that arrives has to be the
-- row the caller is allowed to have.
--
-- Same signature and same return type as the deployed version (see
-- supabase/db-functions/captured_2026-09-18.sql), so CREATE OR REPLACE
-- is valid here -- a changed return type would need a DROP first and
-- would break every caller in between.

create or replace function get_directory_people(target_church_id uuid)
returns table(user_id uuid, full_name text, email text, phone text, avatar_url text, is_member boolean, is_staff boolean, is_owner boolean, has_registered_event boolean)
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
    -- rejected request is not a member, and get_mass_email_recipients
    -- disagreeing about this is noted in db-functions/.
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
    ) as has_registered_event
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

-- CREATE OR REPLACE keeps existing grants, so these only assert what
-- should already be true. Postgres grants EXECUTE to PUBLIC by default
-- on a new function and this project separately grants to anon, so both
-- have to be revoked to mean anything -- see 054.
revoke all on function get_directory_people(uuid) from public;
revoke all on function get_directory_people(uuid) from anon;
grant execute on function get_directory_people(uuid) to authenticated;

notify pgrst, 'reload schema';

do $verify$
declare
  v_open int;
begin
  if not has_function_privilege('authenticated', 'get_directory_people(uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: authenticated cannot execute it, so the directory is empty for everyone.';
  end if;
  if has_function_privilege('anon', 'get_directory_people(uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon can execute it.';
  end if;

  -- The migration must not have opened anybody's directory by itself.
  -- Anything already set to 'members' was set deliberately on the
  -- settings page; this reports it rather than assuming.
  select count(*) into v_open from churches where directory_visibility = 'members';
  raise notice 'OK: enforced. % church(es) have chosen to show their directory to approved members.', v_open;
end
$verify$;
