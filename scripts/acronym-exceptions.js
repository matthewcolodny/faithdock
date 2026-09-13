#!/usr/bin/env node
'use strict';

/*
 * acronym-exceptions.js
 * ----------------------
 * Church-name title-casing (whatever pipeline eventually runs it -- see
 * the note in GOTCHAS.md: the one-off script that originally title-cased
 * the San Antonio import's names was never committed to this repo, so
 * there's no single shared title-caser to hook this into today) turns
 * any all-caps acronym into "Satx", "Umc", "Efca", etc. -- readable for
 * an ordinary word, wrong for an abbreviation that's supposed to stay
 * all-caps. This file is the reusable fix for that, meant to be
 * `require()`'d by whatever future import/cleanup script needs it,
 * rather than re-solving this per-region the way the original San
 * Antonio pass apparently did.
 *
 * ACRONYM_EXCEPTIONS is deliberately just a flat array of uppercase
 * strings -- extending it for a new region or denomination is a
 * one-line edit, nothing else to touch. Every match is whole-word
 * (`\bSATX\b`, never a substring check) for the same reason
 * filter-churches.js's keyword matching is -- see that file's own
 * header for the "Administry"/"Churchill" story this project already
 * learned that lesson from once.
 *
 * Usage as a library (from another script):
 *   const { applyAcronymCasing } = require('./acronym-exceptions');
 *   const fixed = applyAcronymCasing(titleCasedName);
 *
 * Usage as a one-off live-database audit (no args needed -- reads the
 * public, publishable Supabase key already embedded in index.html,
 * same one every visitor's browser already uses):
 *   node scripts/acronym-exceptions.js
 * Fetches every current church name, finds any acronym token that isn't
 * already in its canonical all-caps form, and writes a ready-to-run SQL
 * correction file -- never writes to the database itself. This project
 * has no CLI/linked Supabase project (see CLAUDE.md-equivalent
 * conventions elsewhere in this repo) -- every real data change here
 * goes through a generated .sql file, run by hand in the Supabase SQL
 * Editor, same as every other one-off correction script in this repo
 * root.
 *
 *   --selftest         offline checks, no network access
 *   --out=<path>        where to write the SQL file (default:
 *                        acronym_casing_fixes.sql in the cwd)
 */

const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------------
// The list. Add to it freely -- one uppercase string per acronym, no
// other bookkeeping required. Grouped by comment only for readability;
// the matching logic below doesn't care about the grouping.
// ---------------------------------------------------------------------
const ACRONYM_EXCEPTIONS = [
  // Regional
  'SATX', 'RGV',
  // Denominational / parachurch
  'UPCI', 'UMC', 'EFCA', 'SBC', 'COGIC', 'AME', 'ELCA', 'PCA', 'AG'
];

// Applies every known acronym exception to a single (already
// title-cased) name, forcing each whole-word match back to its
// canonical all-caps form. Idempotent -- running it twice on an
// already-correct name is a no-op, so it's always safe to run as a
// blanket final pass rather than only on rows known to be wrong.
function applyAcronymCasing(name) {
  if (!name) return name;
  let result = name;
  for (const acronym of ACRONYM_EXCEPTIONS) {
    const re = new RegExp('\\b' + acronym + '\\b', 'gi');
    result = result.replace(re, acronym);
  }
  return result;
}

