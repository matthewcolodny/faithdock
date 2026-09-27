#!/usr/bin/env node
//
// Turns an address into coordinates for one batch, or one metro's worth
// of batches, so the directory can put a pin on the map.
//
//   node tools/geocode-batch.js --metro san-antonio --dry-run
//   node tools/geocode-batch.js --metro san-antonio
//   node tools/geocode-batch.js --file faithstreet-batches/fs-houston-1.csv
//   node tools/geocode-batch.js --metros            (list them and stop)
//
// ---------------------------------------------------------------------
// WHY NOT enrich-batch.js
//
// That tool exists to FIND a church: it searches Places by name, then
// works hard to decide whether the thing that came back is the church
// you asked for, because the IRS source gave it a name and nothing
// else. It earned that complexity -- see its own header for the
// Big Bend Tabernacle / Big Bend Telephone Company case.
//
// This source already has a curated street address, a phone and often a
// website. Nothing needs finding. The only thing missing is a lat/lng,
// and plain geocoding answers that in a much cheaper SKU than a Places
// text search. At twenty thousand rows that difference is the whole
// bill. Check the current rates in your own console before a big run.
//
// ---------------------------------------------------------------------
// THE FAILURE THAT MATTERS
//
// A geocoder always answers. Ask it for a street it cannot find and it
// will happily hand back the middle of the town, with status OK, and
// nothing in the reply shouts about it -- you have to read
// location_type:
//
//   ROOFTOP               the building.               keep
//   RANGE_INTERPOLATED    between two known numbers.  keep
//   GEOMETRIC_CENTER      centre of a street.         keep, roughly right
//   APPROXIMATE           centre of the TOWN.         DO NOT KEEP
//
// An APPROXIMATE result is not a bad pin, it is the same pin for every
// church in that town, stacked on the courthouse. partial_match means
// Google matched some of the address and guessed the rest, which is the
// same problem wearing a different hat. Both are held back for review
// rather than written into the import.
//
// The returned city is checked against the one asked for as well, since
// a mistyped street can land the answer in another county entirely.
//
// ---------------------------------------------------------------------
// COST AND THE CACHE
//
// One billable call per address. Every answer is appended to
// .geocode-cache.jsonl the moment it lands, so an interrupted run
// resumes without paying twice and re-running after a rule change is
// free for rows already looked up. FAILURES ARE NOT CACHED -- a timeout
// or a quota error means "unknown", and remembering that as an answer
// would permanently mark a good address unresolvable. That mistake has
// already been made once in this repo, in the coverage map's town
// cache; do not make it again here.
//
// --dry-run invents coordinates, never calls Google, and writes to its
// own cache and its own filenames, so a rehearsal can never be mistaken
// for real data or poison the real cache.
//
'use strict';

const fs = require('fs');
const path = require('path');
const https = require('https');

const args = process.argv.slice(2);
function arg(n, d) { const i = args.indexOf('--' + n); return i !== -1 && args[i + 1] ? args[i + 1] : d; }
function has(n) { return args.indexOf('--' + n) !== -1; }

const DIR = arg('dir', 'faithstreet-batches');
const FILE = arg('file', '');
const METRO = (arg('metro', '') || '').toLowerCase();
const LIMIT = parseInt(arg('limit', '0'), 10) || 0;
const DRY = has('dry-run');
const CACHED_ONLY = has('cached-only');
const KEY = process.env.GOOGLE_GEOCODE_KEY || process.env.GOOGLE_PLACES_KEY || '';

