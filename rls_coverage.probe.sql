-- READ ONLY. Run in the Supabase SQL Editor and paste the output back.
--
-- ONE statement, on purpose. The two probes before this were written
-- as a batch of separate selects, and the editor returns only one
-- result set per run -- so everything above the last statement was
-- thrown away, which is why both came back as a single table and the
-- questions that mattered went unanswered twice. Everything is unioned
-- into one output here, with a `section` column saying which question
-- each row answers.
--
-- WHAT IS BEING ASKED, AND WHY
--
-- All 39 tables in public carry DELETE/INSERT/TRUNCATE/UPDATE for
-- anon. That is Supabase's default -- the platform grants wide and
-- makes row level security the whole gate -- so the grants are not the
-- finding. Whether RLS is actually there to do that job is.
--
-- profiles is the sharp end. Measured: anon and authenticated hold
-- INSERT on EVERY column of it, including is_platform_admin, and anon
-- holds DELETE. If RLS does not stop an insert, the path is: delete
-- your own profile row, insert a replacement for your own auth.uid()
-- with is_platform_admin = true. Nothing in the grants prevents that.
-- Section C and D decide whether it is reachable.
--
-- Two things already confirmed good and not re-asked: anon has no
-- SELECT on profiles at all, and authenticated has SELECT on only
-- age_range, full_name and id. Migration 012b's narrowing works.
--
-- Nothing here writes, and nothing here touches a row.

select section, detail1, detail2, detail3, detail4
from (

  -- A. Tables with RLS off, or on but with no policy at all. A table
  -- with RLS off is one anon can read, write and empty over the REST
  -- API. RLS on with zero policies denies everything, which is safe
  -- but is usually an accident rather than a decision. Only the
  -- problem tables are listed -- 39 rows of "fine" is noise.
  select 1 as ord, 'A. RLS GAP' as section,
         c.relname::text as detail1,
         (case when c.relrowsecurity then 'rls on' else '*** RLS OFF ***' end)::text as detail2,
         ((select count(*) from pg_policies p
            where p.schemaname = 'public' and p.tablename = c.relname)::text
          || ' policies')::text as detail3,
         ''::text as detail4
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and (not c.relrowsecurity
          or (select count(*) from pg_policies p
               where p.schemaname = 'public' and p.tablename = c.relname) = 0)

  union all

  -- B. The denominator, so an empty section A reads as "checked and
  -- clean" rather than "the query did not run".
  select 2, 'B. SUMMARY',
         (count(*)::text || ' tables in public')::text,
         (count(*) filter (where not c.relrowsecurity)::text || ' with RLS off')::text,
         ''::text, ''::text
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'

  union all

  -- C. profiles itself.
  select 3, 'C. profiles table',
         (case when c.relrowsecurity then 'rls on' else '*** RLS OFF ***' end)::text,
         (case when c.relforcerowsecurity then 'forced' else 'not forced' end)::text,
         ''::text, ''::text
    from pg_class c where c.oid = 'public.profiles'::regclass

  union all

  -- D. Every policy on profiles. An INSERT policy whose WITH CHECK
  -- does not pin id to auth.uid(), or no INSERT policy at all, is the
  -- answer to the escalation question above.
  select 4, 'D. profiles policy',
         policyname::text, cmd::text,
         coalesce(qual, '(no USING)')::text,
         coalesce(with_check, '(no WITH CHECK)')::text
    from pg_policies
   where schemaname = 'public' and tablename = 'profiles'

  union all

  -- E. Any permissive write policy, on any table, that lets anon or
  -- public through with a USING/WITH CHECK of true. Some of these are
  -- legitimate -- contact messages, error logs and waitlist signups
  -- all take anonymous inserts by design -- so these are for reading,
  -- not for assuming.
  select 5, 'E. open write policy',
         (tablename || ' / ' || policyname)::text, cmd::text,
         ('USING ' || coalesce(qual, 'null'))::text,
         ('CHECK ' || coalesce(with_check, 'null'))::text
    from pg_policies
   where schemaname = 'public'
     and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
     and permissive = 'PERMISSIVE'
     and (roles::text like '%anon%' or roles::text like '%public%')
     and (coalesce(qual, 'true') = 'true' or coalesce(with_check, 'true') = 'true')

  union all

  -- F. Views that are not security_invoker. Such a view runs with its
  -- owner's rights and can hand back rows the underlying table's RLS
  -- would have refused. Postgres defaults this off.
  select 6, 'F. view not invoker',
         c.relname::text, ''::text, ''::text, ''::text
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'v'
     and coalesce((select option_value from pg_options_to_table(c.reloptions)
                    where option_name = 'security_invoker'), 'off') <> 'true'

) z
order by ord, detail1;
