-- READ ONLY. Run in the Supabase SQL Editor and paste the output back.
--
-- ONE statement, on purpose -- same reason as rls_coverage.probe.sql:
-- the editor returns only the last statement's result set, so a probe
-- written as several selects silently answers only its final question.
-- Everything is unioned here with a `section` column.
--
-- ---------------------------------------------------------------------
-- WHAT IS BEING ASKED, AND WHY
--
-- Before writing a migration for a daily scripture panel on the user
-- dashboard. The design is one row per date, written once a day by a
-- server-side job and read by every visitor:
--
--   * the model SELECTS from a pre-vetted verse pool and writes a
--     reflection. It never produces scripture text, so it cannot
--     misquote a verse.
--   * one AI call per day for the whole site, not per visitor.
--
-- Five things have to be true of the database before that migration can
-- be written, and the repo cannot answer any of them reliably -- 089
-- guessed five rules wrong and 118 nearly dropped the wrong function.
--
--   A. Does a table for this already exist under some other name? A
--      second one would be the "two definitions of search_groups"
--      problem again.
--
--   B. Does service_role actually BYPASS RLS here? The whole write
--      design rests on it: if it bypasses, the table needs RLS on, one
--      SELECT policy, and NO write policy at all, and the Edge Function
--      still writes. If it does not, the table needs an explicit write
--      policy and this design is wrong.
--
--   C. Is pg_cron available, and pg_net with it? pg_cron alone cannot
--      call an Edge Function -- it needs pg_net (or http) to make the
--      request. If neither is installable, scheduling has to come from
--      outside the database (a GitHub Actions cron), which is a
--      different migration and a different secret.
--
--   D. What does a world-readable, nobody-writes table look like in
--      THIS database? Copying a real one beats inventing a shape.
--
--   E. Do the helpers I would otherwise re-create already exist --
--      is_platform_admin() for an admin override, and an updated_at
--      trigger function?
--
-- Nothing here writes, and nothing here touches a row.

select section, detail1, detail2, detail3, detail4
from (

  -- A. NAME COLLISION. Any table, view or matview in public whose name
  -- suggests this feature already has a home. Empty is the expected
  -- answer and means the name is free.
  select 1 as ord, 'A. existing table?' as section,
         c.relname::text as detail1,
         (case c.relkind when 'r' then 'table' when 'v' then 'view'
                         when 'm' then 'matview' else c.relkind::text end)::text as detail2,
         ''::text as detail3,
         ''::text as detail4
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind in ('r', 'v', 'm')
     and (c.relname ~* 'scriptur|verse|devotion|daily|bible|psalm')

  union all

  -- B. Does service_role bypass RLS? rolbypassrls is the field that
  -- decides whether a table with no write policy is still writable by
  -- the Edge Function. anon and authenticated are listed alongside as
  -- the control -- they must read 'no'.
  select 2, 'B. role bypasses rls',
         rolname::text,
         (case when rolbypassrls then 'BYPASSES RLS' else 'no' end)::text,
         (case when rolsuper then 'superuser' else '' end)::text,
         ''::text
    from pg_roles
   where rolname in ('service_role', 'authenticated', 'anon', 'postgres', 'authenticator')

  union all

  -- C. Scheduling. installed_version non-null means it is already on;
  -- a row with installed_version null means it CAN be installed. No row
  -- at all means this Postgres cannot do it and scheduling moves out of
  -- the database entirely.
  select 3, 'C. extension',
         name::text,
         coalesce(installed_version, '(not installed)')::text,
         coalesce(default_version, '')::text,
         ''::text
    from pg_available_extensions
   where name in ('pg_cron', 'pg_net', 'http', 'pgsql-http')

  union all

  -- D. The house pattern for a read-only reference table: every policy
  -- on it is a SELECT and there is at least one. These are the tables
  -- the new one should look like. roles and the USING clause are what
  -- gets copied.
  select 4, 'D. read-only table',
         (p.tablename || ' / ' || p.policyname)::text,
         p.roles::text,
         coalesce(p.qual, '(no USING)')::text,
         (select count(*)::text || ' policies total'
            from pg_policies q where q.schemaname = 'public' and q.tablename = p.tablename)::text
    from pg_policies p
   where p.schemaname = 'public'
     and p.cmd = 'SELECT'
     and not exists (
           select 1 from pg_policies w
            where w.schemaname = 'public' and w.tablename = p.tablename
              and w.cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL'))

  union all

  -- E. Helpers that already exist, so the migration calls them instead
  -- of defining a second copy.
  select 5, 'E. helper function',
         p.proname::text,
         pg_get_function_identity_arguments(p.oid)::text,
         (case when p.prosecdef then 'security definer' else 'invoker' end)::text,
         pg_get_function_result(p.oid)::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'extensions')
     and (p.proname ~* 'is_platform_admin|updated_at|set_timestamp|moddatetime')

  union all

  -- F. The denominator, so an empty A reads as "asked and clean"
  -- rather than "the query did not run".
  select 6, 'F. summary',
         (count(*)::text || ' tables in public')::text,
         (count(*) filter (where c.relrowsecurity)::text || ' with rls on')::text,
         ''::text, ''::text
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'

) z
order by ord, detail1;
