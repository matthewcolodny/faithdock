#!/usr/bin/env node
//
// Turns the IRS Exempt Organizations Business Master File for Texas
// into import-ready batches, the same shape the San Antonio run used.
//
//   node tools/prep-texas.js --in "C:/Users/Owner/Downloads/eo_tx.csv"
//
// Writes texas-batches/ :
//   _manifest.csv     one row per batch, biggest first -- the pick list
//   <zip3>-<city>.csv name,denomination,address -- ready for the
//                     admin importer as-is
//   _po-box.csv       real churches whose only address is a PO box
//   _review.csv       kept out of the batches, needs a human look
//   _excluded.csv     dropped, each with the reason
//
// ---------------------------------------------------------------------
// WHICH ROWS ARE CHURCHES
//
// Measured against the real file (153,779 rows) rather than assumed:
//
//   FOUNDATION = 10        24,716    IRS: "church 170(b)(1)(A)(i)"
//   NTEE_CD starts with X  22,311    religion-related
//   both                   13,409
//   F10 but NTEE not X     11,307
//   NTEE X but not F10      8,902
//
// FOUNDATION=10 is the IRS itself classifying the organisation as a
// church, and it is the filter used here. NTEE is assigned loosely and
// is blank for 40,494 rows, so it cannot be the primary test -- of the
// 11,307 churches it would have lost, a sample reads MT ZION BAPTIST
// CHURCH (coded Z20), LIFEBRIDGE CHRISTIAN CHURCH (B21), PENTECOSTAL
// WORSHIP CENTER (B90).
//
// The 8,902 rows that are NTEE-X but not FOUNDATION=10 are the other
// half of the same coin: religion-RELATED but not congregations --
// X12 fundraising, X40 religious media, X80 coalitions, X99 other.
// Those are exactly the "zero-signal ministries" that had to be hidden
// by hand after the San Antonio import. Not including them is the
// whole point of using FOUNDATION rather than NTEE.
//
// STATUS = 01 as well: 1,381 rows are revoked or otherwise not active.
//
// ---------------------------------------------------------------------
// WHAT IS DELIBERATELY NOT DONE HERE
//
// denomination is left BLANK. The database already derives tags from
// the name -- compute_denomination_tags(), migrations 023/026/027, with
// word-boundary patterns for messianic, LDS, apostolic, methodist,
// baptist and the rest. Re-implementing that keyword list in Node would
// create a second source of truth that drifts from the first. San
// Antonio's CSV left it blank for the same reason.
//
// address is left in the IRS's raw ALL CAPS. titleCaseAddress() in
// index.html fixes it at RENDER time, which covers rows imported a year
// from now as well as these, and keeps the stored value equal to the
// source. Fixing it here would put a second, diverging implementation
// in front of the first. name IS title-cased here, because that is what
// the San Antonio import did and the database stores it as given.
//
// Nothing is geocoded. Geocoding happens in the admin importer, one
// batch at a time, which is the point of splitting the file up.

const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------- args
const args = process.argv.slice(2);
function arg(name, fallback) {
  const i = args.indexOf('--' + name);
  return i !== -1 && args[i + 1] ? args[i + 1] : fallback;
}
const IN = arg('in', 'C:/Users/Owner/Downloads/eo_tx.csv');
const OUT = arg('out', 'texas-batches');
// Comma-separated CSVs of rows already imported, matched on name+address.
// Measured need: without it, 850 rows that went in with the San Antonio
// run reappear across three batches -- 699 of the 746 in 782 alone --
// and every one would be geocoded again before the importer's own
// dedupe_key threw it away. The server-side dedupe makes re-importing
// harmless; it does not make it free.
const EXCLUDE_FILES = arg('exclude', '').split(',').map(s => s.trim()).filter(Boolean);

// ----------------------------------------------------------------- csv
function splitCsvLine(line) {
  const out = []; let f = ''; let q = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) {
      if (c === '"') { if (line[i + 1] === '"') { f += '"'; i++; } else q = false; }
      else f += c;
    } else if (c === '"') q = true;
    else if (c === ',') { out.push(f); f = ''; }
    else f += c;
  }
  out.push(f);
  return out;
}
const q = v => {
  const s = String(v == null ? '' : v);
  return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
};
const csvLine = cells => cells.map(q).join(',');

// ------------------------------------------------------- name cleaning
// Same rules as titleCaseAddress() in index.html: connectors lowercased
// unless first or last, Mc surnames, apostrophes and hyphens.
const CONNECTORS = new Set(['of', 'the', 'and', 'in', 'for', 'a', 'an', 'to', 'at', 'on', 'by']);

