-- Run in the Supabase SQL Editor.
--
-- A login role for CI to run supabase/checks/security_invariants.sql
-- with, so the weekly workflow never holds the master database
-- password.
--
-- ####################################################################
-- #  THIS FILE CONTAINS NO PASSWORD AND CREATES NO USABLE LOGIN.      #
-- #                                                                   #
-- #  It creates the role with NOLOGIN. Enabling it is a separate,     #
-- #  deliberate statement you run once, by hand, and never commit:    #
-- #                                                                   #
-- #    alter role ci_invariants login password '<generated>';         #
-- #                                                                   #
-- #  Put that password straight into the GitHub secret and nowhere    #
-- #  else. tools/check.js fails the build if a password literal ever  #
-- #  appears in this file.                                            #
-- ####################################################################
--
-- WHY IT IS BUILT THIS WAY. The first version shipped a placeholder
-- password and told the reader to replace it before running. Somebody
-- ran it unchanged -- reasonably, since it looked runnable -- and that
-- created a login role on the production database whose password was
-- published in a public repository. The role is NOINHERIT with no table
-- grants, which sounds contained and is not: it can SET ROLE
-- authenticated and then set request.jwt.claims to any user id, which
-- is impersonation of any member or owner.
--
-- A migration that produces a working credential when run as written is
-- the wrong shape, however loud the comment above it. This one is inert
-- until a human types a password into a separate statement.
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
    raise notice 'Role ci_invariants already exists. This script will set it to NOLOGIN and refresh its membership rather than create it.';
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
-- NOLOGIN and no password. Re-running this on a role that has already
-- been given a real password will DISABLE it again, which is the safe
-- direction: re-enable deliberately rather than leave a credential
-- alive by accident.
do $create$
begin
  if exists (select 1 from pg_roles where rolname = 'ci_invariants') then
    alter role ci_invariants nologin noinherit;
    -- Worded without a quoted example on purpose: tools/check.js rejects
    -- any password literal in this file's runnable SQL, and a sample one
    -- inside a notice string trips it. The full statement is in the
    -- header comment.
    raise notice 'ci_invariants already existed and is now NOLOGIN. Re-enable it with a separate ALTER ROLE ... LOGIN PASSWORD statement (see the header).';
  else
    create role ci_invariants nologin noinherit;
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
-- Expect: can_login FALSE, inherits_passively FALSE, is_superuser false,
-- can_create_db false, member_of 'anon, authenticated', and
-- reads_tables_as_itself 0.
--
-- TWO that matter, for different reasons.
--
-- can_login false means the role is inert: it exists, it is shaped
-- correctly, and nobody can connect as it. That is the state to leave
-- it in until the moment the GitHub secret is being set up.
--
-- inherits_passively false means that once it IS enabled, it carries
-- none of anon's or authenticated's privileges unless it explicitly
-- switches. If that comes back true, this has not achieved what it set
-- out to, whatever the other columns say.
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
