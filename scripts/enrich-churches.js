#!/usr/bin/env node
'use strict';

/*
 * enrich-churches.js
 * ------------------
 * Takes a CSV of churches (columns: name, denomination, address) and adds
 * phone + website columns using the Google Places API, plus a "matched"
 * flag and a "match_detail" note so you can see what needs manual
 * follow-up.
 *
 * How it works, per row:
 *   1. Parse a city + state out of the `address` field. The street / PO Box
 *      portion is ignored -- only the ", City, ST ZIP" tail is used.
 *   2. Places Text Search for  "{name}, {city}, {state}".
 *   3. Take the top result ONLY if it's a confident match:
 *        - name similarity (normalised token Jaccard, with a substring
 *          shortcut) >= NAME_SIM_THRESHOLD (default 0.5), AND
 *        - the result's formatted_address contains the same state.
 *   4. Places Details on that result for formatted_phone_number + website.
 *   5. No confident match  ->  phone/website left blank, matched = "no".
 *
 * `matched` column values:
 *   yes      confident match, place is operational
 *   closed   confident match, but Places says CLOSED_PERMANENTLY
 *            (phone/website still filled from the listing; review these).
 *            With --drop-closed these rows go to <output>.closed.csv
 *            instead of the main output.
 *   no       no confident match  ->  phone/website blank; see match_detail
 *   skipped  row already had phone + website (run with --force to redo)
 *
 * It never guesses: a weak or wrong-looking top result is reported as
 * unmatched rather than filled in.
 *
 * Usage:
 *   GOOGLE_PLACES_API_KEY=xxxxx  node scripts/enrich-churches.js in.csv [out.csv]
 *
 *   out.csv defaults to  in.enriched.csv
 *
 * Env vars:
 *   GOOGLE_PLACES_API_KEY   (required) -- the API key. Not hardcoded.
 *   NAME_SIM_THRESHOLD      (optional) match strictness, 0..1, default 0.5
 *   DELAY_MS               (optional) pause between rows, default 200
 *
 * Flags:
 *   --limit=N       only process the first N data rows (for a test run)
 *   --force         re-query rows that already have both phone and website
 *   --drop-closed   keep permanently-closed matches OUT of the main output;
 *                   they're written to <output>.closed.csv for review
 *   --selftest      run offline sanity checks on the parsing logic and exit
 *
 * Requires Node 18+ (uses the global fetch). Needs the *legacy* "Places API"
 * enabled in the Google Cloud console (not "Places API (New)") and billing
 * on the project -- a REQUEST_DENIED with an api-key/enablement message
 * means one of those is missing.
 */

const fs = require('fs');
const path = require('path');

const API_KEY = process.env.GOOGLE_PLACES_API_KEY;
const NAME_SIM_THRESHOLD = clampNum(process.env.NAME_SIM_THRESHOLD, 0.5, 0, 1);
const DELAY_MS = clampNum(process.env.DELAY_MS, 200, 0, 60000);

// ===========================================================================
// Google Places (legacy) API
// ===========================================================================

async function gget(base, params, tries) {
  tries = tries || 4;
  const url = new URL(base);
  for (const k in params) if (params[k] != null) url.searchParams.set(k, params[k]);
  url.searchParams.set('key', API_KEY);

  for (let attempt = 0; attempt < tries; attempt++) {
    let json;
    try {
      const res = await fetch(url);
      json = await res.json();
    } catch (e) {
      if (attempt === tries - 1) throw e;
      await sleep(1000 * (attempt + 1));
      continue;
    }
    if (json.status === 'OVER_QUERY_LIMIT' || json.status === 'UNKNOWN_ERROR') {
      if (attempt === tries - 1) return json;
      await sleep(2000 * (attempt + 1));
      continue;
    }
    return json; // OK, ZERO_RESULTS, REQUEST_DENIED, INVALID_REQUEST, NOT_FOUND
  }
  return { status: 'OVER_QUERY_LIMIT' };
}

function textSearch(query) {
  return gget('https://maps.googleapis.com/maps/api/place/textsearch/json', { query });
}

function placeDetails(placeId) {
  return gget('https://maps.googleapis.com/maps/api/place/details/json', {
    place_id: placeId,
    fields: 'formatted_phone_number,website,name,formatted_address,business_status',
  });
}

function assertNotDenied(json) {
  if (json && json.status === 'REQUEST_DENIED') {
    die('Google returned REQUEST_DENIED' + (json.error_message ? ': ' + json.error_message : '') +
      '\nCheck the API key, that the (legacy) "Places API" is enabled, and that billing is on.');
  }
}

