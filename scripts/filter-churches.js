#!/usr/bin/env node
'use strict';

/*
 * filter-churches.js
 * -------------------
 * Takes a raw nonprofit-org extract (e.g. an IRS EO Business Master File
 * pull for a metro area -- columns: name, denomination, address; same
 * shape enrich-churches.js expects, `denomination` may be blank) and
 * splits it into three files:
 *
 *   <prefix>.clean.csv     import-ready: looks like an actual single
 *                          congregation.
 *   <prefix>.excluded.csv  confidently NOT a single congregation to list
 *                          -- a school, a diocese/archdiocese admin
 *                          office, an insurance affiliate, a fundraising
 *                          Foundation/Endowment/Trust arm, etc.
 *   <prefix>.review.csv    ambiguous "association of..." / "council of
 *                          ..." / "...society" entities that might be a
 *                          single congregation, a denominational body, or
 *                          a parachurch org -- needs a human to look.
 *
 * Rows that don't look like a religious organization at all are silently
 * dropped (not written anywhere) -- for a whole-metro or statewide BMF
 * pull, the overwhelming majority of rows are ordinary nonprofits with
 * nothing to do with churches, and there's no reason to review those.
 *
 * ---------------------------------------------------------------------
 * Why every keyword check here is WORD-BOUNDARY, never a plain substring
 * check:
 *
 * The first, ad hoc pass at this (done outside any committed script, for
 * the San Antonio metro import) matched keywords with plain substring
 * checks. That is exactly how "Resurrection Cemetery Administry Of The
 * Cordi-Marian Sisters" -- a cemetery administrative office, not a
 * ministry -- slipped in as a candidate: "Administry" contains the
 * letters "ministry". Rebuilding the same list here with
 * `\bministry\b`-style word-boundary regex instead of `.includes(...)`
 * closes that whole bug CLASS, not just that one name. Re-validating the
 * word-boundary version against San Antonio's actual, already-triaged
 * clean/excluded/review split (1470 raw rows) turned up two more
 * real instances of the exact same substring bug that the original ad
 * hoc pass had silently gotten wrong in the other direction -- both
 * fixed for free by the same regex change, not chased down by hand:
 *   - "Winston Churchill High School" and five other Churchill ISD
 *     school-club names (band boosters, JROTC, orchestra, speech &
 *     debate, a plain "Churchill Spirit Club") were being treated as
 *     religious-org CANDIDATES purely because "Churchill" contains
 *     "church" -- then had to be filtered back out via "School" /
 *     "Booster Club" / "Association". With `\bchurch\b`, "Churchill"
 *     never matches in the first place, so these are correctly dropped
 *     at stage 1 instead of leaking into .excluded.csv / .review.csv.
 *   - "Palme-Templeton Family Foundation" was a candidate because
 *     "Templeton" contains "temple". `\btemple\b` doesn't match it;
 *     it's correctly dropped instead of leaking into .excluded.csv.
 * The known, accepted trade-off in the other direction: a handful of
 * real, stylized church names that mash the keyword into another word
 * with no separator at all -- "Rechurch210", "Oasis Of Hope
 * Familychurch" -- won't match `\bchurch\b` either, and get dropped
 * instead of landing in .clean.csv. There's no regex that gets both
 * of those right at once; word-boundary was chosen because false
 * positives (a non-church silently in the directory) are worse than
 * false negatives (a real church needing a manual add), and a full run
 * finishes fast enough to skim the dropped-row count and spot-check.
 * ---------------------------------------------------------------------
 *
 * Usage:
 *   node scripts/filter-churches.js input.csv [outputPrefix]
 *
 *   outputPrefix defaults to input.csv's own path without its extension,
 *   so input.csv -> input.clean.csv / input.excluded.csv / input.review.csv
 *
 * Flags:
 *   --selftest   run offline sanity checks (including the Administry,
 *                Churchill, and Templeton cases above) and exit
 */

const fs = require('fs');
const path = require('path');

