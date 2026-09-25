#!/usr/bin/env node
//
// Looks up one prepared batch against Google Places and splits it into
// what is worth importing and what is not. Run BEFORE importing, so
// nothing is geocoded or stored that a lookup says is not there.
//
//   set GOOGLE_PLACES_KEY=...            (PowerShell: $env:GOOGLE_PLACES_KEY="...")
//   node tools/enrich-batch.js --file texas-batches/787-austin.csv
//
//   --limit 5     stop after 5 lookups. Do this first on any new batch.
//   --dry-run     no network, no spend; exercises everything else.
//
// Writes next to the input:
//   <batch>.enriched.csv        every row + phone, website, matched,
//                               match_detail, place_types
//   <batch>.yes.csv             matched = yes, in the importer's own
//                               columns -- this is the file to import
//   <batch>.no.csv              nothing found at that address
//   <batch>.type-mismatch.csv   found, but Google does not call it a
//                               place of worship -- read these
//
// ---------------------------------------------------------------------
// WHY THESE FOUR FILES
//
// Taken from what the San Antonio run actually produced, not invented:
// 1,443 enriched rows -> phone on 689 (48%), website on 618 (43%),
// and a matched verdict of 761 yes / 682 no. The yes-only file was
// exactly the matched=yes rows -- 640 of 1,282, confirmed by counting
// both files rather than assuming the rule.
//
// place_types was a SEPARATE signal, not part of that cut: of the 640
// confirmed matches, 529 carried church or place_of_worship and 108
// did not, and those went to their own file to be read. That split is
// reproduced here. A row can be a real place at a real address and
// still be a dentist's office sharing the building -- "Christ Is Life
// Ministries ... establishment; health; point_of_interest" is a real
// example from that file.
//
// ---------------------------------------------------------------------
// COST, AND WHY THE CACHE EXISTS
//
// One billable Places call per church. Requesting phone, website and
// types puts it in a dearer SKU than a bare search -- check the current
// rate in your own Google console rather than trusting a number here.
// At 14,786 rows across the state this is the expensive step of the
// whole pipeline, which is why batches exist and why --limit does.
//
// Every result is appended to .enrich-cache.jsonl the moment it lands,
// so an interrupted run resumes without paying twice, and re-running a
// batch after editing the rules costs nothing for rows already looked
// up. A FAILURE IS NOT CACHED -- only an answer from Google is. A
// timeout or a quota error means "unknown", and caching that would
// permanently mark a real church as missing. That exact trap was
// already hit once, in the coverage map's town cache.
//
// ---------------------------------------------------------------------
// THE KEY IS NOT THE ONE IN THE PAGE
//
// index.html ships a browser key restricted by HTTP referrer, which is
// why localhost gets RefererNotAllowedMapError. A server-side call has
// no referrer and that key will refuse it. Make a SECOND key in Google
// Cloud Console, restrict it by IP and to the Places API, and pass it
// in the environment. Never put it in a file in this repo -- the repo
// is public.

const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------- args
const args = process.argv.slice(2);
const has = n => args.includes('--' + n);
function arg(n, d) { const i = args.indexOf('--' + n); return i !== -1 && args[i + 1] ? args[i + 1] : d; }

const FILE = arg('file', '');
const LIMIT = parseInt(arg('limit', '0'), 10) || 0;
const DRY = has('dry-run');
const KEY = process.env.GOOGLE_PLACES_KEY || '';
const PAUSE_MS = parseInt(arg('pause', '120'), 10);

if (!FILE) {
  console.error('Usage: node tools/enrich-batch.js --file texas-batches/<batch>.csv [--limit N] [--dry-run]');
  process.exit(1);
}
if (!fs.existsSync(FILE)) { console.error('No such file: ' + FILE); process.exit(1); }
if (!KEY && !DRY) {
  console.error('GOOGLE_PLACES_KEY is not set.\n' +
    '  PowerShell:  $env:GOOGLE_PLACES_KEY="..."\n' +
    '  bash:        export GOOGLE_PLACES_KEY=...\n' +
    'It must be a SERVER key (IP-restricted), not the referrer-restricted browser key in index.html.\n' +
    'Use --dry-run to exercise everything except the lookups.');
  process.exit(1);
}

