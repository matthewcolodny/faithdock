-- Run in the Supabase SQL Editor. Reads only -- changes nothing.
--
-- WHY: migration 092's own output reported three SELECT policies on
-- events, not one. Permissive policies OR together, so the strictest
-- one does not win -- the loosest does. Signed out, private events are
-- now correctly invisible (verified: 5 rows before, 0 after), which
-- proves none of the other two opens them to anon.
--
-- It does NOT prove anything about a SIGNED-IN person who is not a
-- member of that church. If one of the other two says something like
-- "authenticated can read events", a members-only event is still
-- readable by any account on the platform, just not by a logged-out
-- one -- and that is most of the exposure, since making an account is
-- free.
--
-- This prints the policies in full so that question can be answered by
-- reading them rather than guessing.

select
  p.polname                                              as policy_name,
  case p.polpermissive when true then 'PERMISSIVE (ORed)'
                       else 'RESTRICTIVE (ANDed)' end    as kind,
  coalesce(
    (select string_agg(r.rolname, ', ' order by r.rolname)
       from pg_roles r where r.oid = any(p.polroles)),
    'PUBLIC (every role)')                               as applies_to,
  pg_get_expr(p.polqual, p.polrelid)                     as using_expression
from pg_policy p
join pg_class c on c.oid = p.polrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'events'
  and p.polcmd in ('r', '*')       -- SELECT, and ALL (which covers SELECT)
order by p.polpermissive desc, p.polname;
