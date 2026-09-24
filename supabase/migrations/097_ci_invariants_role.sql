-- Run in the Supabase SQL Editor.
--
-- A login role for CI to run supabase/checks/security_invariants.sql
-- with, so the weekly workflow never holds the master database
-- password.
--
-- ####################################################################
-- #  BEFORE RUNNING: replace REPLACE_WITH_A_GENERATED_PASSWORD below  #
-- #  with a long random password.                                     #
-- #                                                                   #
-- #  DO NOT COMMIT THE FILLED-IN VERSION. Fill it in, run it, then    #
-- #  put the password straight into the GitHub secret and nowhere     #
-- #  else. tools/check.js fails the build if this file is ever        #
-- #  committed without the placeholder still in it.                   #
-- ####################################################################
--
-- WHY THIS EXISTS. The invariants have to answer "what can anon
-- actually see" and "what can a signed-in non-member actually see",
-- which means switching roles (`set local role anon`). A plain
-- read-only role cannot do that. Superuser can -- but handing a CI job
-- the master password means a leaked GitHub secret is the whole
-- database, and on Supabase that password is not even retrievable
-- after project creation, so using it at all means resetting it and
-- breaking anything that already depends on it.
--
-- NOINHERIT IS THE IMPORTANT WORD. Membership of anon and authenticated
-- would normally hand this role their privileges automatically, which
-- would include writing through every RLS policy that permits it.
-- NOINHERIT means membership grants only the right to SET ROLE, and
-- nothing is inherited passively. The checks do switch explicitly, so
-- they still work; anything that forgets to switch gets no privileges
-- at all. Fails closed.
--
-- What it can do:  read pg_catalog (granted to PUBLIC), and SET ROLE to
--                  anon or authenticated inside a transaction.
-- What it cannot:  read or write any application table as itself, own
--                  anything, or create anything.

-- ---------------------------------------------------------------------
-- Preflight
-- ---------------------------------------------------------------------
do $preflight$
begin
  if exists (select 1 from pg_roles where rolname = 'ci_invariants') then
    raise notice 'Role ci_invariants already exists. This script will update its password and membership rather than create it.';
  end if;
  -- Both must exist or the grants below fail with a confusing message.
  if not exists (select 1 from pg_roles where rolname = 'anon')
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise exception 'ABORT: anon and/or authenticated do not exist. This is not a Supabase database, or the roles are named differently.';
  end if;
end
$preflight$;

-- ---------------------------------------------------------------------
-- The role
-- ---------------------------------------------------------------------
do $create$
begin
  if exists (select 1 from pg_roles where rolname = 'ci_invariants') then
    alter role ci_invariants login noinherit password 'REPLACE_WITH_A_GENERATED_PASSWORD';
  else
    create role ci_invariants login noinherit password 'REPLACE_WITH_A_GENERATED_PASSWORD';
  end if;
end
$create$;

-- SET ROLE rights only, because of NOINHERIT above.
grant anon, authenticated to ci_invariants;

-- Belt and braces: it should never be able to create objects.
revoke create on schema public from ci_invariants;

-- ---------------------------------------------------------------------
-- Verify. Read the output rather than assuming.
-- ---------------------------------------------------------------------
-- Expect: can_login true, inherits_passively FALSE, is_superuser false,
-- can_create_db false, member_of 'anon, authenticated', and
-- reads_tables_as_itself 0.
--
-- inherits_passively is the one that matters. If it comes back true,
-- the role carries anon's and authenticated's privileges without asking
-- and this has not achieved what it set out to.
select
  r.rolcanlogin                                    as can_login,
  r.rolinherit                                     as inherits_passively,
  r.rolsuper                                       as is_superuser,
  r.rolcreatedb                                    as can_create_db,
  r.rolcreaterole                                  as can_create_role,
  (select string_agg(g.rolname, ', ' order by g.rolname)
     from pg_auth_members m
     join pg_roles g on g.oid = m.roleid
    where m.member = r.oid)                        as member_of,
  (select count(*) from information_schema.table_privileges
    where grantee = 'ci_invariants')               as reads_tables_as_itself
from pg_roles r
where r.rolname = 'ci_invariants';
