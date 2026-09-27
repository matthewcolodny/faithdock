-- Run in Supabase SQL Editor. Requires 102_batch_visibility.sql.
--
-- 102 left a batch hidden before it existed with no way back.
--
-- Its rule was: "Show all" only clears rows that "Hide all" marked, and
-- anything hidden before the mark existed counts as hidden by hand, so
-- it is never touched. Safe, and wrong at the edges -- fs-san-antonio-1
-- had all 400 of its churches hidden by the OLD "Hide all" minutes
-- before 102 ran. Not one of them was a human decision, none carry the
-- mark, and the admin panel now offers no button that would bring them
-- back. 400 churches with no way out except one at a time.
--
-- The honest fix is not to guess which legacy rows were deliberate. It
-- is to let the admin say "I know you cannot tell -- show them anyway",
-- and to only ask that of batches where there is genuinely nothing to
-- tell apart.
--
--   batch has marked rows      -> Show all clears exactly those. No prompt.
--   batch has only legacy rows -> Show all can clear them, on confirmation.
--
-- After a batch has been shown once it is in the new world, and every
-- hide from then on is marked.

do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_name = 'churches' and column_name = 'hidden_by_batch') then
    raise exception 'ABORT: churches.hidden_by_batch is missing. Run 102_batch_visibility.sql first.';
  end if;
end $$;

-- The two-argument form. The one-argument form from 102 stays, and
-- keeps its old meaning, so any caller that has not been updated cannot
-- accidentally sweep up a hand-hidden church.
create or replace function admin_show_import_batch(p_batch_id text, p_include_unmarked boolean)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  affected integer;
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to change a church''s visibility.';
  end if;

  update churches
     set is_hidden = false, hidden_by_batch = false
   where owner_id is null
     and is_hidden = true
     and import_batch_id is not distinct from p_batch_id
     and (
       hidden_by_batch = true
       -- Only when asked, and only for rows that predate the mark.
       or (p_include_unmarked and hidden_by_batch = false)
     );

  get diagnostics affected = row_count;
  return affected;
end;
$$;

grant execute on function admin_show_import_batch(text, boolean) to authenticated;

-- ---------------------------------------------------------------------
do $$
declare
  n_legacy integer;
  n_args2  integer;
  n_total  integer;
  sigs     text;
begin
  -- Counted by argument count, not by comparing the formatted signature
  -- string. The first version of this check matched
  -- pg_get_function_identity_arguments against the literal 'text,
  -- boolean' and failed on a function that was sitting right there,
  -- taking the whole migration down with it. pronargs cannot be tripped
  -- by spacing, argument names or how the server chooses to print a type.
  select count(*) filter (where p.pronargs = 2), count(*),
         string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    into n_args2, n_total, sigs
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'admin_show_import_batch';

  if n_args2 <> 1 then
    raise exception 'VERIFY FAILED: no two-argument admin_show_import_batch. Found: %', coalesce(sigs, 'nothing');
  end if;
  -- Both forms are meant to be live: the client picks by argument count.
  if n_total <> 2 then
    raise exception 'VERIFY FAILED: expected 2 admin_show_import_batch signatures, found %. %', n_total, coalesce(sigs, '');
  end if;

  select count(*) into n_legacy
    from churches
   where is_hidden = true and hidden_by_batch = false
     and owner_id is null and import_batch_id is not null;

  raise notice 'OK. % hidden churches in batches carry no mark -- those batches now offer Show all behind a confirmation.', n_legacy;
end $$;
