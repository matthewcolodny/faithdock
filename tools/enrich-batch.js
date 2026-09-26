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
// Re-score what is already cached and buy nothing. The rules for
// deciding a match changed once already after seeing real results, and
// re-running a batch to apply a new rule should not cost what the
// lookups cost.
const CACHED_ONLY = has('cached-only');
// Promote rows whose name scores at least this AND sit in the same
// postal area, using GOOGLE'S address rather than the IRS one. Off by
// default and meant to be set after reading a sorted .check.csv, not
// before. 0 means never.
const ACCEPT_SIMILAR = parseInt(arg('accept-similar', '0'), 10) || 0;
const KEY = process.env.GOOGLE_PLACES_KEY || '';
const PAUSE_MS = parseInt(arg('pause', '120'), 10);

if (!FILE) {
  console.error('Usage: node tools/enrich-batch.js --file texas-batches/<batch>.csv [--limit N] [--dry-run]');
  process.exit(1);
}
if (!fs.existsSync(FILE)) { console.error('No such file: ' + FILE); process.exit(1); }
if (!KEY && !DRY && !CACHED_ONLY) {
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
    formatted: p.formattedAddress || '',
    detail: label + ' — ' + (p.formattedAddress || ''),
    phone: p.nationalPhoneNumber || '',
    website: p.websiteUri || '',
    types: (p.types || []).join('; ')
  };
}

