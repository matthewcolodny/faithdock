-- Run in Supabase SQL Editor. Requires 035 (church_memberships.status).
--
-- The same bug migration 040 fixed in get_directory_people, still
-- sitting in get_mass_email_recipients. Found by capturing the
-- untracked RPCs and reading them side by side -- 040's fix was applied
-- to one function and not to the other, which is the ordinary way a
-- rule gets half-enforced.
--
-- === The bug ===
-- 040 records the fact that matters here: a row created by someone
-- merely REQUESTING to join is `is_permanent = true` with
-- `status = 'pending'`. So this branch --
--
--     where cm.church_id = target_church_id and cm.is_permanent = true
--
-- treats every person who ever asked to join as a member. Emailing
-- "Members" reaches:
--
--   * people whose request is still pending, who have not been let in
--   * people whose request was REJECTED, who were explicitly kept out
--
-- Sending a church's internal announcements to someone it declined is
-- worse than a missing feature. And nothing about the sending UI hints
-- at it: the audience says "Members", the count looks plausible, and
-- the extra recipients are invisible to whoever pressed send.
--
-- People who LEFT are already excluded -- 036 flips is_permanent to
-- false rather than deleting the row -- so `status = 'approved'` is the
-- only predicate missing.
--
-- === Scope ===
-- ONLY the 'members' branch changes. The other three are already
-- correct and are reproduced verbatim:
--   staff -> church_staff plus the owner, no membership involved
--   group -> gm.status = 'active'
--   event -> er.status = 'confirmed'
--
-- CREATE OR REPLACE with no DROP, for the same reason 040 gave: the
-- argument list and return type are byte-identical to what is
-- deployed and only the body changes. The body below is the live one
-- from pg_get_functiondef (see supabase/db-functions/captured_2026-09-18.sql)
-- with one line changed, not a reconstruction.

CREATE OR REPLACE FUNCTION public.get_mass_email_recipients(target_church_id uuid, audience_type text, audience_ref_id uuid DEFAULT NULL::uuid)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  recipient_emails text[];
begin
  if not (
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or is_church_staff_member(target_church_id)
  ) then
    return array[]::text[];
  end if;

  if audience_type = 'members' then
    select array_agg(distinct u.email) into recipient_emails
    from church_memberships cm
    join auth.users u on u.id = cm.user_id
    -- status = 'approved' added. Asking to join and being a member are
    -- different things (035/036), and this is the line that was missing
    -- it. Matches get_directory_people after 040.
    where cm.church_id = target_church_id
      and cm.is_permanent = true
      and cm.status = 'approved';

  elsif audience_type = 'staff' then
    select array_agg(distinct u.email) into recipient_emails
    from (
      select user_id from church_staff where church_id = target_church_id
      union
      select owner_id as user_id from churches where id = target_church_id
    ) people
    join auth.users u on u.id = people.user_id;

  elsif audience_type = 'group' then
    select array_agg(distinct u.email) into recipient_emails
    from group_members gm
    join groups g on g.id = gm.group_id
    join auth.users u on u.id = gm.user_id
    where g.id = audience_ref_id and g.church_id = target_church_id and gm.status = 'active';

  elsif audience_type = 'event' then
    select array_agg(distinct u.email) into recipient_emails
    from event_registrations er
    join events e on e.id = er.event_id
    join auth.users u on u.id = er.user_id
    where e.id = audience_ref_id and e.church_id = target_church_id and er.status = 'confirmed';
  end if;

  return coalesce(recipient_emails, array[]::text[]);
end;
$function$;

notify pgrst, 'reload schema';

-- How many people this was reaching that it should not have been.
-- Read-only, and worth looking at: each row is somebody who received a
-- church's member emails without being a member of it.
select c.name            as church,
       cm.status         as membership_status,
       count(*)          as people
  from church_memberships cm
  join churches c on c.id = cm.church_id
 where cm.is_permanent = true
   and cm.status is distinct from 'approved'
 group by c.name, cm.status
 order by people desc;

do $verify$
begin
  -- The predicate has to actually be in the deployed body. Checking
  -- that the function exists would pass whether or not the fix landed.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_mass_email_recipients'
       and pg_get_functiondef(p.oid) like '%cm.status = ''approved''%'
  ) then
    raise exception 'VERIFY FAILED: the members branch still has no status check.';
  end if;
  raise notice 'OK: "Members" now means approved members only.';
end
$verify$;
