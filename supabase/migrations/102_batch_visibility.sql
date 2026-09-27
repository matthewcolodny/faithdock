-- Run in Supabase SQL Editor.
--
-- Gives "Hide all" a counterpart, and makes it safe to use one after
-- the other: showing a batch again must NOT resurrect the churches
-- somebody hid one at a time on purpose.
--
-- ---------------------------------------------------------------------
-- WHY A SECOND COLUMN
--
-- is_hidden alone cannot answer "should this come back?". Hide a batch
-- of 400, then show it, and a plain "set is_hidden = false where
-- import_batch_id = ..." also un-hides the handful hidden deliberately
-- -- the duplicates, the non-congregations, the one with a wrong
-- address. Those are the decisions worth keeping, and losing them is
-- silent: the church is simply back in the directory and nothing says
-- it should not be.
--
-- hidden_by_batch records WHO hid it. Hiding a batch only touches rows
-- that are visible at that moment, and marks them. Showing a batch only
-- clears rows it marked. A church hidden by hand is never marked, so a
-- show walks straight past it.
--
--   church state          hide all              show all
--   ------------          --------              --------
--   visible               hidden, marked        visible again
--   hidden by hand        left alone            LEFT ALONE
--   hidden by this batch  already marked        visible again
--
-- ---------------------------------------------------------------------
-- The verify block asserts from the catalog and from churches directly.
-- It does NOT call these functions: auth.uid() is null in the SQL
-- Editor, so is_platform_admin() is always false there and every admin
-- RPC raises. A check that cannot pass for the right reason is no check.

do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_name = 'churches' and column_name = 'is_hidden') then
    raise exception 'ABORT: churches.is_hidden is missing. Run 018_church_is_hidden.sql first.';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_name = 'churches' and column_name = 'import_batch_id') then
    raise exception 'ABORT: churches.import_batch_id is missing. Run 020_import_batch_tracking.sql first.';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                 where ns.nspname = 'public' and p.proname = 'admin_hide_import_batch') then
    raise exception 'ABORT: admin_hide_import_batch is missing. Run 020_import_batch_tracking.sql first.';
  end if;
end $$;

alter table churches add column if not exists hidden_by_batch boolean not null default false;

-- Every church hidden before today was hidden by hand -- "Hide all"
-- existed but nothing recorded that it was the one responsible. Leaving
-- the default false is the safe reading: the first "Show all" after
-- this migration will leave all of them hidden. Anything that was
-- batch-hidden and should come back can be shown individually, once.
create index if not exists idx_churches_hidden_by_batch
  on churches(import_batch_id) where hidden_by_batch = true;

-- Replaces the 020 version. Same owner_id is null scoping -- a church
-- somebody has genuinely claimed should not vanish under them because
-- it started life as an import row -- plus two changes: it only touches
-- rows that are currently visible, and it marks what it hid.
create or replace function admin_hide_import_batch(p_batch_id text)
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
     set is_hidden = true, hidden_by_batch = true
   where owner_id is null
     and is_hidden = false
     and import_batch_id is not distinct from p_batch_id;

  get diagnostics affected = row_count;
  return affected;
end;
$$;

grant execute on function admin_hide_import_batch(text) to authenticated;

-- The counterpart. Only undoes what the line above did.
create or replace function admin_show_import_batch(p_batch_id text)
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
     and hidden_by_batch = true
     and import_batch_id is not distinct from p_batch_id;

  get diagnostics affected = row_count;
  return affected;
end;
$$;

grant execute on function admin_show_import_batch(text) to authenticated;

-- The batch list gains hidden_count. Without it "Hide all" reports 400
-- hidden and the row it sits on looks exactly as it did a moment ago --
-- unclaimed_count does not move, because hiding does not claim
-- anything. Reported as the button not responding, and it was right:
-- nothing on screen could have changed.
--
-- DROPped first, not replaced. CREATE OR REPLACE cannot change a
-- function's return type, and a silent failure here leaves the old
-- five-column version live.
drop function if exists admin_list_import_batches(integer);

create or replace function admin_list_import_batches(p_limit integer default 100)
returns table(
  import_batch_id text,
  source_filename text,
  batch_date timestamptz,
  row_count bigint,
  unclaimed_count bigint,
  hidden_count bigint,
  batch_hidden_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to view import batches.';
  end if;

  return query
    select c.import_batch_id, max(c.import_source_filename), min(c.created_at) as batch_date,
      count(*) as row_count,
      count(*) filter (where c.owner_id is null) as unclaimed_count,
      -- everything hidden, however it got that way
      count(*) filter (where c.is_hidden) as hidden_count,
      -- the subset "Show all" would bring back
      count(*) filter (where c.hidden_by_batch) as batch_hidden_count
    from churches c
    where c.import_batch_id is not null
    group by c.import_batch_id
    order by batch_date desc
    limit p_limit;
end;
$$;

grant execute on function admin_list_import_batches(integer) to authenticated;

-- Hiding or showing one church by hand takes it out of the batch's
-- care, in both directions. Without this, hiding a church by hand
-- inside a batch-hidden set would leave its old mark in place and the
-- next "Show all" would undo the decision.
create or replace function admin_set_church_hidden(target_church_id uuid, hidden boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from profiles where id = auth.uid() and is_platform_admin = true) then
    raise exception 'You do not have permission to change a church''s visibility.';
  end if;
  update churches
     set is_hidden = hidden, hidden_by_batch = false
   where id = target_church_id;
end;
$$;

grant execute on function admin_set_church_hidden(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------
do $$
declare
  n_marked integer;
  n_hidden integer;
begin
  if not exists (select 1 from information_schema.columns
                 where table_name = 'churches' and column_name = 'hidden_by_batch') then
    raise exception 'VERIFY FAILED: churches.hidden_by_batch was not created.';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                 where ns.nspname = 'public' and p.proname = 'admin_show_import_batch') then
    raise exception 'VERIFY FAILED: admin_show_import_batch was not created.';
  end if;
  -- The list must be the seven-column version, or the admin panel reads
  -- hidden_count off a row that does not have one.
  if (select count(*) from information_schema.routines r
      join information_schema.parameters pa on pa.specific_name = r.specific_name
      where r.routine_name = 'admin_list_import_batches'
        and pa.parameter_mode = 'OUT' and pa.parameter_name = 'hidden_count') <> 1 then
    raise exception 'VERIFY FAILED: admin_list_import_batches has no hidden_count column.';
  end if;
  if (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname = 'admin_list_import_batches') <> 1 then
    raise exception 'VERIFY FAILED: admin_list_import_batches has more than one signature.';
  end if;
  -- One live overload each, or the client gets "could not choose".
  if (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname = 'admin_hide_import_batch') <> 1 then
    raise exception 'VERIFY FAILED: admin_hide_import_batch has more than one signature.';
  end if;

  select count(*) into n_hidden from churches where is_hidden = true;
  select count(*) into n_marked from churches where hidden_by_batch = true;
  if n_marked <> 0 then
    raise exception 'VERIFY FAILED: % rows already marked hidden_by_batch; expected 0.', n_marked;
  end if;

  raise notice 'OK. % churches hidden, none of them marked -- the first Show all will leave every one alone.', n_hidden;
end $$;