// Left uppercase. Every one is a real church-name token that title case
// would otherwise mangle into Fbc, Umc, Sda.
const ACRONYMS = new Set([
  'FBC', 'FUMC', 'UMC', 'AME', 'AMEZ', 'CME', 'COGIC', 'UPCI', 'SDA', 'LDS', 'PCA', 'PCUSA',
  'ELCA', 'LCMS', 'SBC', 'BMA', 'CBF', 'ABC', 'UCC', 'COG', 'AG', 'YWAM', 'USA', 'US', 'TX',
  'II', 'III', 'IV', 'VI', 'VII', 'VIII', 'IX', 'XI', 'XII', 'JR', 'SR'
]);

function capWord(w) {
  return w.toLowerCase().replace(/(^|['-])([a-z])/g, (m, sep, ch) => sep + ch.toUpperCase());
}

function titleCaseName(raw) {
  if (!raw) return '';
  const cleaned = String(raw).replace(/\s+/g, ' ').trim();
  const words = cleaned.match(/[A-Za-z0-9''-]+/g) || [];
  let wi = 0;
  return cleaned.replace(/[A-Za-z0-9''-]+/g, (word) => {
    const isFirst = wi === 0, isLast = wi === words.length - 1;
    wi++;
    const letters = word.replace(/[^A-Za-z0-9]/g, '');
    const upper = letters.toUpperCase();
    if (ACRONYMS.has(upper)) return upper;
    // An ordinal such as 1ST or 2ND reads better lowercased after the
    // digit: "1St Baptist" is the thing title case gets wrong here.
    if (/^\d+(ST|ND|RD|TH)$/.test(upper)) return upper.toLowerCase();
    if (!isFirst && !isLast && CONNECTORS.has(letters.toLowerCase())) return word.toLowerCase();
    if (upper.length > 2 && upper.slice(0, 2) === 'MC' && /^[A-Z]/.test(upper.charAt(2))) {
      return 'Mc' + word.charAt(2).toUpperCase() + word.slice(3).toLowerCase();
    }
    return capWord(word);
  });
}

// ------------------------------------------------------------ verdicts
// Word-boundary matching throughout, never substrings. "Administry"
// contains "ministry" and "Churchill" contains "church"; both have
// already cost a round of wrong answers on this data.
const EXCLUDE = [
  [/\bcemeter(y|ies)\b|\bmausoleum\b|\bmemorial park\b/i, 'cemetery'],
  [/\b(arch)?diocese\b|\bpresbytery\b|\bsynod\b|\bconference of\b|\bconvention\b|\bassociation of churches\b/i, 'governing body, not a congregation'],
  [/\bcharit(y|ies)\b|\bfoundation\b|\bendowment\b|\bscholarship\b/i, 'grant-making, not a congregation'],
  [/\b(school|academy|college|university|seminary|institute|preschool|daycare|day care|montessori)\b/i, 'school'],
  [/\b(housing|apartments|retirement|nursing home|assisted living|senior living)\b/i, 'housing'],
  [/\b(credit union|thrift|bookstore|publishing|press|radio|broadcast(ing)?|television|tv network)\b/i, 'media or retail'],
  [/\b(camp|retreat center|conference center|campground)\b/i, 'camp or retreat centre'],
  [/\b(hospital|clinic|hospice|medical center)\b/i, 'health'],
  [/\b(food bank|thrift store|homeless shelter|crisis center|pregnancy center)\b/i, 'social service, not a congregation'],
];

// A congregation almost always says so somewhere in its name. The ones
// that do not are the rows that needed hiding by hand last time, so
// they are held back for a look rather than dropped or imported.
// Plurals and Spanish forms matter more than they look. Before they
// were here, 67 rows named "... Churches ..." and 185 beginning
// "Ministerio" were held back for review as having no congregation
// word -- \bchurch\b does not match "Churches", and the Spanish-
// language congregations are a large minority of this file, not an
// edge case.
const CONGREGATION = new RegExp([
  'church(es)?', 'chapel(s)?', 'parish(es)?', 'cathedral', 'basilica', 'oratory',
  'parroquia', 'iglesia(s)?', 'templo', 'temple', 'tabernacle|tabernaculo',
  'synagogue', 'assembly|assemblies', 'congregation', 'fellowship',
  'mission(s)?|misi[oó]n(es)?', 'worship', 'ministr(y|ies)', 'ministerio(s)?',
  'centro cristiano', 'christian cent(er|re)', 'comunidad cristiana',
  'casa de (oraci[oó]n|adoraci[oó]n|dios)', 'centro de adoraci[oó]n', 'capilla',
  'house of prayer', 'sanctuary', 'shrine', 'abbey', 'monastery', 'priory',
  'friary', 'convent'
].map(function(p){ return '(?:' + p + ')'; }).join('|').replace(/^/, '\\b(?:') + ')\\b', 'i');

function verdict(name) {
  for (const [re, reason] of EXCLUDE) if (re.test(name)) return { bucket: 'excluded', reason };
  if (!CONGREGATION.test(name)) return { bucket: 'review', reason: 'no congregation word in the name' };
  return { bucket: 'clean', reason: '' };
}

// ------------------------------------------------------------- read it
if (!fs.existsSync(IN)) {
  console.error('Input not found: ' + IN + '\nPass --in <path to eo_tx.csv>');
  process.exit(1);
}
console.log('Reading ' + IN + ' ...');
const lines = fs.readFileSync(IN, 'utf8').split(/\r?\n/);
const header = splitCsvLine(lines[0]).map(h => h.trim().replace(/^\uFEFF/, ''));
const col = {};
header.forEach((h, i) => (col[h] = i));
for (const need of ['NAME', 'STREET', 'CITY', 'STATE', 'ZIP', 'FOUNDATION', 'STATUS']) {
  if (col[need] === undefined) {
    console.error('Input is missing the column "' + need + '" -- is this the IRS EO BMF extract?');
    process.exit(1);
  }
}

// Already-imported rows, keyed the same way as the dedupe below.
const alreadyHave = new Set();
EXCLUDE_FILES.forEach(function(f){
  if (!fs.existsSync(f)) { console.error('  --exclude file not found, ignoring: ' + f); return; }
  const ls = fs.readFileSync(f, 'utf8').split(/\r?\n/);
  const h = splitCsvLine(ls[0]).map(x => x.trim().toLowerCase());
  const ni = h.indexOf('name'), ai = h.indexOf('address');
  if (ni === -1 || ai === -1) { console.error('  --exclude file has no name/address column, ignoring: ' + f); return; }
  let added = 0;
  for (let i = 1; i < ls.length; i++) {
    if (!ls[i]) continue;
    const c = splitCsvLine(ls[i]);
    if (!c[ni] || !c[ai]) continue;
    alreadyHave.add(c[ni].trim().toLowerCase() + '|' + c[ai].trim().toLowerCase());
    added++;
  }
  console.log('  excluding ' + added.toLocaleString() + ' already-imported rows from ' + f);
});

const clean = [], review = [], excluded = [], poBox = [];
const seen = new Set();
let total = 0, notChurch = 0, notActive = 0, dupes = 0, already = 0;

for (let i = 1; i < lines.length; i++) {
  if (!lines[i]) continue;
  const c = splitCsvLine(lines[i]);
  if (c.length < header.length - 2) continue;
  total++;
  const g = k => (c[col[k]] || '').trim();

  if (g('FOUNDATION') !== '10') { notChurch++; continue; }
  if (g('STATUS') !== '01') { notActive++; continue; }

  const rawName = g('NAME');
  const street = g('STREET');
  const city = g('CITY');
  const zip = g('ZIP');
  if (!rawName || !city) continue;

  const name = titleCaseName(rawName);
  const address = [street, city, (g('STATE') || 'TX') + ' ' + zip].filter(Boolean).join(', ');

  // Dedupe on the same key the database uses conceptually: name plus
  // address. The importer dedupes again server-side, so this only saves
  // geocoding the same row twice.
  const key = name.toLowerCase() + '|' + address.toLowerCase();
  if (seen.has(key)) { dupes++; continue; }
  seen.add(key);
  if (alreadyHave.has(key)) { already++; continue; }

  const v = verdict(rawName);
  const row = { name, address, city: city.toUpperCase(), zip3: (zip.match(/^\d{3}/) || [''])[0], reason: v.reason };

  if (v.bucket === 'excluded') { excluded.push(row); continue; }
  if (v.bucket === 'review') { review.push(row); continue; }
  // A PO box is a real church with an address that cannot be put on a
  // map. Separated rather than dropped: importing them would place pins
  // at a post office, and dropping them would lose real congregations.
  if (/^\s*P\.?\s*O\.?\s*BOX\b/i.test(street) || /^\s*POST OFFICE BOX\b/i.test(street)) {
    row.reason = 'PO box only -- no street address to place on a map';
    poBox.push(row);
    continue;
  }
  clean.push(row);
}

// ------------------------------------------------------------- batches
// Grouped by the first three digits of the ZIP, which is a real postal
// geography (the sectional centre), and LABELLED from the data -- the
// city holding the most rows in that group. Deliberately not a
// hand-written metro table: a wrong guess about which suburb belongs to
// which metro is invisible until the map is drawn.
const groups = new Map();
clean.forEach(r => {
  const k = r.zip3 || '000';
  if (!groups.has(k)) groups.set(k, []);
  groups.get(k).push(r);
});

const batches = [...groups.entries()].map(([zip3, rows]) => {
  const cities = {};
  rows.forEach(r => (cities[r.city] = (cities[r.city] || 0) + 1));
  const top = Object.entries(cities).sort((a, b) => b[1] - a[1])[0];
  return {
    zip3,
    label: top ? top[0] : 'UNKNOWN',
    rows,
    cities: Object.keys(cities).length,
    topShare: top ? Math.round((top[1] / rows.length) * 100) : 0
  };
}).sort((a, b) => b.rows.length - a.rows.length);

// -------------------------------------------------------------- write
fs.mkdirSync(OUT, { recursive: true });
// Start clean so a re-run after changing the rules cannot leave last
// run's batches lying next to this run's manifest.
fs.readdirSync(OUT).filter(f => f.endsWith('.csv')).forEach(f => fs.unlinkSync(path.join(OUT, f)));

const slug = s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const IMPORT_HEADER = 'name,denomination,address';

batches.forEach(b => {
  const file = b.zip3 + '-' + slug(b.label) + '.csv';
  const body = b.rows.map(r => csvLine([r.name, '', r.address])).join('\n');
  fs.writeFileSync(path.join(OUT, file), IMPORT_HEADER + '\n' + body + '\n');
  b.file = file;
});

function writeAux(file, rows, withReason) {
  const head = withReason ? 'name,denomination,address,reason' : IMPORT_HEADER;
  const body = rows.map(r => csvLine(withReason ? [r.name, '', r.address, r.reason] : [r.name, '', r.address])).join('\n');
  fs.writeFileSync(path.join(OUT, file), head + '\n' + body + '\n');
}
writeAux('_po-box.csv', poBox, true);
writeAux('_review.csv', review, true);
writeAux('_excluded.csv', excluded, true);

fs.writeFileSync(path.join(OUT, '_manifest.csv'),
  'file,zip3,label,rows,distinct_cities,top_city_share_pct\n' +
  batches.map(b => csvLine([b.file, b.zip3, b.label, b.rows.length, b.cities, b.topShare + '%'])).join('\n') + '\n');

// ------------------------------------------------------------- report
const pct = (a, b) => (b ? Math.round((a / b) * 100) : 0) + '%';
console.log('\nRead              ' + total.toLocaleString() + ' organisations');
console.log('  not a church    ' + notChurch.toLocaleString() + '  (FOUNDATION <> 10)');
console.log('  not active      ' + notActive.toLocaleString() + '  (STATUS <> 01)');
console.log('  duplicate rows  ' + dupes.toLocaleString());
if (alreadyHave.size) console.log('  already imported ' + already.toLocaleString());
const churches = clean.length + review.length + excluded.length + poBox.length;
console.log('\nChurches          ' + churches.toLocaleString());
console.log('  ready to import ' + clean.length.toLocaleString() + '  ' + pct(clean.length, churches) + '  in ' + batches.length + ' batches');
console.log('  PO box only     ' + poBox.length.toLocaleString() + '  ' + pct(poBox.length, churches) + '  _po-box.csv');
console.log('  needs a look    ' + review.length.toLocaleString() + '  ' + pct(review.length, churches) + '  _review.csv');
console.log('  excluded        ' + excluded.length.toLocaleString() + '  ' + pct(excluded.length, churches) + '  _excluded.csv');

console.log('\nBiggest batches:');
batches.slice(0, 15).forEach(b => {
  console.log('  ' + String(b.rows.length).padStart(5) + '  ' + b.file.padEnd(28) + b.cities + ' cities, ' + b.topShare + '% ' + b.label);
});
console.log('\nWritten to ' + OUT + '/  -- start with _manifest.csv');