// ===========================================================================
// Address -> city / state
// ===========================================================================

const STATE_NAMES = {
  alabama: 'AL', alaska: 'AK', arizona: 'AZ', arkansas: 'AR', california: 'CA',
  colorado: 'CO', connecticut: 'CT', delaware: 'DE', 'district of columbia': 'DC',
  florida: 'FL', georgia: 'GA', hawaii: 'HI', idaho: 'ID', illinois: 'IL',
  indiana: 'IN', iowa: 'IA', kansas: 'KS', kentucky: 'KY', louisiana: 'LA',
  maine: 'ME', maryland: 'MD', massachusetts: 'MA', michigan: 'MI', minnesota: 'MN',
  mississippi: 'MS', missouri: 'MO', montana: 'MT', nebraska: 'NE', nevada: 'NV',
  'new hampshire': 'NH', 'new jersey': 'NJ', 'new mexico': 'NM', 'new york': 'NY',
  'north carolina': 'NC', 'north dakota': 'ND', ohio: 'OH', oklahoma: 'OK',
  oregon: 'OR', pennsylvania: 'PA', 'rhode island': 'RI', 'south carolina': 'SC',
  'south dakota': 'SD', tennessee: 'TN', texas: 'TX', utah: 'UT', vermont: 'VT',
  virginia: 'VA', washington: 'WA', 'west virginia': 'WV', wisconsin: 'WI',
  wyoming: 'WY', 'puerto rico': 'PR',
};
const STATE_ABBREVS = new Set(Object.values(STATE_NAMES));
const ABBREV_TO_NAME = {};
for (const n in STATE_NAMES) ABBREV_TO_NAME[STATE_NAMES[n]] = n;

// Returns { city, state } -- either may be null. `state` is a 2-letter code.
function parseCityState(address) {
  if (!address) return { city: null, state: null };
  let s = String(address).trim();
  // Drop a trailing country token.
  s = s.replace(/,?\s*(U\.?S\.?A\.?|United States(?: of America)?|US)\s*$/i, '').trim();

  const parts = s.split(',').map((p) => p.trim()).filter(Boolean);
  if (!parts.length) return { city: null, state: null };

  const last = parts[parts.length - 1];
  let city = null;
  let state = null;

  // Case A: last chunk ends with "ST" or "ST 12345" (optionally with a
  // city glued in front of it when the address has no comma).
  const m = last.match(/^(.*?)[\s,]*\b([A-Za-z]{2})\b(?:\s+\d{5}(?:-\d{4})?)?\s*$/);
  if (m && STATE_ABBREVS.has(m[2].toUpperCase())) {
    state = m[2].toUpperCase();
    const glued = m[1].trim().replace(/[\s,]+$/, '');
    city = glued || parts[parts.length - 2] || null;
  } else {
    // Case B: last chunk is (or ends with) a full state name.
    const lastLC = last.toLowerCase().replace(/\s+\d{5}(?:-\d{4})?\s*$/, '').trim();
    for (const nm in STATE_NAMES) {
      if (lastLC === nm) { state = STATE_NAMES[nm]; city = parts[parts.length - 2] || null; break; }
      if (lastLC.endsWith(' ' + nm)) { state = STATE_NAMES[nm]; city = lastLC.slice(0, lastLC.length - nm.length).trim(); break; }
    }
  }

  if (city) {
    city = city.replace(/\b\d{5}(-\d{4})?\b/g, '').replace(/\s{2,}/g, ' ').trim();
    if (!/[a-z]/i.test(city)) city = null; // e.g. leftover "PO Box 12"
  }
  return { city: city || null, state: state || null };
}

function addressHasState(formattedAddress, stateAbbrev) {
  if (!formattedAddress || !stateAbbrev) return false;
  const fa = formattedAddress.toLowerCase();
  if (new RegExp('\\b' + stateAbbrev.toLowerCase() + '\\b').test(fa)) return true;
  const full = ABBREV_TO_NAME[stateAbbrev.toUpperCase()];
  return full ? fa.indexOf(full) !== -1 : false;
}

// ===========================================================================
// Name similarity
// ===========================================================================

const TINY_STOP = new Set(['the', 'of', 'a', 'and', 'at', 'in', 'on', 'for']);

