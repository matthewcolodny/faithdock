-- Run in Supabase SQL Editor.
--
-- Closes 3 real name-matching gaps in compute_denomination_tags(),
-- each found via a live, reported example that was showing up
-- untagged (falling through to "Other") or mislabeled on its card:
--
--   1. "Iglesia Luterana San Pablo" -- Spanish "Luterana"/"Luterano"
--      wasn't recognized at all; only the English "Lutheran" was.
--   2. "Iglesia Bautista ..." (6 live rows) -- same gap for Spanish
--      "Bautista" vs. English "Baptist".
--   3. "Debre Sahle St Michael Eritrean Ort Hodox Tewahdo Church" --
--      an Ethiopian/Eritrean Orthodox Tewahedo congregation that
--      matched neither the "Tewahedo" spelling already in the Oriental
--      Orthodox pattern (this one is spelled "Tewahdo", no middle "e",
--      a genuinely common alternate transliteration) nor "Orthodox"
--      itself (this row's own name has it split across two words,
--      "Ort Hodox" -- almost certainly an OCR/import artifact, not
--      something worth writing a one-off name-correction for). Added
--      "Debre" as its own signal instead of chasing more spelling
--      variants -- it's a Ge'ez/Amharic word meaning "mountain" or
--      "monastery" that prefixes the overwhelming majority of
--      Ethiopian/Eritrean Orthodox church names (Debre Selam, Debre
--      Genet, etc.), so on its own it's a reliable, low-false-positive
--      signal regardless of how the rest of the name is spelled.
--
-- Same function signature as migration 026 (which this re-bodies),
-- so CREATE OR REPLACE is safe -- no DROP FUNCTION needed.
--
-- Also widens the "hide standalone ministry orgs" pattern from
-- migration 025 to catch "Ministrys" (misspelled, no apostrophe) --
-- found live as "Issues Of Life Ministrys", which the original
-- \mministr(y|ies)\M pattern doesn't match: \M is a right-word-
-- boundary anchor, and there's no word boundary between the "y" and
-- the trailing "s" in "Ministrys" (both are word characters), so the
-- pattern requires an exact "ministry" or "ministries" token and
-- silently misses this misspelling. This UPDATE only affects rows
-- migration 025's own version didn't already catch -- rerunning it is
-- safe and idempotent regardless of whether 025 has been run yet.

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
  -- Jewish-shaped or any other pattern -- see migration 026's header) ===
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

  -- === Protestant: Baptist (English + Spanish "Bautista" -- gap found
  -- live via 6 "Iglesia Bautista ..." rows, all untagged) ===
  if hay ~* '(\mbaptist\M|\mbautista\M)' then
    return array['Protestant', 'Baptist'];
  end if;

  -- === Protestant: Lutheran (English + Spanish "Luterana"/"Luterano" --
  -- gap found live via "Iglesia Luterana San Pablo", untagged) ===
  if hay ~* '(\mlutheran\M|\mluteran[oa]s?\M)' then
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

  -- === Orthodox: Oriental Orthodox (before bare "Orthodox") -- added
  -- "Tewahdo" (no middle "e", a common alternate transliteration of
  -- "Tewahedo") and "Debre" (see migration header) ===
  if hay ~* '(\mcoptic\M|armenian apostolic|ethiopian orthodox|\mtewahedo\M|\mtewahdo\M|oriental orthodox|syriac orthodox|\mmalankara\M|\mdebre\M)' then
    return array['Orthodox', 'Oriental Orthodox'];
  end if;

  -- === Orthodox: Eastern Orthodox ===
  if hay ~* '\morthodox\M' then
    return array['Orthodox', 'Eastern Orthodox'];
  end if;

  -- === Stage 2: exact-match compatibility fallback against the OLD
  -- register-church dropdown's fixed values -- unchanged from migration
  -- 026, see its header for why "Christian / General" is only
  -- reachable here and why 'jewish'/'church of god'/'church of
  -- christ'/'apostolic' are deliberately left unmapped. ===
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

-- Re-tag every existing church under the widened patterns above.
update churches set denomination_tags = compute_denomination_tags(denomination, name);

-- Widened follow-up to migration 025's own "hide standalone ministry
-- orgs" UPDATE -- see header. Safe to run regardless of whether 025
-- has run yet: idempotent, and scoped to is_hidden = false so it only
-- ever touches rows not already hidden.
update churches
set is_hidden = true
where is_hidden = false
  and name ~* '\mministr(y|ies|ys)\M';

notify pgrst, 'reload schema';
