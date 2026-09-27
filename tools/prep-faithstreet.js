#!/usr/bin/env node
//
// Turns the faithstreet.com Texas scrape into import-ready batches, the
// same shape prep-texas.js and prep-churchfinder.js produce, so the same
// enrich/import pipeline takes it.
//
//   node tools/prep-faithstreet.js --in fss
//   node tools/prep-faithstreet.js --in fss --exclude live-churches.csv
//
// ---------------------------------------------------------------------
// WHAT THIS SOURCE IS
//
// One CSV per listing letter -- the site indexes Texas cities
// alphabetically -- with one row per church profile. The scrape visits
// every city page for a letter, presses "load more" to the end, and
// opens each profile.
//
// Measured on the a-o files (34,644 rows, 18,822 unique profiles):
//
//   street with a house number   18,138   96%
//   city                         18,634   99%
//   phone                        15,744   84%
//   website                       9,836   52%
//   denomination, once cleaned   15,832   84%
//
// Better address and phone coverage than either source before it, and a
// denomination on five churches in six.
//
// ---------------------------------------------------------------------
// WHAT IT DOES NOT HAVE
//
// No ZIP and no coordinates. prep-texas.js and prep-churchfinder.js
// batch by ZIP3; there is no ZIP here, so this batches by city instead
// and splits the big ones. enrich-batch.js only needs a street number
// plus a city or a ZIP to verify a Places hit, so street + "City, TX"
// is enough for it -- see its verifyAddress().
//
// ---------------------------------------------------------------------
// TWO THINGS WRONG WITH THE DENOMINATION COLUMN
//
// 1. "Edit denomination" appears 2,118 times. It is the page's own edit
//    link, scraped as a value. It is not a denomination and must not be
//    imported as one.
//
// 2. On 7,627 rows the denomination is identical to the service column,
//    and the service column holds worship style. That is why "Casual",
//    "Traditional Hymns", "Youth Group", "A cappella" and "Nursery"
//    turn up where a denomination belongs. NOT_A_DENOMINATION below is
//    that whole set, gathered from the 163 distinct values actually
//    present rather than guessed at.
//
// Both become blank rather than being dropped -- the church is still
// real, and index.html fills a blank denomination from the tags (see
// migration 100).
//
'use strict';

const fs = require('fs');
const path = require('path');

function arg(name, fallback) {
  const i = process.argv.indexOf('--' + name);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}
const IN = arg('in', 'fss');
const OUT = arg('out', 'faithstreet-batches');
const MAX = parseInt(arg('max', '400'), 10);
const EXCLUDE_FILES = arg('exclude', '').split(',').map(s => s.trim()).filter(Boolean);

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

// Same corporate-suffix rule as the other two preps and as index.html.
// Kept in sync by hand.
const CORPORATE_SUFFIX_RE = /,?\s*\b(?:(?:an?\s+)?(?:(?:domestic|texas|state\s+of\s+texas)\s+)*non[\s-]?profit\b|l\.l\.c\.|(?:incorporated|incorporation|corporation|inc|corp|llc|ltd|limited)\b).*$/i;
function stripSuffix(name) {
  const out = String(name || '').replace(CORPORATE_SUFFIX_RE, '').replace(/[\s,]+$/, '');
  return out || String(name || '');
}
const tidy = s => String(s || '').replace(/\s+/g, ' ').trim();

// Names here are human-written and already mixed case, so they are left
// alone -- title-casing would turn "First UMC" into "First Umc". Only a
// name that arrives SHOUTING gets touched.
const ACRONYMS = new Set(['UMC', 'LCMS', 'ELCA', 'PCA', 'PCUSA', 'COGIC', 'AME', 'CME', 'SDA',
  'UCC', 'ABC', 'CBF', 'AG', 'UPCI', 'FBC', 'FUMC', 'SBC', 'II', 'III', 'IV', 'USA', 'US', 'TX',
  'St', 'Sts']);
