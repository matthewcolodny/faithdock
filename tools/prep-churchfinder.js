#!/usr/bin/env node
//
// Turns a churchfinder.com scrape into import-ready batches, the same
// shape prep-texas.js produces, so the same enrich/import pipeline
// takes it.
//
//   node tools/prep-churchfinder.js --in "C:/Users/Owner/Downloads/churchfinder-com-2026-08-20.csv"
//
// ---------------------------------------------------------------------
// WHY A SECOND SOURCE EXISTS AT ALL
//
// Churches are automatically tax-exempt under IRC 508(c)(1)(A). They
// are NOT required to apply for recognition, and many never do, so they
// never appear in the IRS Business Master File that prep-texas.js reads.
// The BMF is a list of churches that chose to file, not a list of
// churches.
//
// Measured, San Antonio, against this scrape's 746 churches:
//
//   clear match in the IRS data   144   19%
//   partial match                 359   48%
//   no match at all               243   33%
//
// About a third of real churches in one metro are missing from the IRS
// file. Treat the number as approximate -- the scrape carries its own
// junk (San Martin Athletic Association, San Antonio TEC) and the
// fuzzy threshold is a judgement -- but the order of magnitude held
// across two different matching methods. An exact-name pass said 85%,
// which was too strict to believe and is why this was measured twice.
//
// It is not a random third, either. The churches least likely to have
// filed are small, immigrant, Spanish-language and storefront
// congregations: Vietnamese Martyrs Catholic Center, Templo Bautista
// Getsemani, Shepherd's Fellowship. Those are exactly the listings a
// directory is most useful for.
//
// ---------------------------------------------------------------------
// WHAT THIS SOURCE HAS THAT THE IRS FILE DOES NOT
//
//   denomination   100%   and specific -- "Southern Baptist Convention",
//                         "Evangelical Lutheran in America"
//   telephone       92%
//   service times   95%   not imported yet; no column for it
//   description     64%   not imported yet
//   address        100%   schema_address parses 99% as street +
//                         "City, ST ZIP"
//
// It has no website -- item_page_link is churchfinder's own page, not
// the church's -- so enrich-batch.js still earns its keep here, for the
// website and for confirming the place exists.
//
// Images are skipped: 724 of 751 are churchfinder's default placeholder
// icon, so the column is 96% noise.
//
// ---------------------------------------------------------------------
// DENOMINATION IS PASSED THROUGH, unlike prep-texas.js which leaves it
// blank. It is real information here and better input than the name
// alone -- compute_denomination_tags() reads (denomination, name), so
// "The Anchor" tagged "Southern Baptist Convention" gets Baptist tags it
// could never have earned from its name.
//
// Note the consequence: the stored text will read "Southern Baptist
// Convention" rather than the app's canonical "Baptist". Filtering is
// unaffected -- that runs on denomination_tags, which are canonical --
// but the displayed label joins the 133 rows already carrying
// non-canonical text from the original San Antonio import. One
// migration normalises all of them; it has not been written yet.

const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
function arg(name, fallback) {
  const i = args.indexOf('--' + name);
  return i !== -1 && args[i + 1] ? args[i + 1] : fallback;
}
const IN = arg('in', 'C:/Users/Owner/Downloads/churchfinder-com-2026-08-20.csv');
const OUT = arg('out', 'churchfinder-batches');
const EXCLUDE_FILES = arg('exclude', '').split(',').map(s => s.trim()).filter(Boolean);

