-- READ ONLY. Run in the Supabase SQL Editor and paste the output back.
--
-- Two things are about to be built and both touch objects that predate
-- supabase/migrations, so neither is being written from a guess:
--
--   A. search_groups() gains the church's address and coordinates (so a
--      group card can offer Directions) plus group_tags and
--      meeting_format (so it can show what the group IS, the way a
--      church card leads with its denomination).
--
--   B. the map "show shops, restaurants and other places" setting moves
--      off this browser and onto the account.
--
-- The repo has TWO definitions of search_groups -- 067 wrote one, 068
-- dropped it and wrote another with image_url -- so the repo alone does
-- not say which is live. A return type cannot be changed by CREATE OR
-- REPLACE; it has to be DROPped by its exact argument list first, and
-- dropping the wrong signature silently leaves the real one in place.

-- 1 -------------------------------------------------------------------
-- Every overload of search_groups that exists, with its full argument
-- list and its current return columns. This is what the DROP must name.
select p.oid::regprocedure                        as exact_signature,
       p.prosecdef                                as security_definer,
       pg_get_function_result(p.oid)              as returns
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'search_groups';

-- 2 -------------------------------------------------------------------
-- The body actually running, so the new one is an edit of the live
-- text rather than a rewrite of whichever file happened to be read.
select pg_get_functiondef(p.oid) as live_body
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'search_groups';

-- 3 -------------------------------------------------------------------
-- The columns the new return type would read. address/lat/lng on
-- churches and group_tags/meeting_format on groups are all assumed to
-- exist; this is the assumption, checked.
select table_name, column_name, data_type
  from information_schema.columns
 where table_schema = 'public'
   and (
     (table_name = 'churches' and column_name in ('address','lat','lng','city','state'))
     or (table_name = 'groups' and column_name in ('group_tags','meeting_format','image_url'))
   )
 order by table_name, column_name;

-- 4 -------------------------------------------------------------------
-- B: does profiles already carry a map or display preference under some
-- name? Adding a second one beside an existing one is how a setting
-- ends up with two sources of truth.
select column_name, data_type, column_default, is_nullable
  from information_schema.columns
 where table_schema = 'public' and table_name = 'profiles'
 order by ordinal_position;

-- 5 -------------------------------------------------------------------
-- B: the house pattern for a self-write. 012b routed every profile
-- write through a SECURITY DEFINER function because anon held an
-- unscoped UPDATE grant; the new setter has to match that shape, not
-- add a column grant beside it.
select p.proname,
       p.prosecdef                          as security_definer,
       pg_get_function_identity_arguments(p.oid) as args,
       pg_get_function_result(p.oid)        as returns
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and (p.proname like '%my_private_profile%'
        or p.proname like 'update_profile%'
        or p.proname like 'set_my%'
        or p.proname like 'get_my%')
 order by p.proname;

-- 6 -------------------------------------------------------------------
-- B: what anon and authenticated may do to profiles right now, so the
-- new column does not quietly inherit a table-wide grant.
select grantee, privilege_type, column_name
  from information_schema.column_privileges
 where table_schema = 'public' and table_name = 'profiles'
   and grantee in ('anon', 'authenticated')
 order by grantee, privilege_type, column_name;

select grantee, privilege_type
  from information_schema.role_table_grants
 where table_schema = 'public' and table_name = 'profiles'
   and grantee in ('anon', 'authenticated')
 order by grantee, privilege_type;