function fixShouting(name) {
  if (!/[a-z]/.test(name) && /[A-Z]{4,}/.test(name)) {
    return name.split(/(\s+|-)/).map(w => {
      const u = w.toUpperCase();
      if (ACRONYMS.has(u)) return u;
      if (!/[A-Za-z]/.test(w)) return w;
      return w.charAt(0).toUpperCase() + w.slice(1).toLowerCase();
    }).join('');
  }
  return name;
}

// Not congregations. Same list as prep-churchfinder.js, which measured
// them in a comparable scrape.
const NOT_A_CHURCH = /\b(athletic association|cyo|cemeter(y|ies)|school|academy|bookstore|thrift|credit union|food bank)\b/i;

// A PO Box is a mailbox, not a building: 1,257 of the a-o rows carry one
// as their only address, and geocoding those drops the pin on a post
// office. Held back rather than imported -- but the church is real, and
// its name plus city is enough for enrich-batch.js to find the street
// address later, so they go to their own file instead of the bin.
const PO_BOX = /\bP\.?\s?O\.?\s+box\b/i;

// Worship style, ministry names and the page's own edit link, all of
// which land in the denomination column. Every one of these was present
// in the a-o files; this is not a precautionary list.
const NOT_A_DENOMINATION = new Set([
  'edit denomination',
  'casual', 'contemporary', 'traditional liturgy', 'traditional hymns', 'blended',
  'spirit-filled', 'down to earth', 'friendly', 'old-school', 'creative', 'progressive',
  'conservative', 'multigenerational', 'downtown', 'neighborhood-focused', 'hillsong-style',
  'passionate reverent', 'praise and worship', 'a cappella', 'choir', 'liturgical', 'formal',
  'community service', 'youth group', 'young adults', 'missions', 'nursery', 'school',
  'faith and work', 'social justice', 'addiction/recovery'
]);