// The metros worth doing as a unit. A batch belongs to a metro when its
// city is on the list; everything else is reachable with --file. These
// are the cities faithstreet actually returned, not a census definition.
const METROS = {
  'san-antonio': ['SAN ANTONIO', 'NEW BRAUNFELS', 'SCHERTZ', 'CIBOLO', 'CONVERSE', 'SELMA',
    'BOERNE', 'HELOTES', 'UNIVERSAL CITY', 'LIVE OAK', 'WINDCREST', 'LEON VALLEY',
    'SEGUIN', 'FLORESVILLE', 'PLEASANTON', 'CASTROVILLE', 'LA VERNIA'],
  'houston': ['HOUSTON', 'KATY', 'PEARLAND', 'SUGAR LAND', 'MISSOURI CITY', 'HUMBLE',
    'SPRING', 'CYPRESS', 'TOMBALL', 'CONROE', 'BAYTOWN', 'PASADENA', 'FRIENDSWOOD',
    'LEAGUE CITY', 'ROSENBERG', 'RICHMOND', 'STAFFORD', 'DEER PARK', 'LA PORTE',
    'CHANNELVIEW', 'CROSBY', 'KINGWOOD', 'ATASCOCITA', 'HUFFMAN', 'NEW CANEY'],
  'dfw': ['DALLAS', 'FORT WORTH', 'ARLINGTON', 'PLANO', 'GARLAND', 'IRVING', 'MESQUITE',
    'MCKINNEY', 'FRISCO', 'DENTON', 'CARROLLTON', 'RICHARDSON', 'LEWISVILLE', 'ALLEN',
    'GRAND PRAIRIE', 'FLOWER MOUND', 'MANSFIELD', 'ROWLETT', 'EULESS', 'DESOTO',
    'GRAPEVINE', 'BEDFORD', 'CEDAR HILL', 'WYLIE', 'KELLER', 'ROCKWALL', 'BURLESON',
    'HURST', 'DUNCANVILLE', 'AZLE', 'WEATHERFORD', 'WAXAHACHIE', 'CLEBURNE'],
  'austin': ['AUSTIN', 'ROUND ROCK', 'CEDAR PARK', 'GEORGETOWN', 'PFLUGERVILLE', 'LEANDER',
    'KYLE', 'SAN MARCOS', 'BUDA', 'HUTTO', 'LAKEWAY', 'BASTROP', 'TAYLOR',
    'WEST LAKE HILLS', 'DRIPPING SPRINGS'],
  'rio-grande-valley': ['MCALLEN', 'BROWNSVILLE', 'HARLINGEN', 'EDINBURG', 'MISSION',
    'PHARR', 'WESLACO', 'SAN BENITO', 'LA FERIA', 'MERCEDES', 'DONNA', 'ALAMO',
    'SAN JUAN', 'RIO GRANDE CITY', 'ELSA'],
  'el-paso': ['EL PASO', 'SOCORRO', 'HORIZON CITY', 'CANUTILLO', 'FABENS', 'CLINT'],
  'corpus-christi': ['CORPUS CHRISTI', 'PORTLAND', 'ROBSTOWN', 'ARANSAS PASS', 'KINGSVILLE',
    'ALICE', 'BEEVILLE', 'SINTON'],
  'waco': ['WACO', 'TEMPLE', 'KILLEEN', 'BELTON', 'HARKER HEIGHTS', 'COPPERAS COVE',
    'HEWITT', 'ROBINSON', 'WOODWAY', 'GATESVILLE'],
  'lubbock': ['LUBBOCK', 'PLAINVIEW', 'LEVELLAND', 'BROWNFIELD', 'SLATON', 'LITTLEFIELD'],
  'amarillo': ['AMARILLO', 'CANYON', 'BORGER', 'PAMPA', 'DUMAS', 'HEREFORD'],
  'permian-basin': ['MIDLAND', 'ODESSA', 'BIG SPRING', 'ANDREWS', 'MONAHANS', 'PECOS'],
  'east-texas': ['TYLER', 'LONGVIEW', 'MARSHALL', 'NACOGDOCHES', 'LUFKIN', 'PALESTINE',
    'HENDERSON', 'KILGORE', 'JACKSONVILLE', 'CARTHAGE', 'ATHENS'],
  'beaumont': ['BEAUMONT', 'PORT ARTHUR', 'ORANGE', 'NEDERLAND', 'VIDOR', 'SILSBEE',
    'GROVES', 'LUMBERTON'],
  'wichita-falls': ['WICHITA FALLS', 'BURKBURNETT', 'IOWA PARK', 'VERNON', 'BOWIE'],
  'abilene': ['ABILENE', 'SWEETWATER', 'SNYDER', 'BRECKENRIDGE', 'ANSON', 'MERKEL'],
  'san-angelo': ['SAN ANGELO', 'BROWNWOOD', 'BALLINGER', 'SONORA', 'OZONA'],
  'victoria': ['VICTORIA', 'PORT LAVACA', 'CUERO', 'GOLIAD', 'YOAKUM', 'EDNA'],
  'texarkana': ['TEXARKANA', 'MOUNT PLEASANT', 'PARIS', 'ATLANTA', 'NEW BOSTON'],
  'bryan': ['BRYAN', 'COLLEGE STATION', 'NAVASOTA', 'BRENHAM', 'HUNTSVILLE', 'MADISONVILLE'],
  'laredo': ['LAREDO', 'EAGLE PASS', 'DEL RIO', 'CARRIZO SPRINGS', 'ZAPATA']
};

