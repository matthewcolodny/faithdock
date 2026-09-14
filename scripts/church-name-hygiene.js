#!/usr/bin/env node
'use strict';

/*
 * church-name-hygiene.js
 * -----------------------
 * Four unrelated live-data cleanups requested after spotting bad
 * examples in the Churches directory ("El Camino Christian Church Tx",
 * "Life Change Church of San Antonio Tx a Domestic Nonprofit",
 * "360 Inner City Church - San Antonio Tx", "New Braunfels Central Tx
 * Foursquare Church", "Crossbridge Community Church Of San Antonio",
 * "San Antonio Church of Christ At Viewcrest"), bundled into one scan
 * since they all read the same live `name` column:
 *
 *   1. TX casing    -- "Tx" -> "TX". Delegated entirely to
 *      acronym-exceptions.js's applyAcronymCasing() now that 'TX' has
 *      been added to ACRONYM_EXCEPTIONS there -- not reimplemented here.
 *   2. Nonprofit hide -- a name that says "nonprofit" / "non-profit" /
 *      "non profit" (e.g. "...a Domestic Nonprofit") is an IRS-extract
 *      artifact bleeding into the display name, not a real congregation
 *      name. These get HIDDEN (churches.is_hidden = true, the same
 *      column search_churches/search_events already filter on -- see
 *      migrations 018/019), not deleted -- reversible, and consistent
 *      with how the 5 known test churches are already excluded.
 *   3. Locator-suffix strip -- a trailing " - <City[, City...]>, TX"-
 *      style suffix (e.g. "360 Inner City Church - San Antonio Tx") is
 *      also import-artifact cruft and gets stripped back to the bare
 *      church name.
 *   4. Minor-word casing -- the same title-casing pass that broke
 *      acronyms ("Satx") also over-capitalized short connector words
 *      that should stay lowercase mid-name: "Church Of San Antonio" ->
 *      "Church of San Antonio", "Church of Christ At Viewcrest" ->
 *      "Church of Christ at Viewcrest". MINOR_WORDS is a flat array of
 *      exact-case strings (capitalized, the wrong form) -- same
 *      one-line-to-extend convention as ACRONYM_EXCEPTIONS, just the
 *      opposite direction (force lowercase instead of upper). Only
 *      applied when the word isn't the first word of the name, so a
 *      name that's genuinely supposed to start with "At" or "Of" is
 *      left alone.
 *
 * All four are read-only against Supabase, same as acronym-exceptions.js
 * -- this only ever WRITES a .sql file for a human to review and run by
 * hand in the Supabase SQL Editor.
 *
 * IMPORTANT -- review before running the generated SQL:
 *   The locator-suffix regex can't tell a real city name from a ministry
 *   descriptor after the dash (e.g. a hypothetical "Some Church -
 *   Reaching Katy Tx" would strip to "Some Church", which may or may not
 *   be what's wanted). Every suffix-strip line is commented with the
 *   before/after name specifically so this can be eyeballed -- read
 *   those before running, don't just pipe the file straight into the SQL
 *   editor. Separately, a name that (after minor-word casing) still ENDS
 *   in "of"/"at" with nothing after it (e.g. "Christian Fellowship
 *   Church Of") looks like an import that's missing its trailing city --
 *   that's a different, bigger problem than casing and isn't something
 *   this script can safely reconstruct, so those rows are only re-cased
 *   here and additionally called out in their own SQL comment section
 *   for a human to go find the actual full name for.
 *
 * A name flagged as "nonprofit" is hidden as-is and is NOT also run
 * through the casing/suffix fixes below -- it's about to disappear from
 * the directory, so there's nothing to gain from also tidying its name.
 *
 * Usage:
 *   node scripts/church-name-hygiene.js [--out=<path>] [--selftest]
 *
 *   --selftest   offline checks only, no network access
 *   --out=<path> where to write the SQL file (default:
 *                church_name_hygiene_fixes.sql in the cwd)
 */

const fs = require('fs');
const path = require('path');
const { applyAcronymCasing, ACRONYM_EXCEPTIONS } = require('./acronym-exceptions');

// ---------------------------------------------------------------------
// Detection / transform rules
// ---------------------------------------------------------------------