// faithstreet's vocabulary -> the display vocabulary index.html can
// translate (see denomI18nKeyMap there). Anything not listed is kept
// verbatim: a specific body is better than a blank, and the unmapped
// ones are reported at the end so this list can grow from real data.
const DENOM_MAP = new Map(Object.entries({
  'Southern Baptist Convention': 'Southern Baptist',
  'Independent Baptist': 'Baptist',
  'Baptist (CBA)': 'Baptist',
  'Baptist (ABA)': 'Baptist',
  'Baptist (NABC)': 'Baptist',
  'Baptist (BBFI)': 'Baptist',
  'Baptist (7th Day)': 'Baptist',
  'Baptist (Alliance of Baptists)': 'Baptist',
  'Baptist (CBF)': 'Cooperative Baptist Fellowship',
  'American Baptist Churches USA': 'Baptist',
  'Free Will Baptists (NAFWB)': 'Baptist',
  'General Association of Regular Baptist Churches': 'Baptist',
  'Nondenominational': 'Non-denominational',
  'Independent': 'Non-denominational',
  'United Methodist Church': 'United Methodist',
  'Global Methodist Church': 'Methodist',
  'Methodist (EMC)': 'Methodist',
  'Methodist (FMCUSA)': 'Methodist',
  'Christian Methodist Episcopal Church': 'Methodist',
  'African Methodist Episcopal Church': 'Methodist',
  'African Methodist Episcopal Zion Church': 'Methodist',
  'Presbyterian (PCUSA)': 'Presbyterian',
  'Presbyterian (PCA)': 'Presbyterian',
  'Presbyterian (CPC)': 'Presbyterian',
  'Presbyterian (EPC)': 'Presbyterian',
  'Presbyterian (ARPC)': 'Presbyterian',
  'Presbyterian (RPCNA)': 'Presbyterian',
  'Presbyterian (PCA-Korean)': 'Presbyterian',
  'Lutheran (LCMS)': 'Lutheran',
  'Lutheran (ELCA)': 'Lutheran',
  'Lutheran (WELS)': 'Lutheran',
  'Lutheran (AFLC)': 'Lutheran',
  'Lutheran (NALC)': 'Lutheran',
  'Lutheran (LCMC)': 'Lutheran',
  'Lutheran (ELS)': 'Lutheran',
  'Lutheran (CLC)': 'Lutheran',
  'Lutheran Brethren (CLB)': 'Lutheran',
  'Catholic (PNCC)': 'Catholic',
  'Catholic (NAOCC)': 'Catholic',
  'Anglican Catholic': 'Anglican',
  'Anglican (REC)': 'Anglican',
  'Anglican (Christ the King)': 'Anglican',
  'Orthodox (AOCANA)': 'Orthodox',
  'Orthodox (Greek)': 'Orthodox',
  'Orthodox (Syrian)': 'Orthodox',
  'Orthodox (Serbian)': 'Orthodox',
  'Orthodox (ROCOR)': 'Orthodox',
  'Orthodox (OCA)': 'Orthodox',
  'Orthodox-Catholic (OCCA)': 'Orthodox',
  'Coptic': 'Orthodox',
  'United Pentecostal Church International': 'Pentecostal',
  'Pentecostal Church of God': 'Pentecostal',
  'Pentecostal (PCAF)': 'Pentecostal',
  'Pentecostal (WPF)': 'Pentecostal',
  'Congregational Holiness Church': 'Pentecostal',
  'Apostolic Assembly of the Faith in Christ Jesus': 'Apostolic',
  'Assemblies of the Lord Jesus Christ': 'Apostolic',
  'Apostolic Faith Church': 'Apostolic',
  'Apostolic Overcoming Holy Church of God': 'Apostolic',
  'Apostolic Christian Church': 'Apostolic',
  'Apostolic Church of Jesus Christ': 'Apostolic',
  'Apostolic Light Fellowship': 'Apostolic',
  'The Way of the Cross Church International': 'Apostolic',
  'Church of God (Cleveland, TN)': 'Church of God',
  'Church of God (Anderson, IN)': 'Church of God',
  'Church of God (7th Day)': 'Church of God',
  'Church of God of Prophecy': 'Church of God',
  'Church of God in Christ': 'Church of God',
  'Christian Churches and Churches of Christ': 'Church of Christ',
  'Churches of Christ in Christian Union': 'Church of Christ',
  'Church of Christ (Holiness) USA': 'Church of Christ',
  'Church of Christ (GHCOC)': 'Church of Christ',
  'Bible Church of Christ': 'Church of Christ',
  'Seventh-day Adventist': 'Seventh-day Adventist',
  'Advent Christian Church': 'Adventist',
  'Church of the Nazarene': 'Church of the Nazarene',
  'Salvation Army': 'The Salvation Army',
  'United House of Prayer': 'Pentecostal',
  'Christian Reformed Church': 'Reformed',
  'Reformed (RCA)': 'Reformed',
  'Reformed (RCUS)': 'Reformed',
  'Reformed': 'Reformed',
  'United Church of Christ': 'United Church of Christ',
  'Unity of the Brethren': 'Congregational',
  'Church of the Brethren': 'Congregational',
  'Fellowship of Grace Brethren Churches': 'Congregational',
  'Quaker (FGC)': 'Quaker',
  'Evangelical Friends Church': 'Quaker',
  'Mennonite (MCUSA)': 'Mennonite',
  'Mennonite (USMB)': 'Mennonite',
  'Mennonite (CMC)': 'Mennonite',
  'Evangelical Free Church of America': 'Evangelical',
  'Evangelical Covenant Church': 'Evangelical',
  'Christian and Missionary Alliance': 'Evangelical',
  'Converge Worldwide': 'Evangelical',
  'Grace Gospel Fellowship': 'Evangelical',
  'Grace Communion International': 'Evangelical',
  'Sovereign Grace Believers': 'Evangelical',
  'Bible Fellowship Church': 'Bible Church',
  'Missionary Church': 'Evangelical',
  'Liberty Church Planting Network': 'Evangelical',
  'Foursquare': 'Foursquare',
  'Vineyard': 'Charismatic',
  'Victory Outreach': 'Charismatic',
  'Calvary Chapel': 'Calvary Chapel',
  'Disciples of Christ': 'Disciples of Christ',
  'Christian Congregation': 'Christian / General',
  'Christian Church': 'Christian / General',
  'Interdenominational': 'Interdenominational',
  'Metropolitan Community Church': 'Christian / General',
  'Amana Church Society': 'Christian / General',
  'New Apostolic Church (USA)': 'Apostolic',
  'True Jesus Church': 'Christian / General',
  'Mar Thoma Church': 'Orthodox',
  'Bethel Ministerial Assoc.': 'Pentecostal',
  'Open Bible Standard Churches': 'Pentecostal',
  'United Assemblies of Christ Intl.': 'Pentecostal',
  'Jews For Jesus': 'Messianic Judaism',
  'Messianic': 'Messianic Judaism',
  'Wesleyan': 'Methodist',
  'Charismatic': 'Charismatic',
  'Assemblies of God': 'Assemblies of God',
  'Catholic': 'Catholic',
  'Episcopal': 'Episcopal',
  'Baptist': 'Baptist',
  'Presbyterian': 'Presbyterian',
  'Methodist': 'Methodist',
  'Lutheran': 'Lutheran',
  'Anglican': 'Anglican',
  'Orthodox': 'Orthodox',
  'Pentecostal': 'Pentecostal',
  'Apostolic': 'Apostolic',
  'Quaker': 'Quaker',
  'Church of Christ': 'Church of Christ',
  'Orthodox Christian': 'Orthodox',
  'Progressive Church': 'Christian / General'
}));

