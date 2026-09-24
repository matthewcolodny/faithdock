-- Read-only. Shows the source of every function an RLS policy calls.
--
-- WHY. A policy is a WHERE clause, and when it calls a function the
-- real rule lives in the function, not in the policy text. Reading
-- `can_manage_church_events(church_id)` tells you nothing about who
-- that lets in.
--
-- It also answers a question the repo cannot: which policies and
-- functions exist in the database but were never written down here.
-- `events` currently carries a policy ("owner and permitted staff can
-- manage events") and a function (can_manage_church_events) that appear
-- in no migration in supabase/migrations. They predate the folder or
-- were created by hand in the dashboard. Either way:
--
--   * nobody can review them from the repo, and
--   * rebuilding this database from the migrations would not recreate
--     them, so the rebuilt copy would behave differently -- quietly.
--
-- WHAT TO LOOK FOR
--   prosecdef = SECURITY DEFINER runs as the function's owner and
--   bypasses RLS on what it reads. That is often correct (it is how
--   policy helpers avoid recursing into the table they protect) but it
--   means the body has to be right on its own.
--
--   volatility: a VOLATILE function inside a policy can be re-evaluated
--   per row, which is how a policy becomes a performance problem as
--   well as a correctness one.
--
--   Two PERMISSIVE policies for the same command OR together, so the
--   LOOSER one decides. If two policies express the same intent, the
--   tighter one is decorative.

with policy_fns as (
  -- Function names mentioned in any policy expression on a public table.
  select distinct
    c.relname                                            as on_table,
    p.polname                                            as policy_name,
    lower((regexp_matches(
      coalesce(pg_get_expr(p.polqual, p.polrelid), '') || ' ' ||
      coalesce(pg_get_expr(p.polwithcheck, p.polrelid), ''),
      '([a-zA-Z_][a-zA-Z0-9_]*)\s*\(', 'g'))[1])         as fn
  from pg_policy p
  join pg_class c      on c.oid = p.polrelid
  join pg_namespace ns on ns.oid = c.relnamespace
  where ns.nspname = 'public'
)
select
  pf.on_table,
  pf.policy_name,
  pr.proname                                             as function_name,
  case pr.prosecdef when true then 'SECURITY DEFINER (bypasses RLS)'
                    else 'SECURITY INVOKER' end          as runs_as,
  case pr.provolatile when 'i' then 'IMMUTABLE'
                      when 's' then 'STABLE'
                      else 'VOLATILE (may re-run per row)' end as volatility,
  coalesce(
    (select string_agg(r.rolname, ', ' order by r.rolname)
       from pg_roles r
      where has_function_privilege(r.rolname, pr.oid, 'EXECUTE')
        and r.rolname in ('anon', 'authenticated', 'service_role')),
    '(none of anon/authenticated/service_role)')         as executable_by,
  pg_get_functiondef(pr.oid)                             as source
from policy_fns pf
join pg_proc pr      on pr.proname = pf.fn
join pg_namespace pn on pn.oid = pr.pronamespace and pn.nspname = 'public'
order by pf.on_table, pf.policy_name, pr.proname;