// Whole-word, case-insensitive, matches Nonprofit / Non-Profit / Non
// Profit / (plural) Nonprofits -- same word-boundary discipline as every
// other keyword check in this repo (see filter-churches.js's header for
// why plain substring checks are unsafe here).
const NONPROFIT_RE = /\bnon[-\s]?profit(s)?\b/i;
function isNonprofitName(name) {
  return !!name && NONPROFIT_RE.test(name);
}

// Trailing " - <Capitalized Word(s)>, TX"-style locator suffix, e.g.:
//   "360 Inner City Church - San Antonio Tx"  ->  "360 Inner City Church"
//   "Some Church - New Braunfels, TX"          ->  "Some Church"
// Deliberately anchored to the END of the string and requires a dash --
// this is why "El Camino Christian Church Tx" and "New Braunfels Central
// Tx Foursquare Church" (no dash) are correctly left untouched: they read
// as the city name being folded INTO the church name, not a bolted-on
// locator suffix.
const LOCATOR_SUFFIX_RE = /\s*[-–—]\s*[A-Z][A-Za-z.'’]*(?:\s+[A-Z][A-Za-z.'’]*)*,?\s*T[Xx]\.?\s*$/;
function stripLocatorSuffix(name) {
  if (!name) return name;
  return name.replace(LOCATOR_SUFFIX_RE, '').trim();
}

// Short connector words a title-caser wrongly capitalized mid-name.
// Exact-case strings (the wrong, capitalized form) -- extending this for
// a newly-spotted word is a one-line edit, same convention as
// ACRONYM_EXCEPTIONS, just the opposite direction (force lowercase
// instead of upper).
const MINOR_WORDS = ['Of', 'At'];
function fixMinorWordCasing(name) {
  if (!name) return name;
  let result = name;
  for (const word of MINOR_WORDS) {
    const re = new RegExp('\\b' + word + '\\b', 'g'); // exact-case match, not /i
    result = result.replace(re, function (match, offset) {
      // Leave the first word of the name alone -- a name that genuinely
      // starts with "At"/"Of" should keep its capital.
      return offset === 0 ? match : word.toLowerCase();
    });
  }
  return result;
}

// True when a name ends in one of MINOR_WORDS with nothing after it
// (checked against the ORIGINAL name, before any fix is applied) --
// e.g. "Christian Fellowship Church Of". That's not a casing problem,
// it's a truncated import missing its trailing city/descriptor, and
// this script can't safely guess what belongs there -- it just flags it
// for a human to track down separately.
const TRAILING_MINOR_WORD_RE = new RegExp('\\b(' + MINOR_WORDS.join('|') + ')\\s*$');
function looksTruncated(name) {
  return !!name && TRAILING_MINOR_WORD_RE.test(name);
}

