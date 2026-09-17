-- Run in Supabase SQL Editor.
--
-- get_user_id_by_email() was an unauthenticated email-enumeration
-- oracle. Its entire body was:
--
--   select id from auth.users where email = lookup_email limit 1;
--
-- SECURITY DEFINER, no authorization check of any kind, and EXECUTE
-- granted to anon. Confirmed live while signed out: an address with no
-- account returns null, a real one returns a uuid. Anyone holding the
-- public anon key -- which is printed in the page source by design --
-- could therefore test whether any email address has a FaithDock
-- account, one request at a time, and harvest the account's uuid when
-- it does.
--
-- Two separate harms, and the second is the less obvious one:
--   1. Membership disclosure. "Does this person have an account on a
--      church platform" is not a neutral fact about someone.
--   2. The returned uuid is the id this app keys everything on --
--      event_registrations.user_id, church_memberships.user_id,
--      profiles.id. Handing a real one to an unauthenticated caller
--      gives them the exact value any other probing needs.
--
-- The fix is not to delete the function: both callers are real. It's
-- called when adding someone to a group by email, and when inviting a
-- staff member by email -- both privileged, both already behind a
-- signed-in dashboard. Nothing calls it before sign-in.
--
-- So it's restricted to the people who actually use it rather than
-- merely to "anyone signed in". Requiring auth alone would have turned
-- an open oracle into a $0 one -- create an account, keep probing. A
-- church owner, a staff member, or a group leader is a far smaller and
-- more accountable population, and it happens to be exactly the set
-- that reaches either call site.
--
-- Signature and return type are unchanged, so neither call site needs
-- touching and CREATE OR REPLACE is safe (no DROP required -- contrast
-- 039, which added a parameter and therefore could not use REPLACE).

CREATE OR REPLACE FUNCTION public.get_user_id_by_email(lookup_email text)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if auth.uid() is null then
    raise exception 'permission denied';
  end if;

  -- is_group_leader() is the existing helper; going through it rather
  -- than reading a role column directly means this keeps agreeing with
  -- however group leadership is defined elsewhere, instead of becoming
  -- a second, drifting definition of the same idea.
  if not (
    exists (select 1 from churches c where c.owner_id = auth.uid())
    or exists (select 1 from church_staff cs where cs.user_id = auth.uid())
    or exists (
      select 1 from group_members gm
      where gm.user_id = auth.uid() and is_group_leader(gm.group_id)
    )
  ) then
    raise exception 'permission denied';
  end if;

  return (select u.id from auth.users u where u.email = lookup_email limit 1);
end;
$function$;

-- Belt and braces: even with the check above, there is no reason for
-- this to appear in the anon role's callable API surface at all.
revoke execute on function public.get_user_id_by_email(text) from anon;

notify pgrst, 'reload schema';

-- Verify. As anon (signed out) the first should now fail rather than
-- answer; signed in as a church owner it should still work, which is
-- what keeps "add member by email" and "invite staff" functioning.
--   select get_user_id_by_email('someone@example.com');
