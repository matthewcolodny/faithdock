-- Run in the Supabase SQL Editor.
--
-- The admin church list could not answer "what did I just import?".
-- It returned name, denomination, address, verification_status and
-- owner_id, sorted by name, so a fresh batch of 22 rows landed
-- scattered alphabetically through 1,309 and there was no way to see
-- which import a row came from or when it arrived.
--
-- This replaces search_all_churches_admin with the same function plus
-- created_at, the batch it came from, and is_hidden -- and two new
-- arguments: sort by newest, and filter to one batch.
--
-- WHY DROP FIRST. CREATE OR REPLACE cannot change a function's
-- argument list; with two new parameters it would create a SECOND
-- overload sitting beside the old one, and PostgREST would then have
-- to guess which to call. Migration 020 hit exactly this with
-- admin_import_churches, and 017 with search_churches before it. Drop
-- the old signature by name, precisely, then create.
--
-- The SQL Editor runs this as one transaction, so if the create fails
-- the drop rolls back with it and the admin list keeps working.
--
-- is_hidden is folded in deliberately. The client was fetching it in a
-- SECOND query against churches for every page of results, purely
-- because this function did not carry it -- see the comment at
-- loadAdminChurchesList. One round trip instead of two, and one place
-- that decides what an admin row contains.
--
-- NOTE ON VERIFYING THIS ONE: you cannot call it from the SQL Editor.
-- is_platform_admin() reads profiles.is_platform_admin for auth.uid(),
-- and the editor carries no JWT, so it returns false for everybody --
-- that is what made migration 098 fail on its first run. The checks at
-- the bottom read the catalog and the table instead.

-- ---------------------------------------------------------------------
-- Preflight
-- ---------------------------------------------------------------------
do $preflight$
begin
  if not exists (select 1 from pg_proc where proname = 'is_platform_admin') then
    raise exception 'ABORT: is_platform_admin() does not exist.';
  end if;
  -- Named one at a time so a failure says which column is missing
  -- rather than "something was wrong". 089 guessed at this table's
  -- shape and got five rules wrong.
  if not exists (select 1 from information_schema.columns
                 where table_name = 'churches' and column_name = 'created_at') then
    raise exception 'ABORT: churches.created_at is missing -- the whole point of this migration.';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_name = 'churches' and column_name = 'import_batch_id') then
    raise exception 'ABORT: churches.import_batch_id is missing. Run 020_import_batch_tracking.sql first.';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_name = 'churches' and column_name = 'is_hidden') then
    raise exception 'ABORT: churches.is_hidden is missing. Run 018_church_is_hidden.sql first.';
  end if;
end
$preflight$;

-- ---------------------------------------------------------------------
-- Replace
-- ---------------------------------------------------------------------
drop function if exists search_all_churches_admin(text, text, integer, integer);

create or replace function search_all_churches_admin(
  p_keyword text default null,
  p_status  text default null,
  p_limit   integer default 30,
  p_offset  integer default 0,
  p_sort    text default 'name',     -- 'name' | 'newest' | 'oldest'
  p_batch   text default null        -- exact import_batch_id
)
returns table (
  id uuid,
  name text,
  denomination text,
  address text,
  verification_status text,
  owner_id uuid,
  is_hidden boolean,
  created_at timestamptz,
  import_batch_id text,
  import_source_filename text,
  total_count bigint
)
language plpgsql
security definer
-- Explicit: SECURITY DEFINER runs as the owner, and an empty or
-- attacker-influenced search_path is how such a function gets pointed
-- at somebody else's churches table.
set search_path = public, pg_temp
as $$
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to search churches.';
  end if;

  return query
    select c.id, c.name, c.denomination, c.address, c.verification_status, c.owner_id,
           c.is_hidden, c.created_at, c.import_batch_id, c.import_source_filename,
           count(*) over() as total_count
    from churches c
    where
      (p_keyword is null or p_keyword = '' or c.name ilike '%' || p_keyword || '%')
      and (
        p_status is null or p_status = ''
        or (p_status = 'unclaimed' and c.owner_id is null)
        or (p_status = 'hidden' and c.is_hidden)
        or (p_status not in ('unclaimed', 'hidden') and c.verification_status = p_status)
      )
      and (p_batch is null or p_batch = '' or c.import_batch_id = p_batch)
    -- Sorted by a CASE rather than by building the query as a string.
    -- p_sort arrives from a dropdown today; a value that is not one of
    -- these three falls through to name, and no value of it can ever
    -- become SQL.
    order by
      case when p_sort = 'newest' then c.created_at end desc nulls last,
      case when p_sort = 'oldest' then c.created_at end asc  nulls last,
      case when p_sort not in ('newest', 'oldest') then c.name end asc
    limit p_limit offset p_offset;
end;
$$;

revoke all on function search_all_churches_admin(text, text, integer, integer, text, text) from public, anon;
grant execute on function search_all_churches_admin(text, text, integer, integer, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- Verify
-- ---------------------------------------------------------------------
-- 1. Exactly ONE search_all_churches_admin, executable by authenticated
--    and not by anon. The count is the part that matters: two would
--    mean the drop missed and an overload is live, which is the failure
--    this migration is shaped to avoid.
do $verify$
declare
  n integer;
  r record;
  problems text[] := '{}';
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'search_all_churches_admin';
  if n <> 1 then
    problems := problems || ('expected exactly 1 search_all_churches_admin, found ' || n ||
                             ' -- an old overload is still live and PostgREST may call either');
  end if;

  for r in
    select p.oid, p.prosecdef as secdef,
           has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
           has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.proname = 'search_all_churches_admin'
  loop
    if r.anon_exec then problems := problems || 'anon CAN execute it -- it reads every church including hidden ones'; end if;
    if not r.auth_exec then problems := problems || 'authenticated CANNOT execute it -- the admin page will break'; end if;
    if not r.secdef then problems := problems || 'not SECURITY DEFINER'; end if;
  end loop;

  if array_length(problems, 1) > 0 then
    raise exception E'INVARIANT FAILED:\n  %', array_to_string(problems, E'\n  ');
  end if;
  raise notice 'OK: one search_all_churches_admin, SECURITY DEFINER, authenticated only.';
end
$verify$;

-- 2. The data the new columns will show. Run against the table
--    directly, because the function itself is unreachable from here.
--    Expect the San Antonio .yes.csv import as the most recent batch.
select
  coalesce(import_batch_id, '(added individually)') as batch,
  count(*)            as rows,
  min(created_at)     as first_added,
  max(created_at)     as last_added
from churches
group by 1
order by max(created_at) desc
limit 10;