function selftest() {
  let failed = 0;
  function eq(actual, expected, label) {
    if (actual !== expected) {
      failed++;
      process.stderr.write('FAIL: ' + label + ' -- expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual) + '\n');
    }
  }

  // --- nonprofit detection ---
  eq(isNonprofitName('Life Change Church of San Antonio Tx a Domestic Nonprofit'), true, 'catches "Nonprofit"');
  eq(isNonprofitName('Some Org, A Non-Profit Corporation'), true, 'catches "Non-Profit"');
  eq(isNonprofitName('Some Org Non Profit Inc'), true, 'catches "Non Profit"');
  eq(isNonprofitName('Nonprofits United Church'), true, 'catches plural "Nonprofits"');
  eq(isNonprofitName('El Camino Christian Church Tx'), false, 'ordinary name -- no false positive');
  eq(isNonprofitName('360 Inner City Church - San Antonio Tx'), false, 'locator-suffixed name -- no false positive');
  eq(isNonprofitName(''), false, 'empty string -- false');
  eq(isNonprofitName(null), false, 'null -- false, does not throw');

  // --- locator-suffix stripping ---
  eq(stripLocatorSuffix('360 Inner City Church - San Antonio Tx'), '360 Inner City Church', 'strips "- San Antonio Tx"');
  eq(stripLocatorSuffix('Some Church - New Braunfels, TX'), 'Some Church', 'strips ", TX" with comma');
  eq(stripLocatorSuffix('Some Church - Austin Tx.'), 'Some Church', 'strips trailing period after Tx');
  eq(stripLocatorSuffix('Some Church – Houston Tx'), 'Some Church', 'strips en-dash variant');
  eq(stripLocatorSuffix('El Camino Christian Church Tx'), 'El Camino Christian Church Tx', 'no dash -- left untouched');
  eq(stripLocatorSuffix('New Braunfels Central Tx Foursquare Church'), 'New Braunfels Central Tx Foursquare Church', 'city folded into name, no dash -- left untouched');
  eq(stripLocatorSuffix('Life Change Church of San Antonio Tx a Domestic Nonprofit'), 'Life Change Church of San Antonio Tx a Domestic Nonprofit', 'nonprofit name has no trailing dash -- left untouched (also excluded upstream by hide check)');
  eq(stripLocatorSuffix(''), '', 'empty string -- no-op');
  eq(stripLocatorSuffix(null), null, 'null -- no-op, does not throw');
  // Known ambiguous case -- documented above, not asserted either way here.
  // "Some Church - Reaching Katy Tx" -> "Some Church" (flag for human review).

  // --- minor-word casing ---
  eq(fixMinorWordCasing('Crossbridge Community Church Of San Antonio'), 'Crossbridge Community Church of San Antonio', 'mid-name "Of" gets lowercased');
  eq(fixMinorWordCasing('San Antonio Church of Christ At Viewcrest'), 'San Antonio Church of Christ at Viewcrest', 'mid-name "At" gets lowercased, already-lowercase "of" left alone');
  eq(fixMinorWordCasing('Genesis Church Of San Antonio'), 'Genesis Church of San Antonio', 'mid-name "Of" gets lowercased');
  eq(fixMinorWordCasing('At Calvary Chapel'), 'At Calvary Chapel', 'leading "At" (first word) left alone');
  eq(fixMinorWordCasing('Of First Importance Ministries'), 'Of First Importance Ministries', 'leading "Of" (first word) left alone');
  eq(fixMinorWordCasing('Latin American Fellowship'), 'Latin American Fellowship', '"At"/"Of" do not fire inside other words (word-boundary)');
  eq(fixMinorWordCasing('Christian Fellowship Church Of'), 'Christian Fellowship Church of', 'trailing "Of" still gets lowercased even though the name looks truncated');
  eq(fixMinorWordCasing(''), '', 'empty string -- no-op');
  eq(fixMinorWordCasing(null), null, 'null -- no-op, does not throw');

  // --- truncation flag (informational only, not auto-fixed) ---
  eq(looksTruncated('Christian Fellowship Church Of'), true, 'flags name ending in "Of" with nothing after');
  eq(looksTruncated('San Antonio Church of Christ At Viewcrest'), false, '"At Viewcrest" has a word after -- not truncated');
  eq(looksTruncated('Crossbridge Community Church Of San Antonio'), false, '"Of San Antonio" has a word after -- not truncated');
  eq(looksTruncated(''), false, 'empty string -- false');
  eq(looksTruncated(null), false, 'null -- false, does not throw');

  process.stderr.write(failed ? '\n' + failed + ' check(s) FAILED\n' : '\nall checks passed\n');
  process.exit(failed ? 1 : 0);
}

// ---------------------------------------------------------------------
// CLI: scan the live database and generate a correction .sql file.
// ---------------------------------------------------------------------

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://doerahlrdknedoknawex.supabase.co';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'sb_publishable_zdoYSKnhvJyEdhhbCV_CAw_owRZ3f-V';

async function fetchAllChurches() {
  const pageSize = 1000;
  let all = [];
  for (let offset = 0; ; offset += pageSize) {
    const url = SUPABASE_URL + '/rest/v1/churches?select=id,name,is_hidden&order=id&offset=' + offset + '&limit=' + pageSize;
    const res = await fetch(url, {
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: 'Bearer ' + SUPABASE_ANON_KEY }
    });
    if (!res.ok) throw new Error('Supabase fetch failed: ' + res.status + ' ' + (await res.text()));
    const page = await res.json();
    all = all.concat(page);
    if (page.length < pageSize) break;
  }
  return all;
}

