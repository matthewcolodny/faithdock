-- Run in Supabase SQL Editor.
--
-- Descriptor tags for a group, and the one thing that is NOT a tag.
--
-- ---------------------------------------------------------------------
-- WHAT IS A TAG AND WHAT IS A COLUMN
--
-- group_tags holds the things a group can be several of at once: who it
-- is for, what you do there, access, languages. Same shape as
-- churches.church_tags from migration 110 -- one namespaced text[], one
-- GIN index, one overlaps() to answer "does this group match anything
-- ticked".
--
-- meeting_format is a column, not a tag, and that is deliberate. A
-- group is online, in person, or both -- exactly one of three -- and it
-- belongs on the card and in a reliable filter. A tag would let a group
-- claim two contradictory things, or none, and would have no default.
--
-- Three more things were considered as tags and rejected for the same
-- reason, because each already has a column that would then have a
-- second answer able to disagree with it:
--
--   "members only"    -> groups.visibility ('public' | 'members')
--   "open to anyone"  -> groups.join_method
--   when it meets     -> meeting_day_of_week / recurrence / time
--
-- Languages are shared with the church vocabulary in the client: the
-- same lang: slugs, one list, so the two cannot drift. They are still
-- separate columns on separate tables.

do $$
begin
  if not exists (select 1 from information_schema.tables
                 where table_schema = 'public' and table_name = 'groups') then
    raise exception 'ABORT: no groups table.';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'groups' and column_name = 'visibility') then
    raise exception 'ABORT: groups.visibility is missing -- members-only is meant to come from it rather than from a tag.';
  end if;
end $$;

alter table groups add column if not exists group_tags text[] not null default '{}';

-- Overlap queries only. GIN is what makes && and @> use an index.
create index if not exists groups_group_tags_idx on groups using gin (group_tags);

-- Nullable on purpose: a group that predates this has not answered the
-- question, and "in person" is a guess, not an answer. The UI treats
-- null as "not said" and does not filter it out.
alter table groups add column if not exists meeting_format text;

do $$
begin
  if not exists (select 1 from information_schema.constraint_column_usage
                 where table_schema = 'public' and table_name = 'groups'
                   and constraint_name = 'groups_meeting_format_check') then
    alter table groups add constraint groups_meeting_format_check
      check (meeting_format is null or meeting_format in ('in_person', 'online', 'hybrid'));
  end if;
end $$;

-- Readable by anyone who can read a group, writable through the row
-- policies groups already has -- a leader editing their own. No new
-- policy: these columns ride on the table's.
grant select (group_tags, meeting_format) on groups to anon, authenticated;
grant update (group_tags, meeting_format) on groups to authenticated;

-- ---------------------------------------------------------------------
do $$
declare
  has_tags   boolean;
  has_format boolean;
  has_idx    boolean;
  n_rows     integer;
begin
  select exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='groups' and column_name='group_tags') into has_tags;
  select exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='groups' and column_name='meeting_format') into has_format;
  select exists (select 1 from pg_indexes
                 where schemaname='public' and indexname='groups_group_tags_idx') into has_idx;

  if not has_tags   then raise exception 'VERIFY FAILED: group_tags was not added.'; end if;
  if not has_format then raise exception 'VERIFY FAILED: meeting_format was not added.'; end if;
  if not has_idx    then raise exception 'VERIFY FAILED: the GIN index was not created.'; end if;

  select count(*) into n_rows from groups;
  raise notice 'OK. group_tags and meeting_format on % groups, all empty until a leader sets them.', n_rows;
  raise notice 'Nothing reads these yet beyond the editor -- the browse filter stays off until groups have tags, the same way By Category did.';
end $$;
