-- Run in the Supabase SQL Editor.
--
-- A group can say which ministry runs it.
--
-- REQUESTED: clicking a ministry should show the groups, events and
-- rooms attributed to it. Events already are, through
-- event_ministries (migration 025). Rooms are derivable -- the rooms
-- those events book. Groups were attributed to nothing: there is no
-- column and no join table anywhere that connects a group to a
-- ministry, so the question "which groups does the youth ministry
-- run?" had no answer to read, only one to invent.
--
-- A COLUMN, NOT A JOIN TABLE, unlike event_ministries. An event can
-- genuinely be co-hosted -- a joint service between two ministries is
-- a real thing, which is why 025 built a join table with an
-- is_primary flag. A group is run by one ministry or by none; a
-- second row would be a question nobody asked. Nullable, because
-- "none" is the honest state for most groups and for every group that
-- exists right now.
--
-- ON DELETE SET NULL, not cascade. Ministries are soft-deleted
-- (is_active = false) rather than removed, so this mostly will not
-- fire -- but if a ministry row is ever really deleted, that must
-- orphan the attribution, not the group. A cascade here would delete
-- somebody's small group because an admin tidied up a ministry list.

-- ---------------------------------------------------------------------
-- Preflight: fail by name, before changing anything.
-- ---------------------------------------------------------------------
do $preflight$
begin
  if not exists (select 1 from information_schema.tables
                 where table_schema = 'public' and table_name = 'groups') then
    raise exception 'VERIFY FAILED: public.groups does not exist. Nothing was changed.';
  end if;
  if not exists (select 1 from information_schema.tables
                 where table_schema = 'public' and table_name = 'church_ministries') then
    raise exception 'VERIFY FAILED: public.church_ministries does not exist. Nothing was changed.';
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'groups'
               and column_name = 'ministry_id') then
    raise notice 'groups.ministry_id already exists -- this migration is a no-op.';
  end if;
end
$preflight$;

alter table groups
  add column if not exists ministry_id uuid
  references church_ministries(id) on delete set null;

-- Every read of this column is "the groups belonging to ministry X",
-- and most groups will have null here, so a partial index is both
-- smaller and the whole answer.
create index if not exists idx_groups_ministry_id
  on groups(ministry_id) where ministry_id is not null;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Verify.
--
-- The grants are the part that can silently half-work. Postgres
-- extends TABLE-level privileges to a new column automatically, but
-- NOT column-level ones: if groups was ever granted per-column (the
-- way event_registrations was, which is exactly what broke anonymous
-- event browsing until migration 085), then authenticated can read
-- and write every column except the one just added, and the group
-- form would fail on save with a permission error rather than an
-- obviously-missing column.
-- ---------------------------------------------------------------------
do $verify$
declare
  missing text := '';
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'groups'
                   and column_name = 'ministry_id') then
    raise exception 'VERIFY FAILED: groups.ministry_id was not created.';
  end if;

  if not has_column_privilege('authenticated', 'public.groups', 'ministry_id', 'SELECT') then
    missing := missing || 'SELECT ';
  end if;
  if not has_column_privilege('authenticated', 'public.groups', 'ministry_id', 'INSERT') then
    missing := missing || 'INSERT ';
  end if;
  if not has_column_privilege('authenticated', 'public.groups', 'ministry_id', 'UPDATE') then
    missing := missing || 'UPDATE ';
  end if;

  if missing <> '' then
    raise exception 'VERIFY FAILED: authenticated lacks % on groups.ministry_id. The column exists but the group form cannot use it -- grant it explicitly before shipping the client change.', missing;
  end if;

  raise notice 'OK: groups.ministry_id exists and authenticated may select, insert and update it.';
end
$verify$;

select
  'groups.ministry_id' as column_name,
  exists (select 1 from information_schema.columns
          where table_schema = 'public' and table_name = 'groups'
            and column_name = 'ministry_id') as column_exists,
  has_column_privilege('authenticated', 'public.groups', 'ministry_id', 'SELECT') as can_select,
  has_column_privilege('authenticated', 'public.groups', 'ministry_id', 'UPDATE') as can_update,
  exists (select 1 from pg_indexes
          where schemaname = 'public' and indexname = 'idx_groups_ministry_id') as index_exists;
