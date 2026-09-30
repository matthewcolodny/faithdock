-- READ ONLY. Run in the Supabase SQL Editor and paste the output back.
--
-- Two questions this answers, both of which I cannot see from the repo:
--
--   1. Why the earliest import batches are missing from the admin list.
--      admin_list_import_batches() is not in supabase/migrations -- it
--      predates this repo -- so the list could be short because the
--      function caps it, because it filters something out, or because
--      those churches carry no import_batch_id at all and therefore
--      form no batch to list.
--
--   2. What "hide" actually writes, so a hide-everything button undoes
--      cleanly. The admin UI already distinguishes rows hidden by a
--      batch action from rows hidden by hand, so there is a marker
--      column somewhere and I need its real name before writing to it.
--
-- Nothing here changes a row. It also does not call any admin_* function:
-- auth.uid() is null in the SQL Editor, so is_platform_admin() is false
-- here and every one of them would refuse or return nothing.

-- 1 -------------------------------------------------------------------
-- The listing function's actual body: any LIMIT, any WHERE that drops
-- older rows, and what it groups by.
select pg_get_functiondef(p.oid) as admin_list_import_batches_def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname = 'admin_list_import_batches';

-- 2 -------------------------------------------------------------------
-- And the hide/show pair, which is where the marker column will be named.
select p.proname, pg_get_functiondef(p.oid) as def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('admin_hide_import_batch', 'admin_show_import_batch', 'admin_set_church_hidden')
 order by p.proname;

-- 3 -------------------------------------------------------------------
-- Every column on churches that looks like it records batch or hidden
-- state, so I am not guessing at a name.
select column_name, data_type, is_nullable, column_default
  from information_schema.columns
 where table_schema = 'public' and table_name = 'churches'
   and (column_name ilike '%batch%' or column_name ilike '%hidden%'
        or column_name ilike '%claim%' or column_name ilike '%owner%')
 order by column_name;

-- 4 -------------------------------------------------------------------
-- How the rows actually distribute. If the first imports landed before
-- import_batch_id existed they are all in the NULL bucket, which no
-- "batch" listing can ever show -- that alone would explain the gap.
select
  count(*)                                             as churches_total,
  count(*) filter (where import_batch_id is null)      as no_batch_id,
  count(distinct import_batch_id)                      as distinct_batches,
  count(*) filter (where is_hidden)                    as hidden_total
from churches;

-- 5 -------------------------------------------------------------------
-- Every batch, oldest first, with no function in the way. Compare this
-- count against what the admin page shows: if this is longer, the
-- function is capping; if it matches, the missing ones are in the NULL
-- bucket above.
select
  import_batch_id,
  min(created_at)                       as first_row_at,
  count(*)                              as rows_in_batch,
  count(*) filter (where is_hidden)     as hidden_in_batch
from churches
where import_batch_id is not null
group by import_batch_id
order by min(created_at) asc;
