-- Run in Supabase SQL Editor.
--
-- Rebuilds compute_denomination_tags() around the final taxonomy: 4
-- grouped traditions (Catholic, Nontrinitarian / Other Christian,
-- Orthodox, Protestant -- each with its own short list of specific
-- denominations, 15 total, including Messianic Judaism as a Protestant
-- child) PLUS 2 standalone, childless categories (Christian / General,
-- Nondenominational) that sit outside all the groups -- Nondenominational
-- was originally a child of Protestant but was pulled out to stand on
-- its own, and Christian / General is reinstated here (it existed
-- pre-taxonomy-overhaul but was dropped from the first draft of this
-- migration) specifically so it stays distinguishable from "Other":
-- "Christian / General" means a church owner explicitly chose that
-- label; "Other" means nothing matched at all. Messianic Judaism was
-- originally its own top-level group with a single "Messianic
-- Congregations" child; both are now collapsed into Messianic Judaism
-- itself as a single flat Protestant child (same shape as Baptist,
-- Lutheran, etc). Same function signature as what this replaces (023,
-- most recently re-bodied here), so CREATE OR REPLACE is safe -- no
-- DROP FUNCTION / overload dance needed (that was only required for
-- search_churches in 023, when ITS signature changed).
--
-- Carries forward, from earlier (now-superseded) drafts of this
-- migration: Messianic Judaism is still checked FIRST, before anything
-- else Jewish-shaped or any other pattern (fixes "Beth Simcha Messianic
-- Synagogue" and similar being mislabeled plain Jewish -- there is
-- deliberately no generic "Jewish" bucket in this taxonomy at all) --
-- moving it under Protestant only changed the tag it returns, not its
-- priority in the matching order; word-boundary (\m...\M,
-- Postgres-specific) regex discipline throughout; the Armenian-Apostolic
-- exclusion (an "Apostolic" name pattern used to detect Oneness
-- Pentecostal churches must not swallow "Armenian Apostolic Church",
-- which is Oriental Orthodox); and the assembl(y|ies) of god pattern
-- that matches both singular and plural.

create or replace function compute_denomination_tags(p_denomination text, p_name text)
returns text[]
language plpgsql
immutable
as $$
declare
  hay text := lower(coalesce(p_denomination, '') || ' ' || coalesce(p_name, ''));
  d text := lower(trim(coalesce(p_denomination, '')));
