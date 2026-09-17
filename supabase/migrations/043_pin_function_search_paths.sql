-- Run in Supabase SQL Editor.
--
-- Clears the Advisor's "Function Search Path Mutable" warnings, but
-- deliberately NOT all of them in one sweep -- see the second half.
--
-- Why it matters: a SECURITY DEFINER function runs with its owner's
-- privileges. If its search_path isn't pinned, the schemas it resolves
-- unqualified names against are whatever the CALLER happens to have set.
-- Anyone able to create an object in a schema that lands earlier in that
-- path can shadow a table or function the definer function trusts, and
-- have their version run with the owner's rights. Pinning the path
-- removes the caller's influence entirely.
--
-- A loop rather than ~35 hand-written ALTER statements, because
-- ALTER FUNCTION needs the exact argument types and several of these
-- have long signatures (update_staff_abilities takes ten parameters).
-- Transcribing those by hand is a typo away from silently altering
-- nothing. Deriving them from the catalog can't drift.

-- === 1. Look first ===
-- Everything the sweep below will touch. Safe to run on its own.
select p.oid::regprocedure as function_signature,
       p.prosecdef        as is_security_definer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.prokind = 'f'
  and p.prosecdef
  and not exists (
    select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) cfg
    where cfg like 'search_path=%'
  )
  -- Extension-owned functions are excluded throughout: pg_net and
  -- pg_trgm are installed in public on this project, and their
  -- functions are not ours to alter. Attempting it either fails on
  -- ownership or, worse, succeeds and changes how the extension
  -- resolves its own internals.
  and not exists (
    select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e'
  )
order by 1;

-- === 2. The sweep: SECURITY DEFINER functions only ===
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.prosecdef
      and not exists (
        select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) cfg
        where cfg like 'search_path=%'
      )
      and not exists (
        select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e'
      )
  loop
    -- public, pg_temp matches what 032/035/036/040 already set, so the
    -- whole codebase ends up saying the same thing. pg_temp goes LAST
    -- on purpose: left implicit it is searched FIRST, which is itself
    -- the hijack -- a temp table can shadow a real one.
    execute format('alter function %s set search_path = public, pg_temp', r.sig);
    raise notice 'pinned search_path on %', r.sig;
  end loop;
end $$;

notify pgrst, 'reload schema';

-- === 3. Confirm ===
-- Expect zero rows. Re-run query 1 to check.

-- === What is deliberately NOT swept, and why ===
--
-- SECURITY INVOKER functions are left alone even though the linter
-- flags them too (search_events and search_churches among them). Two
-- reasons, and the second is the one that would bite:
--
--   1. The privilege-escalation argument doesn't apply. An INVOKER
--      function already runs as the caller, so hijacking its search_path
--      gains an attacker nothing they couldn't do by writing the query
--      themselves. The warning is hygiene there, not a vulnerability.
--
--   2. Adding a SET clause to a LANGUAGE sql function BLOCKS INLINING.
--      The planner cannot inline a SQL function that carries a SET, so
--      search_events -- a multi-join query with a LIMIT, run on every
--      Events page load -- would stop being folded into the calling
--      query and could get materially slower. Trading real query
--      performance for a warning that carries no privilege risk is a
--      bad trade, and it should be made knowingly rather than by a
--      sweep that didn't notice.
--
-- If those warnings are wanted at zero anyway, drop `and p.prosecdef`
-- from both queries above -- but benchmark the Events page after.
