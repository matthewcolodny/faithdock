-- Run in Supabase SQL Editor. Requires 107_denomination_case.sql.
--
-- Merges the denomination labels that mean the same thing, so the
-- filter stops splitting one group across two names.
--
-- ---------------------------------------------------------------------
-- WHERE THE SPLITS CAME FROM
--
-- Every one of these is a seam between two imports. The older San
-- Antonio data uses one vocabulary and the faithstreet prep another,
-- and each label below exists on one side of that seam and not the
-- other. It shows most clearly with Catholic: 1,163 rows say "Catholic"
-- and 61 say "Roman Catholic", and all 61 are in San Antonio, which is
-- why the map appeared to claim Roman Catholics live nowhere else.
--
-- ---------------------------------------------------------------------
-- WHAT IS MERGED, AND WHAT IS NOT
--
-- Pure synonyms and spellings -- nothing is lost:
--
--   Roman Catholic                    -> Catholic
--   Southern Baptist Convention       -> Southern Baptist
--   Seventh Day Adventist             -> Seventh-day Adventist
--   Nazarene                          -> Church of the Nazarene
--
-- Specific bodies folded into their family. These DO lose a
-- distinction, and are merged because tools/prep-faithstreet.js already
-- folds the same bodies the same way -- every row imported since does
-- it, so leaving these three unmerged keeps a difference that reflects
-- which file a church arrived in rather than anything about the church:
--
--   Evangelical Lutheran in America   -> Lutheran            (10 rows)
--   African Methodist Episcopal       -> Methodist           (7 rows)
--   Baptist Bible Fellowship Intl     -> Baptist             (6 rows)
--
-- Deliberately left alone:
--
--   Adventist (23)        broader than Seventh-day Adventist; the prep
--                         puts Advent Christian here, a different body.
--   Restorationist (7)    a real family, not a variant of anything here.
--   Other (8)             means "not listed", which is information.
--   Protestant / Evangelical (7) vs Evangelical (113) -- these read like
--                         the same thing, but the first is a filter
--                         CATEGORY that leaked into the display column
--                         and may want removing rather than merging.
--   '' (2,658)            no denomination at all. Not a naming problem;
--                         see the notice at the bottom.

do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                 where ns.nspname = 'public' and p.proname = 'fd_norm_denom') then
    raise exception 'ABORT: fd_norm_denom is missing. Run 107_denomination_case.sql first.';
  end if;
end $$;

do $$
declare
  pair   record;
  moved  integer;
  total  integer := 0;
  -- from (normalised, so it catches every capitalisation) -> to (as written)
  pairs constant text[][] := array[
    ['roman catholic',                  'Catholic'],
    ['southern baptist convention',     'Southern Baptist'],
    ['seventh day adventist',           'Seventh-day Adventist'],
    ['nazarene',                        'Church of the Nazarene'],
    ['evangelical lutheran in america', 'Lutheran'],
    ['african methodist episcopal',     'Methodist'],
    ['baptist bible fellowship international', 'Baptist']
  ];
  i integer;
begin
  for i in 1 .. array_length(pairs, 1) loop
    update churches
       set denomination = pairs[i][2]
     where fd_norm_denom(denomination) = pairs[i][1]
       -- Skip rows already correct, so a second run reports zero rather
       -- than rewriting the same rows again.
       and denomination is distinct from pairs[i][2];
    get diagnostics moved = row_count;
    total := total + moved;
    if moved > 0 then
      raise notice '  % -> %  (% churches)', pairs[i][1], pairs[i][2], moved;
    end if;
  end loop;
  raise notice '% churches relabelled.', total;
end $$;

-- ---------------------------------------------------------------------
do $$
declare
  leftovers text;
  n_blank   integer;
  n_names   integer;
begin
  -- None of the merged names should survive.
  select string_agg(distinct btrim(c.denomination), ', ') into leftovers
    from churches c
   where fd_norm_denom(c.denomination) in (
     'roman catholic', 'southern baptist convention', 'seventh day adventist',
     'nazarene', 'evangelical lutheran in america', 'african methodist episcopal',
     'baptist bible fellowship international');
  if leftovers is not null then
    raise exception 'VERIFY FAILED: these should have been merged and were not: %', leftovers;
  end if;

  select count(*) into n_names from (
    select fd_norm_denom(c.denomination) from churches c
     where c.denomination is not null and btrim(c.denomination) <> '' group by 1) a;
  select count(*) into n_blank from churches
   where denomination is null or btrim(denomination) = '';

  raise notice 'OK. % distinct denominations left.', n_names;
  raise notice 'Separately: % churches have no denomination at all -- the largest group in the data, and nothing here touches it.', n_blank;
end $$;