begin
  -- === Protestant: Messianic Judaism (checked first, before anything
  -- Jewish-shaped or any other pattern -- see comment above) ===
  if hay ~* '\mmessianic\M' then
    return array['Protestant', 'Messianic Judaism'];
  end if;

  -- === Nontrinitarian / Other Christian ===
  if hay ~* '(latter-day saint|latter day saint|\mmormon\M|church of jesus christ of latter)' then
    return array['Nontrinitarian / Other Christian', 'Latter-day Saints (Mormon)'];
  end if;
  if hay ~* '(jehovah''?s witness|kingdom hall|\mwatchtower\M)' then
    return array['Nontrinitarian / Other Christian', 'Jehovah''s Witnesses'];
  end if;
  if hay ~* '(oneness pentecostal|united pentecostal church|\mupci\M|oneness apostolic)'
     or (hay ~* '\mapostolic\M' and hay !~* '\marmenian\M') then
    return array['Nontrinitarian / Other Christian', 'Oneness Pentecostal'];
  end if;

  -- === Protestant: Methodist & Wesleyan (before Anglican & Episcopal --
  -- "African Methodist Episcopal" must land here, not there) ===
  if hay ~* '(methodist|wesleyan|\mnazarene\M|african methodist episcopal|\mame church\M)' then
    return array['Protestant', 'Methodist & Wesleyan'];
  end if;

  -- === Protestant: Anglican & Episcopal ===
  if hay ~* '(anglican|episcopal)' then
    return array['Protestant', 'Anglican & Episcopal'];
  end if;

  -- === Protestant: Baptist ===
  if hay ~* '\mbaptist\M' then
    return array['Protestant', 'Baptist'];
  end if;

  -- === Protestant: Lutheran ===
  if hay ~* '\mlutheran\M' then
    return array['Protestant', 'Lutheran'];
  end if;

  -- === Protestant: Presbyterian & Reformed ===
  if hay ~* '(presbyterian|reformed church|christian reformed|\mreformed\M)' then
    return array['Protestant', 'Presbyterian & Reformed'];
  end if;

  -- === Protestant: Pentecostal & Charismatic ===
  if hay ~* '(pentecostal|assembl(y|ies) of god|church of god in christ|\mcogic\M|foursquare|calvary chapel|charismatic)' then
    return array['Protestant', 'Pentecostal & Charismatic'];
  end if;

  -- === Protestant: Anabaptist ===
  if hay ~* '(mennonite|\mamish\M|anabaptist|brethren in christ)' then
    return array['Protestant', 'Anabaptist'];
  end if;

  -- === Protestant: Adventist ===
  if hay ~* '\madventist\M' then
    return array['Protestant', 'Adventist'];
  end if;

  -- === Nondenominational (standalone -- NOT a child of Protestant;
  -- checked last among this Protestant-adjacent cluster since its
  -- patterns are the broadest / most generic) ===
  if hay ~* '(nondenominational|non-denominational|community church|bible church|\mvineyard\M)' then
    return array['Nondenominational'];
  end if;

  -- === Catholic: Eastern Catholic (before bare "Catholic") ===
  if hay ~* '(eastern catholic|byzantine catholic|\mmaronite\M|ukrainian catholic|\mmelkite\M)' then
    return array['Catholic', 'Eastern Catholic'];
  end if;

  -- === Catholic: Roman Catholic ===
  if hay ~* '\mcatholic\M' then
    return array['Catholic', 'Roman Catholic'];
  end if;

  -- === Orthodox: Oriental Orthodox (before bare "Orthodox") ===
  if hay ~* '(\mcoptic\M|armenian apostolic|ethiopian orthodox|\mtewahedo\M|oriental orthodox|syriac orthodox|\mmalankara\M)' then
    return array['Orthodox', 'Oriental Orthodox'];
  end if;

  -- === Orthodox: Eastern Orthodox ===
  if hay ~* '\morthodox\M' then
    return array['Orthodox', 'Eastern Orthodox'];
  end if;

  -- === Stage 2: exact-match compatibility fallback against the OLD
  -- register-church dropdown's fixed values, for the rare row where
  -- p_denomination is one of those exact strings but neither it nor
  -- p_name happened to contain a Stage-1 pattern. "Christian / General"
  -- is ONLY reachable here (no Stage-1 regex for it -- "Christian" as a
  -- bare word is far too common across every other bucket's church
  -- names to safely pattern-match; this label only ever gets applied
  -- when a church owner explicitly chose it from the dropdown, or a
  -- bulk import wrote that exact string). Deliberately does NOT map
  -- 'jewish', 'church of god', 'church of christ', or 'apostolic' --
  -- none of the groups fit them, so they're left untagged (falls to
  -- the "Other" wildcard) rather than forced into a misleading
  -- bucket. ===
  if d = 'christian / general' then
    return array['Christian / General'];
  elsif d = 'non-denominational' then
    return array['Nondenominational'];
  elsif d = 'baptist' then
    return array['Protestant', 'Baptist'];
  elsif d = 'episcopal' then
    return array['Protestant', 'Anglican & Episcopal'];
  elsif d = 'lutheran' then
    return array['Protestant', 'Lutheran'];
  elsif d = 'methodist' then
    return array['Protestant', 'Methodist & Wesleyan'];
  elsif d = 'pentecostal' then
    return array['Protestant', 'Pentecostal & Charismatic'];
  elsif d = 'presbyterian' then
    return array['Protestant', 'Presbyterian & Reformed'];
  elsif d = 'catholic' then
    return array['Catholic', 'Roman Catholic'];
  end if;

  return array[]::text[];
end;
$$;

-- Re-tag every existing church with the new taxonomy.
update churches set denomination_tags = compute_denomination_tags(denomination, name);

notify pgrst, 'reload schema';