function sqlEscape(s) {
  return s.replace(/'/g, "''");
}

async function runScan(outPath) {
  process.stderr.write('Fetching live church names...\n');
  const rows = await fetchAllChurches();
  process.stderr.write('Checking ' + rows.length + ' names (nonprofit-hide, locator-suffix, TX casing via ' + ACRONYM_EXCEPTIONS.length + ' known acronyms)...\n');

  const nonprofitHides = [];
  const nameFixes = [];
  const truncatedFlags = [];

  rows.forEach(function (r) {
    if (isNonprofitName(r.name)) {
      if (!r.is_hidden) nonprofitHides.push(r);
      return; // don't also tidy a name that's about to be hidden
    }
    if (looksTruncated(r.name)) truncatedFlags.push(r);
    const stripped = stripLocatorSuffix(r.name);
    const minorFixed = fixMinorWordCasing(stripped);
    const fixed = applyAcronymCasing(minorFixed);
    if (fixed !== r.name) nameFixes.push({ id: r.id, name: r.name, fixed: fixed });
  });

  const lines = [];
  lines.push('-- Church name/visibility hygiene fixes -- generated by');
  lines.push('-- scripts/church-name-hygiene.js against the live database.');
  lines.push('-- Review every statement below before running any of it.');
  lines.push('');

  lines.push('-- ===================================================================');
  lines.push('-- 1) HIDE: names indicating an IRS-extract "nonprofit" artifact, not a');
  lines.push('--    real congregation display name. Reversible (is_hidden = true),');
  lines.push('--    same column search_churches/search_events already filter on.');
  lines.push('-- ===================================================================');
  lines.push('');
  if (nonprofitHides.length === 0) {
    lines.push('-- (none found)');
    lines.push('');
  } else {
    nonprofitHides.forEach(function (r) {
      lines.push('-- ' + r.name);
      lines.push("UPDATE churches SET is_hidden = true WHERE id = '" + r.id + "' AND name = '" + sqlEscape(r.name) + "';");
      lines.push('');
    });
  }

  lines.push('-- ===================================================================');
  lines.push('-- 2) FIX: locator-suffix strip + TX/acronym casing. REVIEW EACH ONE --');
  lines.push('--    the suffix regex can\'t always tell a real city from a ministry');
  lines.push('--    descriptor after a dash. Delete any line that looks wrong before');
  lines.push('--    running this file.');
  lines.push('-- ===================================================================');
  lines.push('');
  if (nameFixes.length === 0) {
    lines.push('-- (none found)');
    lines.push('');
  } else {
    nameFixes.forEach(function (r) {
      lines.push('-- ' + r.name + '  ->  ' + r.fixed);
      lines.push("UPDATE churches SET name = '" + sqlEscape(r.fixed) + "' WHERE id = '" + r.id + "' AND name = '" + sqlEscape(r.name) + "';");
      lines.push('');
    });
  }

  lines.push('-- ===================================================================');
  lines.push('-- 3) FLAGGED, NOT AUTO-FIXABLE: name still ends in "of"/"at" with');
  lines.push('--    nothing after it (after the fixes above) -- looks like an import');
  lines.push('--    that lost its trailing city/descriptor. No SQL generated for');
  lines.push('--    these -- go find the actual full name and fix by hand.');
  lines.push('-- ===================================================================');
  lines.push('');
  if (truncatedFlags.length === 0) {
    lines.push('-- (none found)');
    lines.push('');
  } else {
    truncatedFlags.forEach(function (r) {
      lines.push('-- id ' + r.id + ': "' + r.name + '"');
    });
    lines.push('');
  }

  fs.writeFileSync(outPath, lines.join('\n'));
  process.stderr.write(nonprofitHides.length + ' church(es) to hide, ' + nameFixes.length + ' name fix(es), ' + truncatedFlags.length + ' possibly-truncated name(s) flagged. Wrote ' + outPath + '\n');
}

// Guarded the same way as acronym-exceptions.js -- requiring this file as
// a library never triggers a live fetch, only running it directly does.
if (require.main === module) {
  (function main() {
    const args = process.argv.slice(2);
    if (args.includes('--selftest')) return selftest();
    if (args.includes('--help') || args.includes('-h')) {
      process.stderr.write('Usage: node scripts/church-name-hygiene.js [--out=<path>] [--selftest]\n');
      process.exit(0);
    }
    const outArg = args.find(function (a) { return a.startsWith('--out='); });
    const outPath = outArg ? outArg.slice('--out='.length) : path.join(process.cwd(), 'church_name_hygiene_fixes.sql');

    runScan(outPath).catch(function (err) {
      process.stderr.write('Error: ' + err.message + '\n');
      process.exit(1);
    });
  })();
}

module.exports = {
  isNonprofitName, stripLocatorSuffix, fixMinorWordCasing, looksTruncated,
  NONPROFIT_RE, LOCATOR_SUFFIX_RE, MINOR_WORDS
};