function cleanDenomination(raw, unmapped) {
  const v = tidy(raw);
  if (!v) return '';
  if (NOT_A_DENOMINATION.has(v.toLowerCase())) return '';
  if (DENOM_MAP.has(v)) return DENOM_MAP.get(v);
  unmapped.set(v, (unmapped.get(v) || 0) + 1);
  return v;
}

// ---------------------------------------------------------------------

if (!fs.existsSync(IN) || !fs.statSync(IN).isDirectory()) {
  console.error('Not a directory: ' + IN + '\nPass --in <folder of faithstreet CSVs>');
  process.exit(1);
}
const files = fs.readdirSync(IN).filter(f => f.toLowerCase().endsWith('.csv')).sort();
if (!files.length) { console.error('No CSVs in ' + IN); process.exit(1); }

const alreadyHave = new Set();
EXCLUDE_FILES.forEach(function (f) {
  if (!fs.existsSync(f)) { console.error('  --exclude not found, ignoring: ' + f); return; }
  const rows = parseCsv(fs.readFileSync(f, 'utf8'));
  const h = rows[0].map(x => x.replace(/^﻿/, '').trim().toLowerCase());
  const ni = h.indexOf('name');
  if (ni === -1) { console.error('  --exclude has no "name" column: ' + f); return; }
  let added = 0;
  for (let i = 1; i < rows.length; i++) {
    const c = rows[i];
    if (!c || !c[ni]) continue;
    alreadyHave.add(stripSuffix(tidy(c[ni])).toLowerCase());
    added++;
  }
  console.log('  excluding ' + added.toLocaleString() + ' names already held, from ' + f);
});

const clean = [], skipped = [], poBox = [];
const seenProfile = new Set();   // the site's own id for a church
const seenRow = new Set();       // belt and braces: name + address
const unmapped = new Map();
let rawRows = 0, dupProfile = 0, noAddress = 0, already = 0, letters = new Set();

