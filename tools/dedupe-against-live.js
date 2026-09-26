#!/usr/bin/env node
//
// Compares a batch that is about to be imported against the churches
// already in the live directory, and writes a copy with the duplicates
// taken out.
//
//   node tools/dedupe-against-live.js --file churchfinder-batches/cf-782-san-antonio.yes.csv
//
// Writes, next to the input:
//   <batch>.import.csv      what to actually import
//   <batch>.duplicates.csv  what was dropped, and what it matched
//
// ---------------------------------------------------------------------
// WHY THE IMPORTER'S OWN DEDUPE IS NOT ENOUGH
//
// admin_import_churches has "on conflict (dedupe_key) do nothing", which
// keys on name and address. That catches the same row twice. It does not
// catch the same CHURCH under two different names, and two sources name
// churches differently -- the IRS has the legal name, churchfinder has
// what the church calls itself:
//
//   Cathedral of Faith              vs  Cathedral of Faith of San Antonio
//   Valley Hi First Baptist Church  vs  Valley-Hi First Baptist Church
//   Northwest Church of Christ      vs  Northwest Church of Christ of
//                                       San Antonio Texas
//
// 15 of churchfinder's 466 confirmed San Antonio rows were already in
// the directory under a name like that -- 3%, invisible to dedupe_key.
//
// ---------------------------------------------------------------------
// THE STREET NUMBER IS REQUIRED, and this is why
//
// Name similarity alone produces confident nonsense across metros,
// because denominational churches reuse names. Measured on this same
// batch, all of these are DIFFERENT churches that match by name:
//
//   Saint Paul Lutheran Church      San Antonio  /  Austin
//   Our Savior Lutheran Church      San Antonio  /  Austin
//   Hope Lutheran Church            San Antonio  /  Austin
//   Gethsemane Lutheran Church      San Antonio  /  Austin
//   Northwest Hills United Methodist San Antonio /  Austin
//
// Requiring the same street number as well drops all five and keeps
// every real duplicate. A pair that matches by name but not by number
// goes to the file to read, never dropped -- it might be one church
// that moved, and that is a judgement.
//
// ---------------------------------------------------------------------
// WHAT IT CANNOT SEE
//
// search_churches returns only churches that are NOT hidden. Hidden rows
// -- 487 at the time of writing, mostly the non-Christian and
// zero-signal listings filtered out after the San Antonio import -- are
// invisible here, so a duplicate of one of those will not be caught.
// That is the safe direction to fail in: re-importing a listing that is
// already hidden is a smaller problem than dropping a real church.
//
// Uses the anon key that already ships in index.html, read from there so
// there is no second copy to go stale. It is a public key; search_churches
// is the same call the directory page makes.

const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
function arg(n, d) { const i = args.indexOf('--' + n); return i !== -1 && args[i + 1] ? args[i + 1] : d; }
const FILE = arg('file', '');
const MIN_SIM = parseFloat(arg('similarity', '0.8'));

if (!FILE || !fs.existsSync(FILE)) {
  console.error('Usage: node tools/dedupe-against-live.js --file <batch>.yes.csv');
  process.exit(1);
}

// ---- the public client, read out of the page -------------------------
const page = fs.readFileSync('index.html', 'utf8');
const url = (page.match(/https:\/\/[a-z0-9]+\.supabase\.co/) || [])[0];
// Two formats, because Supabase changed it: the current publishable
// key (sb_publishable_...) and the older anon JWT (eyJ...). Both are
// public and ship in the page; this looks for whichever is there rather
// than assuming, after assuming the JWT form and finding none.
const key = (page.match(/sb_publishable_[A-Za-z0-9_-]{10,}/) ||
             page.match(/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}/) || [])[0];
