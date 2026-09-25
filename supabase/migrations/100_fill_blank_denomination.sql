-- Run in the Supabase SQL Editor.
--
-- "San Antonio Assembly Hall of Jehovahs Witnesses" showed no
-- denomination. So did "Triumphant Lutheran Church". Both say what they
-- are in their own names, and the database already knew:
--
--   compute_denomination_tags('', 'San Antonio Assembly Hall of Jehovahs Witnesses')
--     -> {"Nontrinitarian / Other Christian","Jehovah's Witnesses"}
--   compute_denomination_tags('', 'Triumphant Lutheran Church')
--     -> {"Protestant","Lutheran"}
--
-- THE TWO COLUMNS ARE NOT THE SAME THING, which is the whole bug.
-- `denomination_tags` is derived by a trigger from the name and drives
-- filtering; `denomination` is the plain text a person sees, and
-- nothing has ever filled it in except a human typing it or a CSV
-- carrying it. Bulk imports leave it blank, so a church whose tradition
-- is obvious from its own name displayed as nothing at all.
--
-- WHY NOT A SECOND KEYWORD LIST. The obvious fix is to work the
-- denomination out in the import script. That would put a copy of the
-- patterns in 023/026/027 into a Node file, and two copies of a
-- twenty-branch rule drift -- the next pattern added to
-- compute_denomination_tags would silently not apply to imports. This
-- takes the answer FROM that function instead, so there stays exactly
-- one place that decides what a name means.
--
-- The last element, not the first: tags are {group, specific} --
-- {'Protestant','Lutheran'} -- and "Lutheran" is what a person wants to
-- read. Standalone tags like {'Nondenominational'} have one element and
-- the same expression returns it.
--
-- ONLY BLANKS ARE TOUCHED. A denomination somebody typed is never
-- overwritten, here or in the trigger.

-- ---------------------------------------------------------------------
-- Preflight
-- ---------------------------------------------------------------------
do $preflight$
begin
  if not exists (select 1 from pg_proc where proname = 'compute_denomination_tags') then
    raise exception 'ABORT: compute_denomination_tags() does not exist. Run 023_denomination_tags.sql first.';
  end if;
  if not exists (select 1 from pg_proc where proname = 'churches_set_denomination_tags') then
    raise exception 'ABORT: the denomination_tags trigger function does not exist. Run 023_denomination_tags.sql first.';
  end if;
end
$preflight$;

-- ---------------------------------------------------------------------
-- 1. The trigger also fills the blank, so imports stop needing this
-- ---------------------------------------------------------------------
-- Same trigger, same firing conditions -- one extra line. Doing it here
-- rather than in admin_import_churches covers every path that will ever
-- write a church: the importer, the register-church form, an admin
-- edit, anything added later.
create or replace function churches_set_denomination_tags()
returns trigger
language plpgsql
as $$
declare
  v_tags text[];
begin
  v_tags := compute_denomination_tags(new.denomination, new.name);
  new.denomination_tags := v_tags;

  -- Blank only. nullif(trim(...)) catches '' and '   ' as well as NULL.
  -- A church that genuinely is not any of these gets an empty tag array
  -- and is left blank, rather than being labelled something wrong.
  if nullif(trim(coalesce(new.denomination, '')), '') is null
     and array_length(v_tags, 1) is not null then
    new.denomination := v_tags[array_length(v_tags, 1)];
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Backfill what is already there
-- ---------------------------------------------------------------------
-- denomination_tags is already correct on every row (the trigger has
-- been maintaining it since 023), so this reads the tags rather than
-- recomputing them.
update churches
   set denomination = denomination_tags[array_length(denomination_tags, 1)]
 where nullif(trim(coalesce(denomination, '')), '') is null
   and array_length(denomination_tags, 1) is not null;

-- ---------------------------------------------------------------------
-- Verify
-- ---------------------------------------------------------------------
-- 1. Nothing is left blank that the tags could have named.
do $verify$
declare
  n integer;
begin
  select count(*) into n
    from churches
   where nullif(trim(coalesce(denomination, '')), '') is null
     and array_length(denomination_tags, 1) is not null;
  if n > 0 then
    raise exception 'INVARIANT FAILED: % rows still have a blank denomination despite having tags', n;
  end if;
  raise notice 'OK: no row has tags but a blank denomination.';
end
$verify$;

-- 2. The two rows that prompted this. Expect "Jehovah's Witnesses" and
--    "Lutheran".
select name, denomination, denomination_tags
  from churches
 where name ilike '%jehovah%witness%'
    or name ilike '%triumphant lutheran%'
 order by name
 limit 10;

-- 3. What the directory now shows, most common first. Read it: a label
--    that looks wrong here is a pattern to fix in
--    compute_denomination_tags, not a row to edit by hand.
select coalesce(nullif(trim(denomination), ''), '(still blank)') as denomination,
       count(*) as churches
  from churches
 group by 1
 order by count(*) desc
 limit 20;