// ===========================================================================
// Word-boundary keyword matching
// ===========================================================================

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// A keyword may be a phrase ("assembly of god", "credit union") -- \b at
// each end of the WHOLE phrase, internal whitespace matched loosely.
function makeWordRegex(phrase) {
  return new RegExp('\\b' + escapeRe(phrase).replace(/\s+/g, '\\s+') + '\\b', 'i');
}

const KEYWORD_REGEX_CACHE = new Map();
function keywordRegex(phrase) {
  let re = KEYWORD_REGEX_CACHE.get(phrase);
  if (!re) { re = makeWordRegex(phrase); KEYWORD_REGEX_CACHE.set(phrase, re); }
  return re;
}

function hasAnyKeyword(name, keywords) {
  return keywords.some((kw) => keywordRegex(kw).test(name));
}

// ===========================================================================
// Keyword lists established for the San Antonio metro pull
// ===========================================================================

// Stage 1 -- is this a religious organization at all? A row passes if its
// name contains one of these (word-boundary) OR it already has a non-blank
// `denomination` field (the source extract's own religious-category tag).
// Everything else is dropped outright.
const RELIGION_KEYWORDS = [
  'church', 'churches', 'ministry', 'ministries', 'parish', 'parishes',
  'congregation', 'congregations', 'congregational', 'chapel', 'chapels',
  'cathedral', 'temple', 'synagogue', 'mosque', 'tabernacle', 'fellowship',
  'diocese', 'archdiocese', 'mission', 'missions', 'gospel', 'worship',
  'faith', 'bible', 'monastery', 'convent', 'abbey', 'seminary', 'holiness',
  'assembly of god',
  'christian', 'catholic', 'baptist', 'methodist', 'lutheran',
  'presbyterian', 'pentecostal', 'episcopal', 'episcopalian',
  'orthodox', 'evangelical', 'apostolic', 'adventist', 'mennonite',
  'mormon', 'islamic', 'muslim', 'buddhist', 'hindu', 'jewish', 'sikh',
  // Spanish equivalents. Not all of these were needed for San Antonio's
  // exact denomination mix, but Spanish-named congregations are common
  // enough across Texas that a statewide run needs them from the start,
  // not bolted on after the fact.
  'iglesia', 'iglesias', 'templo', 'templos', 'ministerio', 'ministerios',
  'parroquia', 'capilla', 'catedral', 'mision', 'misión', 'congregacion',
  'congregación', 'cristiana', 'cristiano', 'evangelica', 'evangelico',
  'catolica', 'catolico', 'apostolica', 'apostolico',
];

// Stage 2 -- of the religious orgs, is this an actual single congregation
// someone could visit, or an administrative/fundraising/institutional
// entity that shouldn't get its own directory listing? Checked BEFORE
// REVIEW_KEYWORDS -- e.g. "Lutheran High School Association Of San
// Antonio" has both "School" and "Association"; it's a school (excluded),
// not merely association-shaped (review).
const EXCLUDE_KEYWORDS = [
  'school', 'academy', 'cemetery', 'cemeteries', 'insurance',
  'credit union', 'foundation', 'endowment', 'trust', 'diocese',
  'archdiocese', 'seminary', 'booster club', 'alumni association',
  'charities', 'charitable', 'capital campaign',
];

// Ambiguous entity-type words -- a denominational association, a
// ministerial council, a religious society. Could be a real single
// congregation with an unusual name, could be a multi-church body. Human
// judgment call either way, so these go to .review.csv rather than
// getting silently included or excluded.
const REVIEW_KEYWORDS = ['association', 'council', 'society'];

function classify(name, denomination) {
  const isReligious = hasAnyKeyword(name, RELIGION_KEYWORDS) || !!(denomination && denomination.trim());
  if (!isReligious) return 'drop';
  if (hasAnyKeyword(name, EXCLUDE_KEYWORDS)) return 'excluded';
  if (hasAnyKeyword(name, REVIEW_KEYWORDS)) return 'review';
  return 'clean';
}

// ===========================================================================
// CSV (same implementation as enrich-churches.js -- kept in sync by hand;
// see that file's comments for the quoting/BOM/line-ending details)
// ===========================================================================