if (!url || !key) {
  console.error('Could not find the Supabase URL or anon key in index.html.');
  process.exit(1);
}

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
const qq = v => { const s = String(v == null ? '' : v); return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
const csvLine = c => c.map(qq).join(',');

// "Church" and the city name are removed before comparing: nearly every
// row contains them, so leaving them in inflates every score towards a
// match and makes the threshold meaningless.
const STOP = new Set(['the', 'of', 'a', 'an', 'and', 'inc', 'tx', 'texas', 'de', 'la', 'el', 'en', 'y', 'church', 'iglesia']);

// THE CITY COMES OUT OF THE NAME TOO, and it is not optional. One
// source writes "Cathedral of Faith" and the other "Cathedral of Faith
// of San Antonio"; with the city left in, those score 0.50 and the pair
// is missed. With it out, 1.00. Eleven of the fifteen real duplicates
// in this batch were invisible without this.
//
// Taken from the row's own address rather than hardcoded, so it works
// for Austin and Houston without being told about them.
function cityTokens(address) {
  const city = (String(address || '').split(',')[1] || '').trim().toLowerCase();
  return new Set(city.replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/).filter(Boolean));
}
function tok(name, address) {
  const drop = cityTokens(address);
  return String(name || '').normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/)
    .filter(w => w && !STOP.has(w) && !drop.has(w));
}
const streetNo = a => ((String(a).match(/^\s*(\d+)/) || [])[1] || '');

(async function main() {
  process.stdout.write('Reading the live directory... ');
  let live = [];
  for (let off = 0; off < 20000; off += 200) {
    const res = await fetch(url + '/rest/v1/rpc/search_churches', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: key, Authorization: 'Bearer ' + key },
      body: JSON.stringify({ p_keyword: null, p_limit: 200, p_offset: off })
    });
    if (!res.ok) { console.error('\nsearch_churches failed: HTTP ' + res.status + ' ' + (await res.text()).slice(0, 200)); process.exit(1); }
    const page = await res.json();
    if (!page || !page.length) break;
    live = live.concat(page);
    if (page.length < 200) break;
  }
  console.log(live.length.toLocaleString() + ' visible churches');

  const index = live.map(c => ({ name: c.name, addr: c.address || '', t: new Set(tok(c.name, c.address)), no: streetNo(c.address) }));

  const lines = fs.readFileSync(FILE, 'utf8').split(/\r?\n/).filter(l => l.length);
  const header = lines[0];
  const h = splitCsvLine(header).map(x => x.trim().toLowerCase());
  const iN = h.indexOf('name'), iA = h.indexOf('address');
  if (iN === -1 || iA === -1) { console.error('That CSV has no name/address column.'); process.exit(1); }

  const keep = [], dropped = [], review = [];
  lines.slice(1).forEach(line => {
    const c = splitCsvLine(line);
    const t = new Set(tok(c[iN], c[iA])), no = streetNo(c[iA]);
    let best = 0, match = null;
    for (const d of index) {
      let hit = 0; t.forEach(x => { if (d.t.has(x)) hit++; });
      const j = (t.size && d.t.size) ? hit / (t.size + d.t.size - hit) : 0;
      if (j > best) { best = j; match = d; }
    }
    if (best >= MIN_SIM && match && no && match.no === no) {
      dropped.push([c[iN], c[iA], match.name, match.addr, best.toFixed(2)]);
    } else if (best >= MIN_SIM && match) {
      review.push([c[iN], c[iA], match.name, match.addr, best.toFixed(2)]);
      keep.push(line);
    } else {
      keep.push(line);
    }
  });

  const base = FILE.replace(/\.csv$/i, '');
  fs.writeFileSync(base + '.import.csv', header + '\n' + keep.join('\n') + '\n');
  fs.writeFileSync(base + '.duplicates.csv',
    'name,address,matched_existing_name,matched_existing_address,similarity\n' +
    dropped.map(csvLine).join('\n') + (dropped.length ? '\n' : ''));
  fs.writeFileSync(base + '.same-name-elsewhere.csv',
    'name,address,existing_name,existing_address,similarity\n' +
    review.map(csvLine).join('\n') + (review.length ? '\n' : ''));

  console.log('');
  console.log('  rows in batch        ' + (lines.length - 1).toLocaleString());
  console.log('  already in directory ' + dropped.length.toLocaleString() + '  -> ' + path.basename(base) + '.duplicates.csv');
  console.log('  same name elsewhere  ' + review.length.toLocaleString() + '  -> ' + path.basename(base) + '.same-name-elsewhere.csv  (KEPT -- different street number, read if curious)');
  console.log('  to import            ' + keep.length.toLocaleString() + '  -> ' + path.basename(base) + '.import.csv');
})();
