-- Run in Supabase SQL Editor.
--
-- Hide (or bring back) every unclaimed church in one go, instead of one
-- import batch at a time. There are 135 batches; taking the directory
-- dark before a demo meant 135 clicks.
--
-- ---------------------------------------------------------------------
-- MODELLED ON admin_hide_import_batch, NOT INVENTED
--
-- That function is:
--
--   update churches set is_hidden = true, hidden_by_batch = true
--    where owner_id is null and is_hidden = false
--      and import_batch_id is not distinct from p_batch_id;
--
-- These two are the same statement with the batch predicate dropped.
-- Three things in it matter and are kept exactly:
--
--   owner_id is null  -- a church somebody has claimed is theirs. It is
--                        never hidden by an admin bulk action.
--
--   is_hidden = false -- already-hidden rows are skipped, which is what
--                        preserves their hidden_by_batch marker. 477
--                        churches in the first import are already
--                        hidden; if this touched them it would relabel
--                        hand-hidden rows as batch-hidden, and the
--                        matching show would then un-hide churches that
--                        were deliberately hidden one by one.
--
--   hidden_by_batch   -- the marker that separates "hidden by a bulk
--                        action" from "hidden by hand". Show only ever
--                        clears rows carrying it.
--
-- So hide-all followed by show-all is a round trip: it leaves exactly
-- the rows that were hidden before it, still hidden.

do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'is_platform_admin') then
    raise exception 'ABORT: is_platform_admin() is missing.';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'churches'
                   and column_name = 'hidden_by_batch') then
    raise exception 'ABORT: churches.hidden_by_batch is missing; there would be no way to undo this.';
  end if;
end $$;

create or replace function public.admin_hide_all_unclaimed_churches()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  affected integer;
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to change a church''s visibility.';
  end if;

  update churches
     set is_hidden = true, hidden_by_batch = true
   where owner_id is null
     and is_hidden = false;

  get diagnostics affected = row_count;
  return affected;
end;
$function$;

-- The undo. Deliberately keyed on the marker alone and not on a batch:
-- it brings back everything any bulk hide put away, and nothing else.
create or replace function public.admin_show_all_batch_hidden_churches()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  affected integer;
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to change a church''s visibility.';
  end if;

  update churches
     set is_hidden = false, hidden_by_batch = false
   where hidden_by_batch = true
     and is_hidden = true;

  get diagnostics affected = row_count;
  return affected;
end;
$function$;

revoke all on function public.admin_hide_all_unclaimed_churches() from public, anon;
revoke all on function public.admin_show_all_batch_hidden_churches() from public, anon;
grant execute on function public.admin_hide_all_unclaimed_churches() to authenticated;
grant execute on function public.admin_show_all_batch_hidden_churches() to authenticated;

-- ---------------------------------------------------------------------
do $$
declare
  n_funcs      integer;
  would_hide   bigint;
  would_show   bigint;
  hand_hidden  bigint;
begin
  -- Deliberately does NOT call either function: auth.uid() is null in
  -- the SQL Editor, so is_platform_admin() is false here and both would
  -- raise. What can be checked is that they exist and what they would
  -- touch.
  select count(*) into n_funcs from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('admin_hide_all_unclaimed_churches', 'admin_show_all_batch_hidden_churches');
  if n_funcs <> 2 then
    raise exception 'VERIFY FAILED: expected 2 functions, found %.', n_funcs;
  end if;

  select count(*) into would_hide from churches where owner_id is null and is_hidden = false;
  select count(*) into would_show from churches where hidden_by_batch and is_hidden;
  select count(*) into hand_hidden from churches where is_hidden and not hidden_by_batch;

  raise notice 'OK. Hide all would hide % churches.', would_hide;
  raise notice 'Show all would bring back % (rows a bulk hide put away).', would_show;
  raise notice '% churches are hidden by hand and are left alone by both.', hand_hidden;
end $$;
