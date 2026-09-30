-- READ ONLY. Run in the Supabase SQL Editor and paste the output back.
--
-- ONE statement. The editor returns only the last statement's result,
-- so a batch of separate selects loses everything above the final one
-- -- that cost three round trips on the RLS probe before it was
-- noticed. Sections are unioned into one output and named in the
-- `section` column.
--
-- WHAT IS BEING BUILT, AND WHAT IS NOT KNOWN
--
--   A/B/C  search_groups gains the church's address and coordinates,
--          so a group card's Directions link points at a real place
--          rather than at "church name, city, state"; plus group_tags
--          and meeting_format, so the card can lead with what the
--          group IS the way a church card leads with its denomination.
--
--   D/E    the map's "show shops and restaurants" setting moves onto
--          the account. Migration 117 has just revoked every write
--          grant on profiles from the browser roles, so this must go
--          through a SECURITY DEFINER function -- E is asking what
--          that family already looks like so the new pair matches it.
--
-- The repo cannot answer A. It holds TWO definitions of search_groups:
-- 067 wrote one, 068 dropped it and wrote another with image_url. A
-- return type cannot be changed by CREATE OR REPLACE -- it has to be
-- DROPped by its exact argument list first, and dropping the wrong
-- signature silently leaves the real function in place.
--
-- B returns the whole live body, which is long and will come back as
-- one big quoted cell. That is deliberate: the new version should be
-- an edit of what is actually running, not a rewrite of whichever file
-- happened to be read.
--
-- Nothing here writes.

select section, detail1, detail2, detail3
from (

  -- A. Every overload that exists, with the argument list a DROP would
  -- have to name exactly, and whether it bypasses RLS.
  select 1 as ord,
         'A. search_groups signature'::text as section,
         p.oid::regprocedure::text as detail1,
         (case when p.prosecdef then '*** SECURITY DEFINER ***' else 'security invoker' end)::text as detail2,
         pg_get_function_result(p.oid)::text as detail3
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'search_groups'

  union all

  -- B. The body actually running.
  select 2, 'B. search_groups body'::text,
         pg_get_functiondef(p.oid)::text,
         ''::text, ''::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'search_groups'

  union all

  -- C. The columns the new return type would read. All assumed to
  -- exist; this is the assumption checked. Anything MISSING changes
  -- what the migration can offer.
  select 3, 'C. column check'::text,
         (w.t || '.' || w.c)::text,
         (case when col.column_name is null then '*** MISSING ***' else 'present' end)::text,
         coalesce(col.data_type, '')::text
    from (values
            ('churches','address'), ('churches','lat'), ('churches','lng'),
            ('churches','city'),    ('churches','state'),
            ('groups','group_tags'),('groups','meeting_format'), ('groups','image_url')
         ) as w(t, c)
    left join information_schema.columns col
           on col.table_schema = 'public'
          and col.table_name = w.t
          and col.column_name = w.c

  union all

  -- D. Does profiles already carry a map or display preference under
  -- some name? Adding a second beside an existing one is how a setting
  -- ends up with two sources of truth.
  select 4, 'D. profiles column'::text,
         column_name::text,
         data_type::text,
         coalesce(column_default, '')::text
    from information_schema.columns
   where table_schema = 'public' and table_name = 'profiles'

  union all

  -- E. The house pattern for reading and writing your own profile
  -- row, which the new getter and setter have to match.
  select 5, 'E. profile self RPC'::text,
         p.proname::text,
         ('(' || pg_get_function_identity_arguments(p.oid) || ')')::text,
         ((case when p.prosecdef then 'DEFINER ' else 'invoker ' end)
          || pg_get_function_result(p.oid))::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and (p.proname like 'get_my%'
          or p.proname like 'set_my%'
          or p.proname like 'update_profile%')

) z
order by ord, detail1;
