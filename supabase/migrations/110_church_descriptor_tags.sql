-- Run in Supabase SQL Editor.
--
-- Descriptor tags for a church: what a visitor wants to know that the
-- denomination does not tell them. Which languages a service is in,
-- whether there is ASL or a deaf ministry, whether everyone is welcome,
-- what the music is like, what programmes run.
--
-- ---------------------------------------------------------------------
-- WHY ONE ARRAY RATHER THAN FIVE COLUMNS
--
-- The values are namespaced -- 'lang:spanish', 'music:gospel-choir',
-- 'welcome:asl-interpreted' -- so one text[] holds all five groups and
-- one GIN index serves every filter. The alternative, a column per
-- group, needs a migration every time a group is added and five
-- overlaps() calls to ask "does this church match anything I ticked".
--
-- The namespace also means the vocabulary can grow in the client alone.
-- Nothing here validates the values: a CHECK listing a hundred slugs
-- would have to be migrated in step with index.html forever, and a tag
-- that stops being offered simply stops being written. The client owns
-- the list; the column owns the storage.
--
-- ---------------------------------------------------------------------
-- WHAT THIS DOES NOT DO
--
-- It does not touch search_churches. The directory filters by fetching
-- the ids that overlap the ticked tags and passing them to the RPC's
-- existing p_church_ids parameter, which is how the events denomination
-- filter already works -- so the function body, which predates these
-- migrations and is not in this repo, stays untouched.

do $$
begin
  if not exists (select 1 from information_schema.tables
                 where table_schema = 'public' and table_name = 'churches') then
    raise exception 'ABORT: no churches table.';
  end if;
end $$;

alter table churches add column if not exists church_tags text[] not null default '{}';

-- Overlap queries only. GIN is what makes && and @> use an index at all.
create index if not exists churches_church_tags_idx on churches using gin (church_tags);

-- Readable by anyone who can read the directory, writable through the
-- existing row policies -- a church owner updating their own row. No new
-- policy: the column rides on the table's.
grant select (church_tags) on churches to anon, authenticated;
grant update (church_tags) on churches to authenticated;

-- ---------------------------------------------------------------------
do $$
declare
  has_col  boolean;
  has_idx  boolean;
  n_rows   integer;
begin
  select exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'churches'
                   and column_name = 'church_tags') into has_col;
  if not has_col then
    raise exception 'VERIFY FAILED: church_tags was not added.';
  end if;

  select exists (select 1 from pg_indexes
                 where schemaname = 'public' and indexname = 'churches_church_tags_idx') into has_idx;
  if not has_idx then
    raise exception 'VERIFY FAILED: the GIN index was not created.';
  end if;

  select count(*) into n_rows from churches;
  raise notice 'OK. church_tags on % churches, all empty until a church sets one.', n_rows;
  raise notice 'Nothing reads this column yet -- index.html only starts using it once this has run.';
end $$;