function parseCsv(text) {
  const rows = []; let row = [], field = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else q = false; } else field += c; }
    else if (c === '"') q = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
    else if (c !== '\r') field += c;
  }
  if (field || row.length) { row.push(field); rows.push(row); }
  return rows;
}
const q = v => { const s = String(v == null ? '' : v); return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
const csvLine = cells => cells.map(q).join(',');
const cityOf = addr => {
  // "STREET, CITY, ST"
  const p = String(addr || '').split(',').map(s => s.trim()).filter(Boolean);
  return p.length >= 2 ? p[p.length - 2].toUpperCase() : '';
};

function batchFiles() {
  if (FILE) return [FILE];
  if (!fs.existsSync(DIR)) { console.error('No such directory: ' + DIR); process.exit(1); }
  const all = fs.readdirSync(DIR).filter(f => f.startsWith('fs-') && f.endsWith('.csv'));
  if (!METRO) return all.map(f => path.join(DIR, f));
  const cities = METROS[METRO];
  if (!cities) {
    console.error('Unknown metro: ' + METRO + '\nRun with --metros to see the list.');
    process.exit(1);
  }
  const want = new Set(cities);
  return all.filter(function (f) {
    const rows = parseCsv(fs.readFileSync(path.join(DIR, f), 'utf8'));
    for (let i = 1; i < rows.length && i < 6; i++) {
      if (rows[i] && want.has(cityOf(rows[i][2]))) return true;
    }
    return false;
  }).map(f => path.join(DIR, f));
}

function listMetros() {
  if (!fs.existsSync(DIR)) { console.error('No such directory: ' + DIR); return; }
  const all = fs.readdirSync(DIR).filter(f => f.startsWith('fs-') && f.endsWith('.csv'));
  const counts = {};
  all.forEach(function (f) {
    const rows = parseCsv(fs.readFileSync(path.join(DIR, f), 'utf8'));
    for (let i = 1; i < rows.length; i++) {
      if (!rows[i] || !rows[i][2]) continue;
      const c = cityOf(rows[i][2]);
      for (const m of Object.keys(METROS)) {
        if (METROS[m].indexOf(c) !== -1) { counts[m] = (counts[m] || 0) + 1; break; }
      }
    }
  });
  Object.keys(METROS).sort(function (a, b) { return (counts[b] || 0) - (counts[a] || 0); })
    .forEach(m => console.log('  ' + m.padEnd(20) + String(counts[m] || 0).padStart(6) + ' churches'));
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  console.log('  ' + '-'.repeat(26));
  console.log('  ' + 'covered'.padEnd(20) + String(total).padStart(6));
  console.log('\n  Anything not in a metro is still reachable with --file.');
}

// Below the helpers on purpose: listMetros reads cityOf, and a const
// arrow is not hoisted the way a function declaration is -- called from
// higher up it throws "cannot access before initialization".
if (has('metros')) {
  console.log('Metros this tool knows, and how many churches each covers:\n');
  listMetros();
  process.exit(0);
}

const files = batchFiles();
if (!files.length) { console.error('No batch files matched.'); process.exit(1); }
if (!KEY && !DRY && !CACHED_ONLY) {
  console.error('GOOGLE_GEOCODE_KEY is not set (GOOGLE_PLACES_KEY is accepted too).\n' +
    '  PowerShell:  $env:GOOGLE_GEOCODE_KEY="..."\n' +
    '  bash:        export GOOGLE_GEOCODE_KEY=...\n' +
    'Or pass --dry-run to rehearse without calling Google.');
  process.exit(1);
}

const CACHE = path.join(DIR, DRY ? '.geocode-cache.dryrun.jsonl' : '.geocode-cache.jsonl');
const cache = new Map();
if (fs.existsSync(CACHE)) {
  fs.readFileSync(CACHE, 'utf8').split(/\r?\n/).forEach(function (l) {
    if (!l.trim()) return;
    try { const o = JSON.parse(l); if (o && o.k) cache.set(o.k, o.v); } catch (e) {}
  });
}
function remember(k, v) {
  cache.set(k, v);
  fs.appendFileSync(CACHE, JSON.stringify({ k: k, v: v }) + '\n');
}

function geocode(address) {
  return new Promise(function (resolve) {
    const url = 'https://maps.googleapis.com/maps/api/geocode/json?address=' +
      encodeURIComponent(address) + '&components=country:US|administrative_area:TX&key=' + KEY;
    const req = https.get(url, function (res) {
      let body = '';
      res.on('data', d => (body += d));
      res.on('end', function () {
        try { resolve(JSON.parse(body)); } catch (e) { resolve(null); }
      });
    });
    req.on('error', () => resolve(null));
    req.setTimeout(10000, function () { req.destroy(); resolve(null); });
  });
}

const KEEP = { ROOFTOP: 1, RANGE_INTERPOLATED: 1, GEOMETRIC_CENTER: 1 };

function comp(result, type) {
  const cs = (result && result.address_components) || [];
  for (const c of cs) if ((c.types || []).indexOf(type) !== -1) return c;
  return null;
}

(async function main() {
  let todo = [];
  files.forEach(function (f) {
    const rows = parseCsv(fs.readFileSync(f, 'utf8'));
    const head = rows[0];
    for (let i = 1; i < rows.length; i++) {
      const r = rows[i];
      if (!r || !r[0]) continue;
      todo.push({ file: f, head: head, name: r[0], denom: r[1], addr: r[2], phone: r[3], web: r[4] });
    }
  });
  const uncached = todo.filter(t => !cache.has(t.addr)).length;
  console.log('batches      ' + files.length + (METRO ? '  (metro: ' + METRO + ')' : ''));
  console.log('addresses    ' + todo.length.toLocaleString());
  console.log('in cache     ' + (todo.length - uncached).toLocaleString());
  console.log('TO LOOK UP   ' + uncached.toLocaleString() + (DRY ? '   (dry run -- no calls, invented coordinates)' : '   <- billable'));
  if (LIMIT) console.log('limit        ' + LIMIT);
  console.log('');

  const byFile = new Map();
  let done = 0, calls = 0;
  for (const t of todo) {
    if (!byFile.has(t.file)) byFile.set(t.file, { ok: [], check: [], fail: [] });
    const out = byFile.get(t.file);
    let v = cache.get(t.addr);
    if (v === undefined) {
      if (CACHED_ONLY) { out.fail.push(Object.assign({ why: 'not in cache' }, t)); continue; }
      if (LIMIT && calls >= LIMIT) { out.fail.push(Object.assign({ why: 'past --limit' }, t)); continue; }
      if (DRY) {
        v = { lat: 31.0 + Math.random(), lng: -99.0 - Math.random(), loc: 'ROOFTOP', city: cityOf(t.addr), partial: false, dry: true };
        remember(t.addr, v);
      } else {
        calls++;
        const res = await geocode(t.addr);
        if (!res || res.status === 'OVER_QUERY_LIMIT' || res.status === 'REQUEST_DENIED') {
          // Not cached: this is "unknown", not "no such place".
          out.fail.push(Object.assign({ why: res ? res.status : 'network/timeout' }, t));
          if (res && res.status === 'REQUEST_DENIED') {
            console.error('\nREQUEST_DENIED -- the key is wrong or the Geocoding API is not enabled.');
            console.error('Stopping rather than burning the rest of the batch on the same error.');
            break;
          }
          continue;
        }
        if (res.status === 'ZERO_RESULTS' || !res.results || !res.results.length) {
          v = null;                       // a real answer: no such address
          remember(t.addr, v);
        } else {
          const g = res.results[0];
          const locality = comp(g, 'locality') || comp(g, 'postal_town') || comp(g, 'sublocality');
          v = {
            lat: g.geometry.location.lat,
            lng: g.geometry.location.lng,
            loc: g.geometry.location_type,
            city: locality ? locality.long_name.toUpperCase() : '',
            partial: !!g.partial_match,
            formatted: g.formatted_address
          };
          remember(t.addr, v);
        }
      }
      if (calls && calls % 200 === 0) console.log('  ...' + calls.toLocaleString() + ' looked up');
    }
    done++;
    if (v === null) { out.fail.push(Object.assign({ why: 'no such address' }, t)); continue; }
    const wanted = cityOf(t.addr);
    const reasons = [];
    if (!KEEP[v.loc]) reasons.push('town centre only (' + v.loc + ')');
    if (v.partial) reasons.push('partial match');
    if (wanted && v.city && v.city !== wanted) reasons.push('landed in ' + v.city);
    const row = Object.assign({ lat: v.lat, lng: v.lng, loc: v.loc, why: reasons.join('; ') }, t);
    if (reasons.length) out.check.push(row); else out.ok.push(row);
  }

  const HEAD = 'name,denomination,address,phone,website,lat,lng';
  const line = r => csvLine([r.name, r.denom, r.addr, r.phone, r.web, r.lat, r.lng]);
  let nOk = 0, nCheck = 0, nFail = 0;
  const suffix = DRY ? '.dryrun' : '';
  byFile.forEach(function (out, f) {
    const base = f.replace(/\.csv$/, '');
    if (out.ok.length) fs.writeFileSync(base + suffix + '.geo.csv', HEAD + '\n' + out.ok.map(line).join('\n') + '\n');
    if (out.check.length) fs.writeFileSync(base + suffix + '.geo-check.csv',
      HEAD + ',why\n' + out.check.map(r => csvLine([r.name, r.denom, r.addr, r.phone, r.web, r.lat, r.lng, r.why])).join('\n') + '\n');
    if (out.fail.length) fs.writeFileSync(base + suffix + '.geo-fail.csv',
      'name,denomination,address,phone,website,why\n' + out.fail.map(r => csvLine([r.name, r.denom, r.addr, r.phone, r.web, r.why])).join('\n') + '\n');
    nOk += out.ok.length; nCheck += out.check.length; nFail += out.fail.length;
  });

  console.log('');
  console.log('billable calls made  ' + calls.toLocaleString());
  console.log('');
  console.log('READY TO IMPORT      ' + nOk.toLocaleString() + '   -> *.geo.csv');
  console.log('needs a look         ' + nCheck.toLocaleString() + '   -> *.geo-check.csv  (town-centre, partial, or wrong city)');
  console.log('no coordinates       ' + nFail.toLocaleString() + '   -> *.geo-fail.csv');
  if (nCheck) {
    console.log('');
    console.log('  The check file is not junk -- it is mostly addresses Google could only');
    console.log('  place at the middle of the town. Importing those stacks every church in');
    console.log('  that town on one pin, which looks worse than having no pin at all.');
  }
})();