function normalizeName(s) {
  return String(s || '')
    .toLowerCase()
    .replace(/&/g, ' and ')
    .replace(/[^a-z0-9\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function nameTokens(s) {
  return normalizeName(s).split(' ').filter((t) => t && !TINY_STOP.has(t));
}

// 0..1. 1 = identical; ~0.92 for a clean substring match; otherwise token
// Jaccard. Church-type words (church, baptist, ...) are deliberately KEPT
// so "Abbott Baptist Church" does not collide with "Abbott Methodist Church".
function nameSimilarity(a, b) {
  const na = normalizeName(a);
  const nb = normalizeName(b);
  if (!na || !nb) return 0;
  if (na === nb) return 1;
  if (na.length >= 6 && (nb.indexOf(na) !== -1 || na.indexOf(nb) !== -1)) return 0.92;

  const ta = new Set(nameTokens(a));
  const tb = new Set(nameTokens(b));
  if (!ta.size || !tb.size) return 0;
  let inter = 0;
  for (const t of ta) if (tb.has(t)) inter++;
  return inter / (ta.size + tb.size - inter);
}

// ===========================================================================
// CSV
// ===========================================================================

function parseCsv(text) {
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1); // BOM
  text = text.replace(/\r\n?/g, '\n'); // normalise line endings

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

function ensureCol(headers, name) {
  const lc = headers.map((h) => h.trim().toLowerCase());
  let idx = lc.indexOf(name);
  if (idx === -1) { headers.push(name); idx = headers.length - 1; }
  return idx;
}
function padTo(arr, n) { while (arr.length < n) arr.push(''); return arr; }
function cell(arr, i) { return (arr[i] || '').trim(); }
function setCell(arr, i, v) { arr[i] = v == null ? '' : String(v); }
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
function clampNum(v, dflt, lo, hi) {
  const n = Number(v);
  if (!isFinite(n)) return dflt;
  return Math.min(hi, Math.max(lo, n));
}
function defaultSuffixPath(p, suffix) {
  if (!p) return suffix + '.csv';
  const ext = path.extname(p);
  return ext ? p.slice(0, -ext.length) + '.' + suffix + ext : p + '.' + suffix + '.csv';
}
function defaultOutPath(p) {
  return p ? defaultSuffixPath(p, 'enriched') : 'enriched.csv';
}
function printUsage() {
  process.stderr.write(
    'Usage:\n  GOOGLE_PLACES_API_KEY=xxx node scripts/enrich-churches.js input.csv [output.csv]\n\n' +
    'Input CSV needs at least "name" and "address" columns. Output adds\n' +
    'phone, website, matched, match_detail.\n' +
    'Flags: --limit=N, --force, --drop-closed, --selftest.\n'
  );
}
function die(msg) {
  process.stderr.write('\nerror: ' + msg + '\n');
  process.exit(1);
}

// ===========================================================================
// Main
// ===========================================================================

async function run(inPath, outPath, opts) {
  const raw = fs.readFileSync(inPath, 'utf8');
  const { headers, rows } = parseCsv(raw);
  if (!headers.length) die('Input CSV has no header row.');

  const headerLC = headers.map((h) => h.trim().toLowerCase());
  const nameIdx = headerLC.indexOf('name');
  const addrIdx = headerLC.indexOf('address');
  if (nameIdx === -1 || addrIdx === -1) {
    die('Input CSV must have "name" and "address" columns. Found: ' + headers.join(', '));
  }

  // Output = original columns, then phone / website / matched / match_detail
  // (reused in place if the input already has one of those headers).
  const outHeaders = headers.slice();
  const phoneIdx = ensureCol(outHeaders, 'phone');
  const websiteIdx = ensureCol(outHeaders, 'website');
  const matchedIdx = ensureCol(outHeaders, 'matched');
  const detailIdx = ensureCol(outHeaders, 'match_detail');

  const total = Math.min(rows.length, opts.limit);
  const out = fs.createWriteStream(outPath, { encoding: 'utf8' });
  out.write(csvRow(outHeaders));

  // With --drop-closed, permanently-closed matches go to a sidecar file
  // (never silently discarded) instead of the main output. Opened lazily.
  const closedPath = defaultSuffixPath(outPath, 'closed');
  let closedOut = null;
  const openClosedOut = () => {
    if (!closedOut) { closedOut = fs.createWriteStream(closedPath, { encoding: 'utf8' }); closedOut.write(csvRow(outHeaders)); }
    return closedOut;
  };

  const stats = { matched: 0, closed: 0, dropped: 0, phone: 0, website: 0, noState: 0, noResult: 0, lowConf: 0, skipped: 0 };

  for (let i = 0; i < total; i++) {
    const src = rows[i];
    const row = padTo(src.slice(), outHeaders.length);
    const name = (src[nameIdx] || '').trim();
    const address = (src[addrIdx] || '').trim();

    let phone = cell(row, phoneIdx);
    let website = cell(row, websiteIdx);
    let matched = 'no';
    let detail = '';

    if (!opts.force && phone && website) {
      matched = 'skipped';
      detail = 'already had phone + website';
      stats.skipped++;
    } else if (!name) {
      detail = 'row has no name';
    } else {
      const { city, state } = parseCityState(address);
      if (!state) {
        detail = 'could not parse a state from address: "' + address + '"';
        stats.noState++;
      } else {
        const query = [name, city, state].filter(Boolean).join(', ');
        const search = await textSearch(query);
        assertNotDenied(search);
        const results = Array.isArray(search.results) ? search.results : [];

        if (!results.length) {
          detail = 'no Places results for: ' + query;
          stats.noResult++;
        } else {
          const top = results[0];
          const sim = nameSimilarity(name, top.name || '');
          const stateOk = addressHasState(top.formatted_address || '', state);

          if (sim >= NAME_SIM_THRESHOLD && stateOk) {
            const det = await placeDetails(top.place_id);
            assertNotDenied(det);
            const r = det.result || {};
            phone = r.formatted_phone_number || '';
            website = r.website || '';
            const bs = r.business_status || top.business_status;
            // A permanently-closed place is still a confident match, but
            // it gets its own `matched` value so a clean match is
            // distinguishable without reading match_detail. A temporary
            // closure is treated as a normal match (just noted).
            matched = (bs === 'CLOSED_PERMANENTLY') ? 'closed' : 'yes';
            detail = (r.name || top.name || '') + ' — ' + (r.formatted_address || top.formatted_address || '');
            if (bs === 'CLOSED_PERMANENTLY') detail += ' [permanently closed]';
            else if (bs === 'CLOSED_TEMPORARILY') detail += ' [temporarily closed]';
            if (matched === 'closed') stats.closed++;
            else stats.matched++;
            if (phone) stats.phone++;
            if (website) stats.website++;
          } else {
            const why = !stateOk ? 'wrong state' : 'name similarity ' + sim.toFixed(2) + ' < ' + NAME_SIM_THRESHOLD;
            detail = 'no confident match (' + why + '). top result: "' + (top.name || '') + '" — ' + (top.formatted_address || '');
            stats.lowConf++;
          }
        }
      }
    }

    setCell(row, phoneIdx, phone);
    setCell(row, websiteIdx, website);
    setCell(row, matchedIdx, matched);
    setCell(row, detailIdx, detail);

    const divert = opts.dropClosed && matched === 'closed';
    (divert ? openClosedOut() : out).write(csvRow(row));
    if (divert) stats.dropped++;

    process.stderr.write(
      '[' + (i + 1) + '/' + total + '] ' + (name || '(no name)') +
      '  ->  ' + matched + (divert ? ' (dropped)' : '') +
      ((matched === 'yes' || matched === 'closed') ? ' (' + (phone ? '+phone' : 'no phone') + ', ' + (website ? '+website' : 'no website') + ')' : '') +
      '\n'
    );

    if (i < total - 1 && DELAY_MS) await sleep(DELAY_MS);
  }

  await new Promise((res) => out.end(res));
  if (closedOut) await new Promise((res) => closedOut.end(res));

  const followUp = stats.noState + stats.noResult + stats.lowConf;
  const closedInMain = stats.closed - stats.dropped;
  process.stderr.write(
    '\nDone. ' + total + ' rows: ' + stats.matched + ' matched ' +
    '(phone: ' + stats.phone + ', website: ' + stats.website + '), ' +
    stats.closed + ' matched but permanently closed' +
    (stats.dropped ? ' (' + stats.dropped + ' dropped from main output)' : '') + ', ' +
    followUp + ' need follow-up' +
    (stats.skipped ? ', ' + stats.skipped + ' skipped (already filled)' : '') + '.\n' +
    '  no state parsed from address : ' + stats.noState + '\n' +
    '  no Places result             : ' + stats.noResult + '\n' +
    '  result rejected (low conf)   : ' + stats.lowConf + '\n' +
    (stats.dropped ? '  permanently closed (dropped)  : ' + stats.dropped + '\n' : '') +
    'Wrote: ' + outPath + (closedInMain ? '  (' + closedInMain + ' closed rows kept in it)' : '') + '\n' +
    (stats.dropped ? 'Wrote: ' + closedPath + '  (' + stats.dropped + ' permanently-closed rows, for review)\n' : '')
  );
}

// ===========================================================================
// Self-test (no network)
// ===========================================================================

function selftest() {
  let failed = 0;
  const eq = (got, want, label) => {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    if (!ok) failed++;
    process.stderr.write((ok ? '  ok   ' : '  FAIL ') + label +
      (ok ? '' : '  got ' + JSON.stringify(got) + '  want ' + JSON.stringify(want)) + '\n');
  };
  const near = (got, want, label) => {
    const ok = Math.abs(got - want) < 0.02;
    if (!ok) failed++;
    process.stderr.write((ok ? '  ok   ' : '  FAIL ') + label + (ok ? '' : '  got ' + got + '  want ~' + want) + '\n');
  };

  process.stderr.write('parseCityState:\n');
  eq(parseCityState('PO Box 38, Abbott, TX 76621'), { city: 'Abbott', state: 'TX' }, 'PO Box + city + ST ZIP');
  eq(parseCityState('704 Avenue D, Abernathy, TX 79311'), { city: 'Abernathy', state: 'TX' }, 'street + city + ST ZIP');
  eq(parseCityState('San Antonio Mall Dr, San Antonio, TX 78266, USA'), { city: 'San Antonio', state: 'TX' }, 'street named like a city + , USA');
  eq(parseCityState('Abilene, TX 79605'), { city: 'Abilene', state: 'TX' }, 'city + ST ZIP only');
  eq(parseCityState('Abbott TX 76621'), { city: 'Abbott', state: 'TX' }, 'no commas at all');
  eq(parseCityState('123 Main St, Springfield, Illinois'), { city: 'Springfield', state: 'IL' }, 'full state name');
  eq(parseCityState('123 Main St, Kansas City, MO 64111'), { city: 'Kansas City', state: 'MO' }, 'two-word city');
  eq(parseCityState(''), { city: null, state: null }, 'empty');
  eq(parseCityState('Just a street with no locality'), { city: null, state: null }, 'no state -> nulls');

  process.stderr.write('nameSimilarity:\n');
  near(nameSimilarity('Abbott Baptist Church', 'Abbott Baptist Church'), 1, 'identical');
  near(nameSimilarity('Grace Fellowship', 'Grace Fellowship Church of Austin'), 0.92, 'substring');
  eq(nameSimilarity('Abbott Baptist Church', 'Abbott United Methodist Church') < NAME_SIM_THRESHOLD, true, 'diff denomination stays below threshold');
  eq(nameSimilarity('First Baptist Church', 'Walmart Supercenter') < 0.2, true, 'unrelated is low');

  process.stderr.write('addressHasState:\n');
  eq(addressHasState('123 Main St, Abbott, TX 76621, USA', 'TX'), true, 'abbrev present');
  eq(addressHasState('123 Main St, Springfield, IL, USA', 'MO'), false, 'wrong state');
  eq(addressHasState('Springfield, Illinois, USA', 'IL'), true, 'full-name fallback');

  process.stderr.write('csv round-trip:\n');
  const sample = 'name,denomination,address\r\n"Smith, John Church",Baptist,"1 A St, Waco, TX 76700"\nPlain Church,,"2 B St, Austin, TX 78701"\n';
  const p = parseCsv(sample);
  eq(p.headers, ['name', 'denomination', 'address'], 'headers');
  eq(p.rows[0], ['Smith, John Church', 'Baptist', '1 A St, Waco, TX 76700'], 'quoted comma field');
  eq(csvRow(['a', 'b,c', 'd"e']), 'a,"b,c","d""e"\n', 'writer quoting');

  process.stderr.write(failed ? '\n' + failed + ' check(s) FAILED\n' : '\nall checks passed\n');
  process.exit(failed ? 1 : 0);
}

// ===========================================================================
// CLI entry
// ===========================================================================

(function main() {
  const positional = [];
  const opts = { limit: Infinity, force: false, dropClosed: false };
  for (const a of process.argv.slice(2)) {
    if (a === '--force') opts.force = true;
    else if (a === '--drop-closed') opts.dropClosed = true;
    else if (a.startsWith('--limit=')) opts.limit = Math.max(0, parseInt(a.slice(8), 10) || 0);
    else if (a === '--selftest') return selftest();
    else if (a === '--help' || a === '-h') { printUsage(); process.exit(0); }
    else if (a.startsWith('--')) die('Unknown flag: ' + a);
    else positional.push(a);
  }

  const inPath = positional[0];
  if (!inPath) { printUsage(); process.exit(1); }
  const outPath = positional[1] || defaultOutPath(inPath);

  if (!API_KEY) die('Set GOOGLE_PLACES_API_KEY in the environment (do not hardcode it).');
  if (!fs.existsSync(inPath)) die('Input file not found: ' + inPath);
  if (path.resolve(inPath) === path.resolve(outPath)) die('Output path is the same as the input; refusing to overwrite.');

  run(inPath, outPath, opts).catch((err) => die(err && err.stack ? err.stack : String(err)));
})();