for (const f of files) {
  const rows = parseCsv(fs.readFileSync(path.join(IN, f), 'utf8'));
  if (!rows.length) continue;
  // The export carries a UTF-8 BOM on the first header cell.
  const header = rows[0].map(x => x.replace(/^﻿/, '').trim());
  const ix = {};
  header.forEach((h, i) => (ix[h] = i));
  for (const need of ['church_name', 'street', 'city', 'profile_link-href']) {
    if (ix[need] === undefined) {
      console.error('  ' + f + ': no "' + need + '" column -- skipping this file');
      ix.__bad = true;
    }
  }
  if (ix.__bad) continue;

  for (let i = 1; i < rows.length; i++) {
    const r = rows[i];
    if (!r || r.length < header.length - 2) continue;
    rawRows++;

    const start = tidy(r[ix.web_scraper_start_url]);
    const m = /\/cities\/([a-z0-9]+)$/.exec(start);
    if (m) letters.add(m[1]);

    const href = tidy(r[ix['profile_link-href']]);
    if (href) {
      if (seenProfile.has(href)) { dupProfile++; continue; }
      seenProfile.add(href);
    }

    const rawName = tidy(r[ix.church_name]);
    if (!rawName) continue;
    const name = fixShouting(stripSuffix(rawName));

    const street = tidy(r[ix.street]);
    // "Lyons, TX" -- the church's own city, which is not always the
    // listing page's city, so this column is the one to trust.
    const cityRaw = tidy(r[ix.city]);
    const cm = /^(.*?),\s*([A-Za-z]{2})$/.exec(cityRaw);
    const city = cm ? tidy(cm[1]) : cityRaw;
    const state = cm ? cm[2].toUpperCase() : '';
    // enrich-batch.js needs a house number and a city to verify a hit.
    if (!street || !/\d/.test(street) || !city) { noAddress++; continue; }

    const address = street + ', ' + city + (state ? ', ' + state : '');
    const key = name.toLowerCase() + '|' + address.toLowerCase();
    if (seenRow.has(key)) { dupProfile++; continue; }
    seenRow.add(key);

    const row = {
      name: name,
      denomination: cleanDenomination(r[ix.denomination], unmapped),
      address: address,
      phone: tidy(r[ix.phone]),
      website: tidy(r[ix['website-href']]),
      city: city.toUpperCase()
    };

    if (NOT_A_CHURCH.test(rawName)) { row.reason = 'not a congregation'; skipped.push(row); continue; }
    // A PO Box is a mailbox, not a building. Geocoding one drops the
    // pin on a post office, so these are held back -- but the church is
    // real, and name plus city is enough for enrich-batch.js to find
    // its street address later.
    if (PO_BOX.test(street)) { poBox.push(row); continue; }
    if (alreadyHave.has(name.toLowerCase())) { already++; continue; }
    clean.push(row);
  }
}

// Batched by city, because there is no ZIP here. A city bigger than
// --max is split into numbered parts so no batch is too large to review
// by hand, which is the whole point of batching.
const groups = new Map();
clean.forEach(r => {
  if (!groups.has(r.city)) groups.set(r.city, []);
  groups.get(r.city).push(r);
});
// A city big enough to review on its own gets its own batch, split into
// parts if it is very big. Everything else is packed alphabetically
// into full batches -- one file per town gave 1,116 files, most of them
// holding a single church, which is not a reviewable unit.
const BIG = 40;
const batches = [];
const tail = [];
[...groups.entries()].sort((a, b) => a[0].localeCompare(b[0])).forEach(([city, rs]) => {
  if (rs.length < BIG) { tail.push(...rs); return; }
  if (rs.length <= MAX) { batches.push({ label: city, rows: rs, part: 0 }); return; }
  for (let i = 0; i < rs.length; i += MAX) {
    batches.push({ label: city, rows: rs.slice(i, i + MAX), part: Math.floor(i / MAX) + 1 });
  }
});
for (let i = 0; i < tail.length; i += MAX) {
  const chunk = tail.slice(i, i + MAX);
  // Labelled by the towns at each end, so the file name says what is in it.
  const a = chunk[0].city, b = chunk[chunk.length - 1].city;
  batches.push({ label: 'towns-' + a + (a === b ? '' : '-to-' + b), rows: chunk, part: 0 });
}

