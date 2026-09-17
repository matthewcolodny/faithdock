-- Run in Supabase SQL Editor. Requires migration 035 (which added
-- church_memberships.status).
--
-- Fixes a real bug in get_directory_people(): it has no idea the
-- approval workflow exists.
--
-- The whole point of 035/036 was that asking to join a church and being
-- a member of it are different things. This function predates that and
-- was never updated, so it still treats any membership row as
-- membership:
--
--   left join church_memberships cm
--     on cm.user_id = p.id and cm.church_id = target_church_id
--     and cm.is_permanent = true
--
-- with `coalesce(cm.is_permanent, false) as is_member`. A row created by
-- someone merely REQUESTING to join is is_permanent = true and
-- status = 'pending', which means two things went wrong at once:
--
--   1. is_member came back true, so a pending request was listed in the
--      Directory as a full member, and
--   2. the outer `where cm.id is not null` is what admitted them to the
--      result at all -- so someone with no other connection to the
--      church (not staff, not the owner, no registrations) appeared in
--      its Directory purely by having asked.
--
-- Both symptoms are the same missing predicate, so both are fixed by
-- adding it in one place. After this, a pending-only person doesn't
-- appear in the Directory -- correctly, since they already appear in
-- the membership review queue (get_church_membership_requests), which
-- is where a decision about them belongs.
--
-- CREATE OR REPLACE with no DROP, unlike migration 039: the argument
-- list and the RETURNS TABLE row type are both byte-identical to what
-- is deployed, and only the body changes. That is the one case REPLACE
-- handles cleanly -- no second overload, no 42P13. The definition below
-- is the live one from pg_get_functiondef with a single line changed,
-- not a reconstruction from memory.

CREATE OR REPLACE FUNCTION public.get_directory_people(target_church_id uuid)
 RETURNS TABLE(user_id uuid, full_name text, email text, phone text, avatar_url text, is_member boolean, is_staff boolean, is_owner boolean, has_registered_event boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not (
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or is_church_staff_member(target_church_id)
  ) then
    return;
  end if;

  return query
  select
    p.id as user_id,
    p.full_name::text,
    u.email::text,
    p.phone::text,
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
  -- The one changed line: status = 'approved'. In the JOIN condition
  -- rather than the WHERE, deliberately -- this is a LEFT join, and a
  -- WHERE clause on cm would turn it into an inner one, dropping staff,
  -- owners and event registrants who have no membership row at all.
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
$function$;

notify pgrst, 'reload schema';

-- Confirm: for a church with a PENDING request outstanding, that person
-- should now be absent from the first result and present in the second.
-- Run as a church owner/staff account, substituting the church id.
--
-- select user_id, full_name, is_member from get_directory_people('<church-id>');
-- select * from get_church_membership_requests('<church-id>');