function parseCsv(text) {
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1); // BOM
  text = text.replace(/\r\n?/g, '\n');

  const rows = [];
  let row = [];
  let field = '';
  let inQ = false;

  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inQ) {
      if (ch === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; }
        else inQ = false;
      } else field += ch;
    } else if (ch === '"') {
      inQ = true;
    } else if (ch === ',') {
      row.push(field); field = '';
    } else if (ch === '\n') {
      row.push(field); rows.push(row); row = []; field = '';
    } else {
      field += ch;
    }
  }
  if (field.length || row.length) { row.push(field); rows.push(row); }
  while (rows.length && rows[rows.length - 1].every((c) => c === '')) rows.pop();

  const headers = rows.shift() || [];
  return { headers, rows };
}

function csvCell(v) {
  v = v == null ? '' : String(v);
  return /[",\r\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
}
function csvRow(arr) {
  return arr.map(csvCell).join(',') + '\n';
}

// ===========================================================================
// Small helpers
// ===========================================================================

function defaultOutPrefix(p) {
  const ext = path.extname(p);
  return ext ? p.slice(0, -ext.length) : p;
}
function printUsage() {
  process.stderr.write(
    'Usage:\n  node scripts/filter-churches.js input.csv [outputPrefix]\n\n' +
    'Input CSV needs at least "name" and "address" columns ("denomination"\n' +
    'is used if present, but optional). Writes <prefix>.clean.csv,\n' +
    '<prefix>.excluded.csv, <prefix>.review.csv. Rows that don\'t look\n' +
    'like a religious org at all are dropped (not written anywhere).\n' +
    'Flags: --selftest.\n'
  );
}
function die(msg) {
  process.stderr.write('\nerror: ' + msg + '\n');
  process.exit(1);
}

// ===========================================================================
// Main
// ===========================================================================

function run(inPath, outPrefix) {
  const raw = fs.readFileSync(inPath, 'utf8');
  const { headers, rows } = parseCsv(raw);
  if (!headers.length) die('Input CSV has no header row.');

  const headerLC = headers.map((h) => h.trim().toLowerCase());
  const nameIdx = headerLC.indexOf('name');
  const addrIdx = headerLC.indexOf('address');
  const denomIdx = headerLC.indexOf('denomination');
  if (nameIdx === -1 || addrIdx === -1) {
    die('Input CSV must have "name" and "address" columns. Found: ' + headers.join(', '));
  }

  const outFiles = {
    clean: fs.createWriteStream(outPrefix + '.clean.csv', { encoding: 'utf8' }),
    excluded: fs.createWriteStream(outPrefix + '.excluded.csv', { encoding: 'utf8' }),
    review: fs.createWriteStream(outPrefix + '.review.csv', { encoding: 'utf8' }),
  };
  for (const k in outFiles) outFiles[k].write(csvRow(headers));

  const counts = { clean: 0, excluded: 0, review: 0, drop: 0 };
  for (const row of rows) {
    const name = (row[nameIdx] || '').trim();
    const denomination = denomIdx === -1 ? '' : (row[denomIdx] || '').trim();
    const bucket = classify(name, denomination);
    counts[bucket]++;
    if (bucket !== 'drop') outFiles[bucket].write(csvRow(row));
  }

  for (const k in outFiles) outFiles[k].end();

  const total = rows.length;
  process.stderr.write(
    '\nDone. ' + total + ' input rows:\n' +
    '  clean    : ' + counts.clean + '  -> ' + outPrefix + '.clean.csv\n' +
    '  excluded : ' + counts.excluded + '  -> ' + outPrefix + '.excluded.csv\n' +
    '  review   : ' + counts.review + '  -> ' + outPrefix + '.review.csv\n' +
    '  dropped  : ' + counts.drop + '  (not a religious org by name/denomination -- not written anywhere)\n'
  );
}

// ===========================================================================
// Self-test (no network, no file I/O)
// ===========================================================================

function selftest() {
  let failed = 0;
  const eq = (got, want, label) => {
    const ok = got === want;
    if (!ok) failed++;
    process.stderr.write((ok ? '  ok   ' : '  FAIL ') + label +
      (ok ? '' : '  got ' + JSON.stringify(got) + '  want ' + JSON.stringify(want)) + '\n');
  };

  process.stderr.write('word-boundary keyword matching (the actual bug fix):\n');
  eq(hasAnyKeyword('Resurrection Cemetery Administry Of The Cordi-Marian Sisters', ['ministry']), false, '"Administry" does not match "ministry"');
  eq(hasAnyKeyword('Grace Ministry Church', ['ministry']), true, '"Ministry" as its own word does match');
  eq(hasAnyKeyword('Winston Churchill High School Jrotc Booster Club', ['church']), false, '"Churchill" does not match "church"');
  eq(hasAnyKeyword('Crossbridge Community Church Of San Antonio', ['church']), true, '"Church" as its own word does match');
  eq(hasAnyKeyword('Palme-Templeton Family Foundation', ['temple']), false, '"Templeton" does not match "temple"');
  eq(hasAnyKeyword('Hindu Temple Of San Antonio Foundation', ['temple']), true, '"Temple" as its own word does match');
  eq(hasAnyKeyword('Valley Hi Assembly Of God', ['assembly of god']), true, 'multi-word phrase matches');
  eq(hasAnyKeyword('Some Assembly Hall Required', ['assembly of god']), false, 'multi-word phrase requires the whole phrase');

  process.stderr.write('classify() end-to-end:\n');
  eq(classify('Resurrection Cemetery Administry Of The Cordi-Marian Sisters', 'Christian / General'), 'excluded', 'cemetery admin office -> excluded (via "Cemetery", not a false "ministry" match)');
  eq(classify('Crossbridge Community Church Of San Antonio', ''), 'clean', 'plain church name, blank denomination -> clean');
  eq(classify('Baptist Credit Union', 'Baptist'), 'excluded', 'denomination alone is enough to be a candidate; "Credit Union" excludes it');
  eq(classify('Winston Churchill High School Jrotc Booster Club', ''), 'drop', 'non-religious org -- "Churchill" must not make it a candidate');
  eq(classify('Palme-Templeton Family Foundation', ''), 'drop', 'non-religious org -- "Templeton" must not make it a candidate');
  eq(classify('Cufi Church Association', ''), 'review', 'real "Church" + "Association" -> ambiguous, needs a human');
  eq(classify('Iglesia Bautista Nueva Esperanza', ''), 'clean', 'Spanish-named church, blank denomination -> clean');
  eq(classify('Westover Hills Assembly Of God Foundation', ''), 'excluded', '"Assembly of God" is religious, "Foundation" excludes it');
  eq(classify('Acme Plumbing Inc', ''), 'drop', 'ordinary non-religious nonprofit -> drop');

  process.stderr.write('csv round-trip:\n');
  const sample = 'name,denomination,address\r\n"Smith, John Memorial Church",Baptist,"1 A St, Waco, TX 76700"\nPlain Temple,,"2 B St, Austin, TX 78701"\n';
  const p = parseCsv(sample);
  eq(JSON.stringify(p.headers), JSON.stringify(['name', 'denomination', 'address']), 'headers');
  eq(JSON.stringify(p.rows[0]), JSON.stringify(['Smith, John Memorial Church', 'Baptist', '1 A St, Waco, TX 76700']), 'quoted comma field');
  eq(csvRow(['a', 'b,c', 'd"e']), 'a,"b,c","d""e"\n', 'writer quoting');

  process.stderr.write(failed ? '\n' + failed + ' check(s) FAILED\n' : '\nall checks passed\n');
  process.exit(failed ? 1 : 0);
}

// ===========================================================================
// CLI entry
// ===========================================================================

(function main() {
  const positional = [];
  for (const a of process.argv.slice(2)) {
    if (a === '--selftest') return selftest();
    else if (a === '--help' || a === '-h') { printUsage(); process.exit(0); }
    else if (a.startsWith('--')) die('Unknown flag: ' + a);
    else positional.push(a);
  }

  const inPath = positional[0];
  if (!inPath) { printUsage(); process.exit(1); }
  const outPrefix = positional[1] || defaultOutPrefix(inPath);

  if (!fs.existsSync(inPath)) die('Input file not found: ' + inPath);

  run(inPath, outPrefix);
})();