// ----------------------------------------------------------------- csv
function splitCsvLine(line) {
  const out = []; let f = ''; let q = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) { if (c === '"') { if (line[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
    else if (c === '"') q = true;
    else if (c === ',') { out.push(f); f = ''; }
    else f += c;
  }
  out.push(f); return out;
}
const q = v => { const s = String(v == null ? '' : v); return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
const csvLine = cells => cells.map(q).join(',');

const lines = fs.readFileSync(FILE, 'utf8').split(/\r?\n/).filter(l => l.length);
const header = splitCsvLine(lines[0]).map(h => h.trim().toLowerCase());
const iName = header.indexOf('name'), iDenom = header.indexOf('denomination'), iAddr = header.indexOf('address');
if (iName === -1 || iAddr === -1) {
  console.error('That CSV has no name/address column -- is it a prepared batch?');
  process.exit(1);
}
const rows = lines.slice(1).map(splitCsvLine).map(c => ({
  name: (c[iName] || '').trim(),
  denomination: iDenom === -1 ? '' : (c[iDenom] || '').trim(),
  address: (c[iAddr] || '').trim()
})).filter(r => r.name && r.address);

// --------------------------------------------------------------- cache
// A DRY RUN GETS ITS OWN CACHE AND ITS OWN FILENAMES, and this is not
// tidiness. The first version shared both: one dry run wrote 411
// fabricated results into the real cache and left 787-austin.yes.csv
// sitting on disk full of invented phone numbers and websites. A later
// real run would have served those fakes from cache without one
// billable call, and they would have gone into the database looking
// exactly like data. Same family of mistake as caching a failed
// geocode -- something that is not an answer being stored as one.
const CACHE = path.join(path.dirname(FILE), DRY ? '.enrich-cache.dryrun.jsonl' : '.enrich-cache.jsonl');
const cache = new Map();
if (fs.existsSync(CACHE)) {
  fs.readFileSync(CACHE, 'utf8').split(/\r?\n/).forEach(l => {
    if (!l.trim()) return;
    // One bad line must not throw away a cache that cost real money.
    try { const o = JSON.parse(l); if (o && o.k) cache.set(o.k, o.v); } catch (e) {}
  });
}
const keyOf = r => (r.name + '|' + r.address).toLowerCase();
function remember(k, v) {
  cache.set(k, v);
  fs.appendFileSync(CACHE, JSON.stringify({ k, v }) + '\n');
}

// --------------------------------------------------------------- lookup
const FIELD_MASK = [
  'places.displayName', 'places.formattedAddress',
  'places.nationalPhoneNumber', 'places.websiteUri', 'places.types'
].join(',');

async function lookup(row) {
  if (DRY) {
    // Deterministic, so a dry run is repeatable: every third row is a
    // miss, and every fifth hit has no worship type. Enough to exercise
    // all four output files without a network call.
    const h = (row.name + row.address).split('').reduce((a, c) => (a * 31 + c.charCodeAt(0)) >>> 0, 7);
    if (h % 3 === 0) return { matched: 'no', detail: '', phone: '', website: '', types: '' };
    return {
      matched: 'yes',
      detail: row.name + ' — ' + row.address + ' (dry run)',
      phone: h % 2 ? '(210) 555-0' + String(h % 1000).padStart(3, '0') : '',
      website: h % 4 ? 'https://example.org/' + (h % 9999) : '',
      types: (h % 5 === 0) ? 'establishment; point_of_interest' : 'church; place_of_worship; establishment'
    };
  }

  const res = await fetch('https://places.googleapis.com/v1/places:searchText', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': KEY,
      'X-Goog-FieldMask': FIELD_MASK
    },
    body: JSON.stringify({
      textQuery: row.name + ', ' + row.address,
      maxResultCount: 1,
      regionCode: 'US'
    })
  });

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    const err = new Error('HTTP ' + res.status + ' ' + body.slice(0, 200));
    err.status = res.status;
    throw err;
  }
  const data = await res.json();
  const p = (data.places || [])[0];
  if (!p) return { matched: 'no', detail: '', phone: '', website: '', types: '' };
  const label = (p.displayName && p.displayName.text) || row.name;
  return {
    matched: 'yes',
    detail: label + ' — ' + (p.formattedAddress || ''),
    phone: p.nationalPhoneNumber || '',
    website: p.websiteUri || '',
    types: (p.types || []).join('; ')
  };
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

// Retries only what is worth retrying. A 429 or a 5xx is the server
// asking us to wait; a 400 or 403 is the request or the key being wrong
// and will fail identically forever, so it stops the run rather than
// burning the whole batch against a bad key.
async function lookupWithRetry(row) {
  for (let attempt = 0; attempt < 4; attempt++) {
    try { return await lookup(row); }
    catch (e) {
      const s = e.status || 0;
      if (s === 400 || s === 401 || s === 403) throw e;
      if (attempt === 3) return null;               // unknown, NOT cached
      await sleep(600 * Math.pow(2, attempt));
    }
  }
  return null;
}

// ----------------------------------------------------------------- run
const WORSHIP = /\b(church|place_of_worship|synagogue|mosque|hindu_temple)\b/;

(async function main() {
  const base = FILE.replace(/\.csv$/i, '') + (DRY ? '.dryrun' : '');
  const enriched = [], yes = [], no = [], mismatch = [];
  let calls = 0, cached = 0, unknown = 0, done = 0;

  for (const row of rows) {
    const k = keyOf(row);
    let r = cache.get(k);
    if (r) cached++;
    else {
      if (LIMIT && calls >= LIMIT) break;
      r = await lookupWithRetry(row);
      calls++;
      if (r) remember(k, r);
      else { unknown++; r = { matched: '', detail: 'lookup failed', phone: '', website: '', types: '' }; }
      if (PAUSE_MS) await sleep(PAUSE_MS);
    }
    done++;
    if (done % 100 === 0) process.stdout.write('  ' + done + '/' + rows.length + ' (' + calls + ' calls)\r');

    enriched.push([row.name, row.denomination, row.address, r.phone, r.website, r.matched, r.detail, r.types]);
    if (r.matched === 'yes') {
      yes.push([row.name, row.denomination, row.address, r.phone, r.website]);
      if (!WORSHIP.test(r.types || '')) {
        mismatch.push([row.name, row.denomination, row.address, r.phone, r.website, r.matched, r.detail, r.types]);
      }
    } else if (r.matched === 'no') {
      no.push([row.name, row.denomination, row.address]);
    }
  }

  function write(suffix, head, data) {
    fs.writeFileSync(base + suffix, head + '\n' + data.map(csvLine).join('\n') + (data.length ? '\n' : ''));
  }
  write('.enriched.csv', 'name,denomination,address,phone,website,matched,match_detail,place_types', enriched);
  write('.yes.csv', 'name,denomination,address,phone,website', yes);
  write('.no.csv', 'name,denomination,address', no);
  write('.type-mismatch.csv', 'name,denomination,address,phone,website,matched,match_detail,place_types', mismatch);

  const pct = n => (enriched.length ? Math.round((n / enriched.length) * 100) : 0) + '%';
  console.log('\n' + path.basename(FILE) + (DRY ? '   [DRY RUN -- no lookups, no spend]' : ''));
  console.log('  rows in batch   ' + rows.length.toLocaleString());
  console.log('  looked at       ' + enriched.length.toLocaleString() + (LIMIT ? '   (--limit ' + LIMIT + ')' : ''));
  console.log('  billable calls  ' + calls.toLocaleString());
  console.log('  from cache      ' + cached.toLocaleString());
  if (unknown) console.log('  lookup failed   ' + unknown.toLocaleString() + '   not cached -- re-run to retry these');
  console.log('');
  console.log('  found           ' + yes.length.toLocaleString() + '  ' + pct(yes.length) + '  -> ' + path.basename(base) + '.yes.csv  (import this)');
  console.log('  not found       ' + no.length.toLocaleString() + '  ' + pct(no.length) + '  -> ' + path.basename(base) + '.no.csv');
  console.log('  found, but not a place of worship by type: ' + mismatch.length.toLocaleString() + '  -> ' + path.basename(base) + '.type-mismatch.csv');
  const withPhone = enriched.filter(r => r[3]).length, withSite = enriched.filter(r => r[4]).length;
  console.log('  phone           ' + withPhone.toLocaleString() + '  ' + pct(withPhone));
  console.log('  website         ' + withSite.toLocaleString() + '  ' + pct(withSite));
})().catch(e => {
  console.error('\nStopped: ' + e.message);
  console.error('Nothing already looked up is lost -- results are cached as they land, so re-running resumes.');
  process.exit(1);
});