function selftest() {
  let failed = 0;
  function eq(actual, expected, label) {
    if (actual !== expected) {
      failed++;
      process.stderr.write('FAIL: ' + label + ' -- expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual) + '\n');
    }
  }

  eq(applyAcronymCasing('Waypoint Church Satx'), 'Waypoint Church SATX', 'SATX gets fixed');
  eq(applyAcronymCasing('The Church Upci Inc'), 'The Church UPCI Inc', 'UPCI gets fixed');
  eq(applyAcronymCasing('River Church Rgv Inc'), 'River Church RGV Inc', 'RGV gets fixed');
  eq(applyAcronymCasing('Windsong Christian Center Umc'), 'Windsong Christian Center UMC', 'UMC gets fixed');
  eq(applyAcronymCasing('Mission Community Church- Efca'), 'Mission Community Church- EFCA', 'EFCA gets fixed');
  eq(applyAcronymCasing('Sherman Chapel Ame Church'), 'Sherman Chapel AME Church', 'AME gets fixed');
  eq(applyAcronymCasing('Christ Church Pca of San Antonio'), 'Christ Church PCA of San Antonio', 'PCA gets fixed');
  eq(applyAcronymCasing('Already Correct SATX Church'), 'Already Correct SATX Church', 'already-correct input is a no-op');
  eq(applyAcronymCasing(applyAcronymCasing('Waypoint Church Satx')), 'Waypoint Church SATX', 'idempotent -- running twice is safe');

  // Guards: acronym exceptions must never fire as a substring inside an
  // unrelated real word -- \b is what keeps "AG" (Assembly of God) from
  // matching inside "Agape" the way "ministry" almost matched inside
  // "Administry" elsewhere in this project (see filter-churches.js).
  eq(applyAcronymCasing('Agape Fellowship Church'), 'Agape Fellowship Church', '"AG" does not fire inside "Agape"');
  eq(applyAcronymCasing('Amen Chapel'), 'Amen Chapel', '"AME" does not fire inside "Amen"');
  eq(applyAcronymCasing('Sacred Heart Church'), 'Sacred Heart Church', 'no acronym present -- untouched');
  eq(applyAcronymCasing(''), '', 'empty string -- no-op');
  eq(applyAcronymCasing(null), null, 'null -- no-op, does not throw');

  process.stderr.write(failed ? '\n' + failed + ' check(s) FAILED\n' : '\nall checks passed\n');
  process.exit(failed ? 1 : 0);
}

// ---------------------------------------------------------------------
// CLI: scan the live database and generate a correction .sql file.
// Read-only against Supabase -- the actual UPDATE only ever happens
// when a human runs the generated file by hand.
// ---------------------------------------------------------------------

// The same publishable/anon key already embedded in index.html --
// intentionally safe to hardcode here for the same reason it's safe to
// ship in the client bundle every visitor already downloads. Override
// with env vars if this is ever pointed at a different project.
const SUPABASE_URL = process.env.SUPABASE_URL || 'https://doerahlrdknedoknawex.supabase.co';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'sb_publishable_zdoYSKnhvJyEdhhbCV_CAw_owRZ3f-V';

async function fetchAllChurchNames() {
  const pageSize = 1000;
  let all = [];
  for (let offset = 0; ; offset += pageSize) {
    const url = SUPABASE_URL + '/rest/v1/churches?select=id,name&order=id&offset=' + offset + '&limit=' + pageSize;
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
  const rows = await fetchAllChurchNames();
  process.stderr.write('Checking ' + rows.length + ' names against ' + ACRONYM_EXCEPTIONS.length + ' known acronyms...\n');

  const mismatches = rows
    .map(function (r) { return { id: r.id, name: r.name, fixed: applyAcronymCasing(r.name) }; })
    .filter(function (r) { return r.fixed !== r.name; });

  const lines = [];
  lines.push('-- Corrects church names where a known acronym (' + ACRONYM_EXCEPTIONS.join(', ') + ')');
  lines.push('-- was title-cased instead of kept all-caps -- generated by');
  lines.push('-- scripts/acronym-exceptions.js against the live database.');
  lines.push('-- Extend ACRONYM_EXCEPTIONS in that file and re-run to catch more.');
  lines.push('');
  mismatches.forEach(function (r) {
    lines.push('-- ' + r.name + '  ->  ' + r.fixed);
    lines.push("UPDATE churches SET name = '" + sqlEscape(r.fixed) + "' WHERE id = '" + r.id + "' AND name = '" + sqlEscape(r.name) + "';");
    lines.push('');
  });

  fs.writeFileSync(outPath, lines.join('\n'));
  process.stderr.write(mismatches.length + ' mismatch(es) found. Wrote ' + outPath + '\n');
  if (mismatches.length === 0) {
    process.stderr.write('(No SQL statements to run -- every live name already matches the expected casing.)\n');
  }
}

(function main() {
  const args = process.argv.slice(2);
  if (args.includes('--selftest')) return selftest();
  if (args.includes('--help') || args.includes('-h')) {
    process.stderr.write('Usage: node scripts/acronym-exceptions.js [--out=<path>] [--selftest]\n');
    process.exit(0);
  }
  const outArg = args.find(function (a) { return a.startsWith('--out='); });
  const outPath = outArg ? outArg.slice('--out='.length) : path.join(process.cwd(), 'acronym_casing_fixes.sql');

  runScan(outPath).catch(function (err) {
    process.stderr.write('Error: ' + err.message + '\n');
    process.exit(1);
  });
})();

module.exports = { ACRONYM_EXCEPTIONS, applyAcronymCasing };
