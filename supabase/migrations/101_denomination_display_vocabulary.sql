-- Run in the Supabase SQL Editor.
--
-- Westlake Hills Presbyterian Church was labelled "Presbyterian &
-- Reformed". Nothing decided that about the church: it is the name of a
-- FILTER CATEGORY that migration 100 wrote into a DISPLAY column.
--
-- THERE ARE TWO VOCABULARIES IN THIS APP, and 100 used the wrong one.
--
--   denomination_tags  -- derived, drives the Tradition filter. Its
--                         leaves are deliberately combined categories:
--                         "Presbyterian & Reformed", "Methodist &
--                         Wesleyan", "Anglican & Episcopal",
--                         "Pentecostal & Charismatic". They read
--                         correctly as a checkbox covering a family.
--
--   denomination       -- the plain text a person reads, and the field
--                         a church owner edits. Its vocabulary is the
--                         dropdown in the church form: Baptist,
--                         Episcopal, Lutheran, Methodist, Pentecostal,
--                         Presbyterian, Anglican, Adventist, Catholic,
--                         Orthodox, Church of God, Church of Christ,
--                         Apostolic, Nazarene, Non-denominational,
--                         Protestant, Christian / General, Other.
--
-- A category is right on a checkbox and wrong on a church. This maps
-- the tag to the dropbox value before writing it, in the trigger and in
-- a backfill of what 100 already wrote.
--
-- A SECOND THING THIS CORRECTS. The rows carrying "Methodist",
-- "Presbyterian", "Episcopal", "Church of God" and the rest -- 133 of
-- them from the original San Antonio import -- were reported as
-- non-canonical. They were not. They are exactly the dropdown
-- vocabulary and were right all along; they were compared against the
-- tag list, which is the wrong list for this column. Nothing here
-- touches them.
--
-- Anything with no sensible dropdown equivalent -- Messianic Judaism,
-- Jehovah's Witnesses, Latter-day Saints, Anabaptist, Nontrinitarian /
-- Other Christian -- maps to "Other", which is a real dropdown value.
-- The TAG keeps the specific name, so filtering still finds them; only
-- the displayed word is generalised.

-- ---------------------------------------------------------------------
-- Preflight
-- ---------------------------------------------------------------------
do $preflight$
begin
  if not exists (select 1 from pg_proc where proname = 'churches_set_denomination_tags') then
    raise exception 'ABORT: the denomination trigger does not exist. Run 023 and 100 first.';
  end if;
end
$preflight$;

-- ---------------------------------------------------------------------
-- Tag -> what a person should read
-- ---------------------------------------------------------------------
create or replace function denomination_display_for_tag(p_tag text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case p_tag
    -- Combined filter categories collapse to the single word the
    -- dropdown offers. "Anglican & Episcopal" becomes Episcopal rather
    -- than Anglican because in Texas the Episcopal Church is the
    -- overwhelmingly common case, and both are in the dropdown so an
    -- owner can correct it in one click.
    when 'Presbyterian & Reformed'          then 'Presbyterian'
    when 'Methodist & Wesleyan'             then 'Methodist'
    when 'Anglican & Episcopal'             then 'Episcopal'
    when 'Pentecostal & Charismatic'        then 'Pentecostal'
    when 'Oneness Pentecostal'              then 'Apostolic'
    -- Spelling: the tag has no hyphen, the dropdown does.
    when 'Nondenominational'                then 'Non-denominational'
    when 'Roman Catholic'                   then 'Catholic'
    when 'Eastern Catholic'                 then 'Catholic'
    when 'Eastern Orthodox'                 then 'Orthodox'
    when 'Oriental Orthodox'                then 'Orthodox'
    -- No dropdown equivalent. The TAG keeps the specific name, so the
    -- Tradition filter still finds these; only the label generalises.
    when 'Messianic Judaism'                then 'Other'
    when 'Jehovah''s Witnesses'             then 'Other'
    when 'Latter-day Saints (Mormon)'       then 'Other'
    when 'Anabaptist'                       then 'Other'
    when 'Nontrinitarian / Other Christian' then 'Other'
    -- Baptist, Lutheran, Catholic, Orthodox, Adventist, Protestant and
    -- Christian / General are identical in both vocabularies.
    else p_tag
  end;
$$;

-- ---------------------------------------------------------------------
-- The trigger writes the display value, not the tag
-- ---------------------------------------------------------------------
create or replace function churches_set_denomination_tags()
returns trigger
language plpgsql
as $$
declare
  v_tags text[];
begin
  v_tags := compute_denomination_tags(new.denomination, new.name);
  new.denomination_tags := v_tags;

  if nullif(trim(coalesce(new.denomination, '')), '') is null
     and array_length(v_tags, 1) is not null then
    new.denomination := denomination_display_for_tag(v_tags[array_length(v_tags, 1)]);
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Repair what migration 100 wrote
-- ---------------------------------------------------------------------
-- Only rows whose denomination is literally a tag name it should never
-- have been given. A value somebody typed, and the original import's
-- own vocabulary, are both left alone.
update churches
   set denomination = denomination_display_for_tag(denomination)
 where denomination in (
   'Presbyterian & Reformed', 'Methodist & Wesleyan', 'Anglican & Episcopal',
   'Pentecostal & Charismatic', 'Oneness Pentecostal', 'Nondenominational',
   'Roman Catholic', 'Eastern Catholic', 'Eastern Orthodox', 'Oriental Orthodox',
   'Messianic Judaism', 'Jehovah''s Witnesses', 'Latter-day Saints (Mormon)',
   'Anabaptist', 'Nontrinitarian / Other Christian'
 );

-- ---------------------------------------------------------------------
-- Verify
-- ---------------------------------------------------------------------
-- 1. No displayed denomination is a combined filter category any more.
do $verify$
declare
  n integer;
begin
  select count(*) into n from churches
   where denomination in ('Presbyterian & Reformed', 'Methodist & Wesleyan',
     'Anglican & Episcopal', 'Pentecostal & Charismatic', 'Nondenominational',
     'Nontrinitarian / Other Christian');
  if n > 0 then
    raise exception 'INVARIANT FAILED: % rows still display a filter category', n;
  end if;
  raise notice 'OK: no church displays a combined filter category.';
end
$verify$;

-- 2. Westlake Hills. Expect denomination "Presbyterian", tags still
--    {Protestant, "Presbyterian & Reformed"} -- the filter is unchanged,
--    only the label.
select name, denomination, denomination_tags
  from churches
 where name ilike '%westlake hills presbyterian%'
 limit 5;

-- 3. The whole directory again.
select coalesce(nullif(trim(denomination), ''), '(blank)') as denomination,
       count(*) as churches
  from churches
 group by 1
 order by count(*) desc
 limit 25;