// HOW ALIKE ARE THE TWO NAMES?
//
// Used to SORT the rows a person has to read, and deliberately not to
// decide anything. Scored across 23 real mismatches from the San
// Antonio batch, the boundary is not separable:
//
//   79  New Testament Christian Mission Intl | ...Intl - San Antonio   SAME
//   78  Centro Cristiano De Restauracion     | Centro Familiar de Rest DIFFERENT
//   76  Ministerios Amistad Cristiana USA    | Iglesia Amistad Crist.  SAME
//
// A true match sits on either side of a false one. Any cut-off picked
// here would be a number fitted to 23 rows, and picking numbers that
// happen to work on a small sample is how a rule that fails on ten
// thousand gets written. So the score is printed, the file is sorted by
// it, and the judgement stays with the person -- who can then set
// --accept-similar to whatever they concluded, on evidence.
//
// Accents are folded because the IRS file has none and Google's answers
// do: "Mision Cristiana" and "Misión Cristiana" are the same name and
// score 0 against each other without it.
function fold(x) {
  return String(x || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').replace(/\s+/g, ' ').trim();
}
const NAME_STOP = new Set(['the', 'of', 'de', 'del', 'la', 'el', 'los', 'las', 'a', 'an', 'and', 'y', 'en', 'tx', 'texas', 'inc']);
function nameTokens(x) { return fold(x).split(' ').filter(w => w && !NAME_STOP.has(w)); }

function similarity(a, b) {
  const A = new Set(nameTokens(a)), B = new Set(nameTokens(b));
  let jaccard = 0;
  if (A.size && B.size) {
    let hit = 0; A.forEach(t => { if (B.has(t)) hit++; });
    jaccard = hit / (A.size + B.size - hit);
  }
  // Token overlap alone scores a one-letter typo as a total miss --
  // "Capilla Del Pueblo" against "Capillo Del Pueblo" shares no token
  // for the word that matters. The edit distance catches that; the
  // token score catches reordering and added words. Whichever is
  // kinder is the honest reading of "are these the same name".
  const x = fold(a), y = fold(b);
  const d = [];
  for (let i = 0; i <= y.length; i++) d[i] = [i];
  for (let j = 0; j <= x.length; j++) d[0][j] = j;
  for (let i = 1; i <= y.length; i++) {
    for (let j = 1; j <= x.length; j++) {
      d[i][j] = y[i - 1] === x[j - 1] ? d[i - 1][j - 1]
        : Math.min(d[i - 1][j - 1] + 1, d[i][j - 1] + 1, d[i - 1][j] + 1);
    }
  }
  const edit = 1 - d[y.length][x.length] / Math.max(x.length, y.length, 1);
  return Math.round(Math.max(jaccard, edit) * 100);
}

const zip3of = a => ((String(a).match(/\b(\d{5})(?:-\d{4})?\s*$/) || [])[1] || '').slice(0, 3);

// DOES THE PLACE GOOGLE RETURNED SIT AT THE ADDRESS WE ASKED ABOUT?
//
// Text Search always answers. It has no concept of "nothing here" -- it
// returns its best guess and a confident-looking name, so treating any
// response as a match is treating "Google replied" as "we found the
// church". Measured on the first five real lookups: 5 of 5 came back
// "found", and only 2 were right. "Big Bend Tabernacle, HC 65 Box 151"
// came back as Big Bend Telephone Company, with the phone company's
// number and website; "Christian Catholic Church, 1710 Banker Rd" came
// back as Immaculate Heart of Mary Mission on a different street.
// Importing that would have put a telephone company's number on a
// church. San Antonio's 53% match rate was the honest number; 100% was
// the tell.
//
// The check costs nothing extra -- no second call, just comparing the
// address Google echoed against the one we sent.
//
// THE STREET NUMBER IS REQUIRED. City alone is not enough: Immaculate
// Heart of Mary is in the right city and the right ZIP and is still the
// wrong building. A matching number plus either the city or the ZIP is
// the weakest test that rejects all three bad rows and keeps both good
// ones.
function verifyAddress(asked, got) {
  if (!got) return 'no';
  const street = (asked.split(',')[0] || '').trim();
  const numMatch = street.match(/^(\d+)/);
  // Rural routes and highway contracts -- "HC 65 BOX 151", "RR 2 BOX 40"
  // -- have no street number to check, so nothing here can be confirmed
  // either way. Said out loud rather than guessed at.
  if (!numMatch) return 'unverifiable';
  const num = numMatch[1];
  if (!new RegExp('(^|[^0-9])' + num + '([^0-9]|$)').test(got)) return 'no';
  const city = (asked.split(',')[1] || '').trim().toLowerCase();
  const zip = (asked.match(/\b(\d{5})(?:-\d{4})?\s*$/) || [])[1];
  const g = got.toLowerCase();
  if (city && g.indexOf(city) !== -1) return 'yes';
  if (zip && g.indexOf(zip) !== -1) return 'yes';
  return 'no';
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

// ---- Congregations of another faith --------------------------------
//
// The IRS classifies a Hindu temple, a mosque and a synagogue as
// churches for tax purposes -- FOUNDATION=10 is a tax status, not a
// theology -- so they arrive in these batches. FaithDock is a Christian
// directory, and after the San Antonio import they had to be found and
// hidden BY HAND. This catches them before they go in.
//
// Routed to a file to read, never dropped. A false positive costs a
// glance; a row deleted on a pattern is gone.
//
// PATTERNS MEASURED AGAINST ALL 15,759 PREPARED NAMES, because the
// obvious ones are wrong:
//
//   "temple" alone hits 363 names and most are Christian -- Glory
//   Temple Holiness Church, Victory Temple Free Will Baptist Church.
//   Only "Temple Beth ..." and "Temple Shalom" are used.
//
//   "synagogue" hits 2 names and BOTH are Messianic -- Texoma Messianic
//   Synagogue, Sar Shalom Synagogue. Messianic Judaism is Protestant in
//   this app's own taxonomy (compute_denomination_tags returns
//   {'Protestant','Messianic Judaism'}), so sweeping it up would be
//   wrong twice over.
//
//   "shalom" and "beth" alone hit Christian names too -- Jehovah Shalom
//   Community Bible Fellowship, Beth Eden Baptist Church -- so they
//   only count behind "Congregation" or "Temple".
//
// The result is 109 of 15,759 flagged, 0.7%.
const OTHER_FAITH = [
  [/\bhindu\b|\bmandir\b|\bswaminarayan\b/i, 'Hindu'],
  [/\bbuddhis(t|m)\b|\bdharma\b|\bsangha\b|\bzen cent/i, 'Buddhist'],
  [/\bsikh\b|\bguru?dwara\b/i, 'Sikh'],
  [/\bislam(ic)?\b|\bmasjid\b|\bmosque\b|\bmuslim\b/i, 'Islamic'],
  [/\bscientolog/i, 'Scientology'],
  [/\bunitarian\b|\buniversalist\b/i, 'Unitarian Universalist'],
  [/\bjain\b|\bzoroastrian\b|\bbaha.?i\b|\beckankar\b|\bkrishna\b|\bvedanta\b/i, 'Other faith'],
  [/\bsynagogue\b|\bjewish\b|\btorah\b|\bchabad\b|\bb.?nai\b|congregation\s+beth\b|congregation\s+\S+\s+shalom\b|congregation\s+ohev\b|congregation\s+anshai\b|temple\s+beth\b|temple\s+shalom\b/i, 'Jewish']
];

// Applies to the JEWISH patterns ONLY, and that limit is the whole
// point. Those patterns key on Hebrew words that Messianic
// congregations also use -- Congregation Beth Messiah, Congregation
// Beth Yeshua Texas, Bnai-El Ministries are all Christian and all match
// them -- so a Christian word has to be able to overrule them.
//
// Applied to every category it was WRONG, and measurably so: Church of
// Scientology of Texas and Wildflower Church a Unitarian both contain
// "Church" and both sailed into the import file. Scientology and
// Unitarian Universalism use "Church" in their own names; "Hindu",
// "Buddhist", "Masjid" and "Sikh" are not words a Christian
// congregation applies to itself, so nothing needs to overrule them.
const CHRISTIAN_SIGNAL = /\bmessianic\b|\bmessiah\b|\byeshua\b|\bchurch\b|\bministr(y|ies)\b|\bchrist\b/i;

function otherFaith(name) {
  const hit = OTHER_FAITH.find(function (e) { return e[0].test(name); });
  if (!hit) return '';
  if (hit[1] === 'Jewish' && CHRISTIAN_SIGNAL.test(name)) return '';
  return hit[1];
}

(async function main() {
  const base = FILE.replace(/\.csv$/i, '') + (DRY ? '.dryrun' : '');
  const enriched = [], yes = [], no = [], check = [], mismatch = [], otherFaithRows = [];
  let calls = 0, cached = 0, unknown = 0, done = 0, promoted = 0;
  const accepted = [];

  for (const row of rows) {
    const k = keyOf(row);
    let r = cache.get(k);
    if (r) cached++;
    else {
      if (CACHED_ONLY) continue;
      if (LIMIT && calls >= LIMIT) break;
      r = await lookupWithRetry(row);
      calls++;
      if (r) remember(k, r);
      else { unknown++; r = { matched: '', detail: 'lookup failed', phone: '', website: '', types: '' }; }
      if (PAUSE_MS) await sleep(PAUSE_MS);
    }
    done++;
    if (done % 100 === 0) process.stdout.write('  ' + done + '/' + rows.length + ' (' + calls + ' calls)\r');

    // Cache entries written before the address check existed have no
    // formatted field; the detail line is "Name — Address", so the
    // address is recoverable rather than needing to be bought again.
    const got = r.formatted || (r.detail || '').split('—').slice(1).join('—').trim();
    const agrees = r.matched === 'yes' ? verifyAddress(row.address, got) : 'no';
    const verdict = r.matched === 'yes' ? agrees : r.matched;

    enriched.push([row.name, row.denomination, row.address, r.phone, r.website, verdict, r.detail, r.types]);

    // A CONFIRMED ADDRESS IS NOT A CONFIRMED CHURCH. The address check
    // asks "is this the right building"; it cannot ask "is this the
    // right occupant". "Mission Vineyard, 1107 Austin Hwy Unit 90086"
    // came back United States Postal Service at 1107 Austin Hwy -- the
    // street number matched, so it passed -- carrying an 800 number and
    // a usps.com link that would have gone into the directory as a
    // church's contact details. "Ministerio Del Reino Poder Y
    // Autoridad" came back Swaying Oaks Apartments the same way.
    //
    // The tell is narrow: a result that CARRIES CONTACT DETAILS, is
    // named nothing like the church, and is not typed as a place of
    // worship. That is a different occupant of the same building.
    // Results typed street_address or premise are Google confirming the
    // address with no business attached -- they carry no phone or
    // website, so they are harmless and stay confirmed.
    const resultName = (r.detail || '').split('—')[0].trim();
    const nameScore = similarity(row.name, resultName);
    const hasContacts = !!(r.phone || r.website);
    const otherOccupant = verdict === 'yes' && hasContacts && nameScore < 40 && !WORSHIP.test(r.types || '');

    // Checked before anything else can accept the row: a mosque at a
    // correctly matched address is still not going in a Christian
    // directory, and the address being right is exactly why the other
    // gates would pass it.
    const faith = otherFaith(row.name);
    if (faith && verdict === 'yes') {
      otherFaithRows.push([row.name, row.denomination, row.address, r.phone, r.website, faith, r.detail]);
    } else if (otherOccupant) {
      // Contacts dropped, not carried across -- they belong to whoever
      // else is at this address.
      check.push([row.name, row.denomination, row.address, '', '',
                  'different occupant at this address', nameScore, 'yes', '', r.detail, r.types]);
    } else if (verdict === 'yes') {
      yes.push([row.name, row.denomination, row.address, r.phone, r.website]);
      // Kept alongside, for the shared-place pass below. Index into
      // yes so the row can be pulled back out by position.
      accepted.push({ i: yes.length - 1, place: r.detail || '', score: nameScore,
                      row: row, r: r, types: r.types || '' });
      if (!WORSHIP.test(r.types || '')) {
        mismatch.push([row.name, row.denomination, row.address, r.phone, r.website, verdict, r.detail, r.types]);
      }
    } else if (r.matched === 'yes') {
      // Google answered, but not about this address. Never silently
      // dropped and never silently imported -- the name is often right
      // and the building wrong, which is the one case a person has to
      // look at.
      //
      // The IRS address is frequently a MAILING address: a treasurer's
      // home, a trailer, a PO drop. Google usually has where people
      // actually meet. So when one of these is accepted, it is accepted
      // with Google's address, not the IRS one -- that is the whole
      // value of recovering it for a directory with a map on it.
      const gotName = (r.detail || '').split('\u2014')[0].trim();
      const score = similarity(row.name, gotName);
      const sameArea = zip3of(row.address) && zip3of(got) && zip3of(row.address) === zip3of(got);
      if (ACCEPT_SIMILAR && score >= ACCEPT_SIMILAR && sameArea) {
        yes.push([row.name, row.denomination, got || row.address, r.phone, r.website]);
        promoted++;
      } else {
        check.push([row.name, row.denomination, row.address, r.phone, r.website,
                    agrees, score, sameArea ? 'yes' : 'no', got, r.detail, r.types]);
      }
    } else if (r.matched === 'no') {
      no.push([row.name, row.denomination, row.address]);
    }
  }

  // ---- ONE GOOGLE PLACE CANNOT BE TWO CHURCHES --------------------
  //
  // Text Search answers every query, so when it cannot find a church it
  // returns the nearest plausible one instead -- and several different
  // churches in a batch then resolve to the SAME place. Measured on
  // Austin's 411: 17 places came back more than once in the rejected
  // pile, one of them four times, and 12 rows in the ACCEPTED pile --
  // the file that gets imported -- shared six places between them.
  //
  //   Church in Austin          <- "The Church in Tulsa"
  //   Faith Lutheran (ELCA)     <- "Oriental Mission Church at Austin"
  //                             <- "Grace Korean Church"
  //   Hill Country Bible Church <- itself, and "Association of Hill
  //                                Country Churches"
  //
  // The second and third are the common shape: a congregation that
  // RENTS SPACE in another church's building. The address check cannot
  // catch it, because the address is genuinely right -- it is the
  // building. What is wrong is the phone number and website, which
  // belong to the host.
  //
  // At most one row can be the place. The best name match keeps it; the
  // rest go to .check.csv with their contacts dropped. A tie means
  // neither is clearly the occupant, so all of them go.
  const byPlace = new Map();
  accepted.forEach(a => {
    if (!a.place) return;
    if (!byPlace.has(a.place)) byPlace.set(a.place, []);
    byPlace.get(a.place).push(a);
  });
  const demoted = new Set();
  byPlace.forEach((group, place) => {
    if (group.length < 2) return;
    const best = Math.max.apply(null, group.map(a => a.score));
    const winners = group.filter(a => a.score === best);
    // Strictly one winner, or nobody wins. Two rows scoring identically
    // against the same place is exactly the case where guessing is
    // worse than asking.
    // ...and the winner has to actually look like the place. Both
    // "Grace Korean Church" and "Oriental Mission Church at Austin"
    // resolved to Faith Lutheran Church (ELCA) -- two congregations
    // renting the same building, neither of them the host. Keeping the
    // higher of two wrong answers is still a wrong answer.
    //
    // 60 is a floor, not a fitted cut-off. Across the six real groups
    // in Austin the genuine winners scored 65, 67, 75, 100 and 100, and
    // the false one 42; anywhere in that gap behaves the same. It also
    // fails in the safe direction -- too high only sends more rows to a
    // person, and can never put one in the import file.
    const WINNER_FLOOR = 60;
    const keep = (winners.length === 1 && winners[0].score >= WINNER_FLOOR) ? winners[0] : null;
    group.forEach(a => {
      if (a === keep) return;
      demoted.add(a.i);
      check.push([a.row.name, a.row.denomination, a.row.address, '', '',
                  'another church resolved to this same place', a.score, 'yes', '',
                  a.r.detail, a.types]);
    });
  });
  if (demoted.size) {
    // Rebuild rather than splice, so the surviving indices stay valid.
    const kept = yes.filter((_, i) => !demoted.has(i));
    yes.length = 0;
    kept.forEach(rw => yes.push(rw));
  }

  function write(suffix, head, data) {
    fs.writeFileSync(base + suffix, head + '\n' + data.map(csvLine).join('\n') + (data.length ? '\n' : ''));
  }
  write('.enriched.csv', 'name,denomination,address,phone,website,matched,match_detail,place_types', enriched);
  write('.yes.csv', 'name,denomination,address,phone,website', yes);
  write('.no.csv', 'name,denomination,address', no);
  // Best-looking first, so the decision boundary is in one place
  // instead of scattered down the file.
  check.sort((a, b) => b[6] - a[6]);
  write('.check.csv', 'name,denomination,address,phone,website,why,name_match,same_area,suggested_address,match_detail,place_types', check);
  write('.other-faith.csv', 'name,denomination,address,phone,website,likely,match_detail', otherFaithRows);
  write('.type-mismatch.csv', 'name,denomination,address,phone,website,matched,match_detail,place_types', mismatch);

  const pct = n => (enriched.length ? Math.round((n / enriched.length) * 100) : 0) + '%';
  console.log('\n' + path.basename(FILE) + (DRY ? '   [DRY RUN -- no lookups, no spend]' : ''));
  console.log('  rows in batch   ' + rows.length.toLocaleString());
  console.log('  looked at       ' + enriched.length.toLocaleString() + (LIMIT ? '   (--limit ' + LIMIT + ')' : ''));
  console.log('  billable calls  ' + calls.toLocaleString());
  console.log('  from cache      ' + cached.toLocaleString());
  if (unknown) console.log('  lookup failed   ' + unknown.toLocaleString() + '   not cached -- re-run to retry these');
  console.log('');
  console.log('  confirmed       ' + yes.length.toLocaleString() + '  ' + pct(yes.length) + '  -> ' + path.basename(base) + '.yes.csv  (import this)');
  console.log('  wrong address   ' + check.length.toLocaleString() + '  ' + pct(check.length) + '  -> ' + path.basename(base) + '.check.csv  (read these, best first)');
  if (ACCEPT_SIMILAR) console.log('  of which promoted by --accept-similar ' + ACCEPT_SIMILAR + ': ' + promoted.toLocaleString() + '  (using Google\'s address)');
  console.log('  nothing found   ' + no.length.toLocaleString() + '  ' + pct(no.length) + '  -> ' + path.basename(base) + '.no.csv');
  if (demoted.size) console.log('  of the confirmed, ' + demoted.size + ' shared a Google place with another church and were moved to check');
  if (otherFaithRows.length) console.log('  another faith  ' + otherFaithRows.length + '  -> ' + path.basename(base) + '.other-faith.csv  (not a Christian congregation -- read before importing)');
  console.log('  found, but not a place of worship by type: ' + mismatch.length.toLocaleString() + '  -> ' + path.basename(base) + '.type-mismatch.csv');
  const withPhone = enriched.filter(r => r[3]).length, withSite = enriched.filter(r => r[4]).length;
  console.log('  phone           ' + withPhone.toLocaleString() + '  ' + pct(withPhone));
  console.log('  website         ' + withSite.toLocaleString() + '  ' + pct(withSite));
})().catch(e => {
  console.error('\nStopped: ' + e.message);
  console.error('Nothing already looked up is lost -- results are cached as they land, so re-running resumes.');
  process.exit(1);
});