fs.mkdirSync(OUT, { recursive: true });
fs.readdirSync(OUT).filter(f => f.endsWith('.csv')).forEach(f => fs.unlinkSync(path.join(OUT, f)));
const slug = s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const HEAD = 'name,denomination,address,phone,website';

batches.forEach(b => {
  b.file = 'fs-' + slug(b.label) + (b.part ? '-' + b.part : '') + '.csv';
  fs.writeFileSync(path.join(OUT, b.file),
    HEAD + '\n' + b.rows.map(r => csvLine([r.name, r.denomination, r.address, r.phone, r.website])).join('\n') + '\n');
});
fs.writeFileSync(path.join(OUT, '_po-box-only.csv'),
  HEAD + '\n' +
  poBox.map(r => csvLine([r.name, r.denomination, r.address, r.phone, r.website])).join('\n') + '\n');
fs.writeFileSync(path.join(OUT, '_skipped.csv'),
  'name,denomination,address,phone,reason\n' +
  skipped.map(r => csvLine([r.name, r.denomination, r.address, r.phone, r.reason])).join('\n') + '\n');
fs.writeFileSync(path.join(OUT, '_manifest.csv'),
  'file,city,rows\n' + batches.map(b => csvLine([b.file, b.label, b.rows.length])).join('\n') + '\n');
if (unmapped.size) {
  fs.writeFileSync(path.join(OUT, '_unmapped-denominations.csv'),
    'denomination,count\n' +
    [...unmapped.entries()].sort((a, b) => b[1] - a[1]).map(e => csvLine(e)).join('\n') + '\n');
}

const az = 'abcdefghijklmnopqrstuvwxyz'.split('');
const missing = az.filter(l => !letters.has(l));
const withDenom = clean.filter(r => r.denomination).length;
const withPhone = clean.filter(r => r.phone).length;
const withSite = clean.filter(r => r.website).length;

console.log('');
console.log('read          ' + files.length + ' files, ' + rawRows.toLocaleString() + ' rows');
console.log('duplicates    ' + dupProfile.toLocaleString() + ' (same profile, or same name at the same address)');
console.log('no address    ' + noAddress.toLocaleString() + ' (no street number, or no city)');
if (already) console.log('already held  ' + already.toLocaleString());
console.log('not a church  ' + skipped.length.toLocaleString() + '  -> _skipped.csv');
console.log('PO box only   ' + poBox.length.toLocaleString() + '  -> _po-box-only.csv (real churches, unusable address)');
console.log('WRITTEN       ' + clean.length.toLocaleString() + ' churches in ' + batches.length + ' batches -> ' + OUT + '/');
console.log('');
console.log('  denomination ' + withDenom.toLocaleString() + '  (' + Math.round(withDenom / clean.length * 100) + '%)');
console.log('  phone        ' + withPhone.toLocaleString() + '  (' + Math.round(withPhone / clean.length * 100) + '%)');
console.log('  website      ' + withSite.toLocaleString() + '  (' + Math.round(withSite / clean.length * 100) + '%)');
if (unmapped.size) {
  console.log('');
  console.log('  ' + unmapped.size + ' denominations kept verbatim -- no mapping yet.');
  console.log('  See ' + OUT + '/_unmapped-denominations.csv; the top few:');
  [...unmapped.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5)
    .forEach(e => console.log('    ' + String(e[1]).padStart(5) + '  ' + e[0]));
}
console.log('');
console.log('listing letters scraped: ' + [...letters].sort().join(' '));
if (missing.length) {
  console.log('MISSING letters:         ' + missing.join(' '));
  console.log('  Cities starting with those letters are not in this run at all.');
}