// A scraped CSV has newlines INSIDE quoted fields -- schema_address is
// three lines in one cell -- so it cannot be split on \n first. This
// walks the whole text.
function parseCsv(text) {
  const rows = []; let row = [], field = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else q = false; }
      else field += c;
    } else if (c === '"') q = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
    else if (c !== '\r') field += c;
  }
  if (field || row.length) { row.push(field); rows.push(row); }
  return rows;
}
const q = v => { const s = String(v == null ? '' : v); return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
const csvLine = cells => cells.map(q).join(',');

// Same corporate-suffix rule as prep-texas.js. Kept in sync by hand;
// both are the expression in index.html.
const CORPORATE_SUFFIX_RE = /,?\s*\b(?:(?:an?\s+)?(?:(?:domestic|texas|state\s+of\s+texas)\s+)*non[\s-]?profit\b|l\.l\.c\.|(?:incorporated|incorporation|corporation|inc|corp|llc|ltd|limited)\b).*$/i;
function stripSuffix(name) {
  const out = String(name || '').replace(CORPORATE_SUFFIX_RE, '').replace(/[\s,]+$/, '');
  return out || String(name || '');
}

// Names here are already mixed case and human-written, so they are NOT
// title-cased -- doing so would turn "First UMC" into "First Umc". Only
// whitespace is tidied.
const tidy = s => String(s || '').replace(/\s+/g, ' ').trim();

if (!fs.existsSync(IN)) {
  console.error('Input not found: ' + IN + '\nPass --in <path to the scrape>');
  process.exit(1);
}
const rows = parseCsv(fs.readFileSync(IN, 'utf8').replace(/^\uFEFF/, ''));
const header = rows[0].map(h => h.trim());
const ix = {};
header.forEach((h, i) => (ix[h] = i));
for (const need of ['name', 'schema_address']) {
  if (ix[need] === undefined) {
    console.error('Input has no "' + need + '" column -- is this a churchfinder scrape?');
    process.exit(1);
  }
}

const alreadyHave = new Set();
EXCLUDE_FILES.forEach(function (f) {
  if (!fs.existsSync(f)) { console.error('  --exclude not found, ignoring: ' + f); return; }
  const ls = fs.readFileSync(f, 'utf8').split(/\r?\n/);
  const h = parseCsv(ls[0])[0].map(x => x.trim().toLowerCase());
  const ni = h.indexOf('name');
  if (ni === -1) return;
  let added = 0;
  for (let i = 1; i < ls.length; i++) {
    if (!ls[i]) continue;
    const c = parseCsv(ls[i])[0];
    if (!c || !c[ni]) continue;
    alreadyHave.add(stripSuffix(c[ni].trim()).toLowerCase());
    added++;
  }
  console.log('  excluding ' + added.toLocaleString() + ' names already held, from ' + f);
});

// Not congregations. Measured in this file: San Martin Athletic
// Association, San Antonio TEC and a handful like them are listed as
// churches on the site and are not.
const NOT_A_CHURCH = /\b(athletic association|cyo|cemeter(y|ies)|school|academy|bookstore|thrift|credit union|food bank)\b/i;

const clean = [], skipped = [], already = [];
const seen = new Set();
let noAddress = 0;

for (let i = 1; i < rows.length; i++) {
  const r = rows[i];
  const rawName = tidy(r[ix.name]);
  if (!rawName) continue;

  // schema_address is "street \n City, ST ZIP \n Country".
  const parts = String(r[ix.schema_address] || '').split('\n').map(s => s.trim()).filter(Boolean);
  const street = parts[0] || '';
  const cityLine = parts[1] || '';
  if (!street || !/,\s*[A-Za-z]{2}\s*\d{5}/.test(cityLine)) { noAddress++; continue; }
  const address = street + ', ' + cityLine;

  const name = stripSuffix(rawName);
  const key = name.toLowerCase() + '|' + address.toLowerCase();
  if (seen.has(key)) continue;
  seen.add(key);

  const row = {
    name: name,
    denomination: tidy(r[ix.denomination]),
    address: address,
    phone: tidy(r[ix.telephone] || r[ix.schema_telephone]),
    zip3: ((cityLine.match(/(\d{5})/) || [])[1] || '').slice(0, 3),
    city: (cityLine.split(',')[0] || '').trim().toUpperCase()
  };

  if (NOT_A_CHURCH.test(rawName)) { row.reason = 'not a congregation'; skipped.push(row); continue; }
  if (alreadyHave.has(name.toLowerCase())) { already.push(row); continue; }
  clean.push(row);
}

// Same ZIP3 grouping and data-derived labelling as prep-texas.js, so
// batch names line up between the two sources.
const groups = new Map();
clean.forEach(r => {
  const k = r.zip3 || '000';
  if (!groups.has(k)) groups.set(k, []);
  groups.get(k).push(r);
});
const batches = [...groups.entries()].map(([zip3, rs]) => {
  const cities = {};
  rs.forEach(r => (cities[r.city] = (cities[r.city] || 0) + 1));
  const top = Object.entries(cities).sort((a, b) => b[1] - a[1])[0];
  return { zip3, label: top ? top[0] : 'UNKNOWN', rows: rs, cities: Object.keys(cities).length };
}).sort((a, b) => b.rows.length - a.rows.length);

fs.mkdirSync(OUT, { recursive: true });
fs.readdirSync(OUT).filter(f => f.endsWith('.csv')).forEach(f => fs.unlinkSync(path.join(OUT, f)));
const slug = s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const HEAD = 'name,denomination,address,phone';

batches.forEach(b => {
  b.file = 'cf-' + b.zip3 + '-' + slug(b.label) + '.csv';
  fs.writeFileSync(path.join(OUT, b.file),
    HEAD + '\n' + b.rows.map(r => csvLine([r.name, r.denomination, r.address, r.phone])).join('\n') + '\n');
});
fs.writeFileSync(path.join(OUT, '_skipped.csv'),
  'name,denomination,address,phone,reason\n' +
  skipped.map(r => csvLine([r.name, r.denomination, r.address, r.phone, r.reason])).join('\n') + '\n');
fs.writeFileSync(path.join(OUT, '_already-held.csv'),
  HEAD + '\n' + already.map(r => csvLine([r.name, r.denomination, r.address, r.phone])).join('\n') + '\n');
fs.writeFileSync(path.join(OUT, '_manifest.csv'),
  'file,zip3,label,rows,distinct_cities\n' +
  batches.map(b => csvLine([b.file, b.zip3, b.label, b.rows.length, b.cities])).join('\n') + '\n');

console.log('\nRead              ' + (rows.length - 1).toLocaleString() + ' scraped rows');
console.log('  no usable address ' + noAddress.toLocaleString());
console.log('  not a congregation ' + skipped.length.toLocaleString() + '  _skipped.csv');
if (alreadyHave.size) console.log('  already held      ' + already.length.toLocaleString() + '  _already-held.csv');
console.log('\nReady to enrich   ' + clean.length.toLocaleString() + '  in ' + batches.length + ' batches');
console.log('  with a phone    ' + clean.filter(r => r.phone).length.toLocaleString());
console.log('  with a denomination ' + clean.filter(r => r.denomination).length.toLocaleString());
batches.slice(0, 10).forEach(b => console.log('  ' + String(b.rows.length).padStart(5) + '  ' + b.file));
console.log('\nWritten to ' + OUT + '/  -- same shape as texas-batches, so tools/enrich-batch.js takes it as-is');
