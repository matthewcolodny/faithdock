-- Run in Supabase SQL Editor.
--
-- Giving an event's venue a column of its own.
--
-- The create-event form has had a "Venue name (optional)" box for a
-- while, but there was nowhere to put it: on save the client joined it
-- to the address with a comma and stored one string.
--
--     location = "Fellowship Hall, 123 Main St, Austin, TX"
--
-- That reads fine and round-trips, but it is lossy the moment anything
-- wants the two apart. Reopening an event for editing put the whole
-- string in the address box and left Venue blank, because there is no
-- reliable way to split it back -- "7127 Bee Cave Road" and "Fellowship
-- Hall" are both just text before the first comma. Guessing would put a
-- street number in the venue field, and nobody re-checks a field they
-- believe the computer filled in.
--
-- So the column, which is the only thing that actually fixes it.

alter table events add column if not exists venue_name text;

comment on column events.venue_name is
  'Optional name of the place within/at the address: "Fellowship Hall", '
  '"Church lawn". Null on rows created before this column existed, and on '
  'calendar imports, where the source gives one unsplittable string.';

-- ---------------------------------------------------------------------
-- Deliberately NOT backfilled.
--
-- Existing rows keep the whole string in `location` with `venue_name`
-- null, and that is the correct outcome rather than a deferred chore. A
-- backfill would have to split on the first comma, which is exactly the
-- guess rejected above -- and it would be applied silently, in bulk, to
-- data nobody is looking at.
--
-- Both shapes therefore coexist on purpose, and the client renders them
-- the same way through one helper:
--
--   legacy row : venue_name null, location "Fellowship Hall, 123 Main St"
--   new row    : venue_name "Fellowship Hall", location "123 Main St"
--
-- Anyone who opens a legacy event and fills the Venue box in converts
-- that one row on save, which is the only moment a human is actually
-- looking at the value and can say whether the split is right.
-- ---------------------------------------------------------------------

notify pgrst, 'reload schema';

do $verify$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_name = 'events' and column_name = 'venue_name'
  ) then
    raise exception 'VERIFY FAILED: events.venue_name was not created.';
  end if;

  -- Nullable on purpose: most events have no venue name, and every row
  -- that existed before this migration has none.
  if (select is_nullable from information_schema.columns
      where table_name = 'events' and column_name = 'venue_name') <> 'YES' then
    raise exception 'VERIFY FAILED: events.venue_name should be nullable.';
  end if;

  if exists (select 1 from events where venue_name is not null) then
    raise exception 'VERIFY FAILED: something backfilled venue_name; it should start empty.';
  end if;

  raise notice 'OK: events.venue_name added, nothing backfilled.';
end
$verify$;
