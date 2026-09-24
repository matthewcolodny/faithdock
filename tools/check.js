/* Pre-deploy sanity checks for FaithDock.
 *
 * WHY THIS EXISTS. Cloudflare Pages deploys whatever lands on main.
 * There is nothing between a typo and faithdock.com. A stray "*!/" left
 * mid-edit in a style block silently invalidates every rule after it,
 * and the page still returns 200 -- it just renders wrong. That very
 * nearly shipped once. This is the thing that says no.
 *
 * WHAT IT IS NOT. It is not a linter, a formatter or a validator. It
 * has no opinions about style and it will not tell you your code is
 * ugly. Every check here corresponds to a way this project has actually
 * broken, or could break silently enough that nobody would notice until
 * a user did.
 *
 * NO DEPENDENCIES, same as tools/make-icon.js. Node's own parser does
 * the JavaScript half; the rest is a few hundred lines of counting.
 * Adding a package here would mean a lockfile and a node_modules tree
 * in a repo whose main virtue is not having one.
 *
 *   node tools/check.js
 *
 * Exit code 0 = safe to deploy. Non-zero = do not.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const problems = [];
const notes = [];
function fail(where, msg) { problems.push(where + ': ' + msg); }
function note(msg) { notes.push(msg); }

const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');

// Line number for a character offset, so a failure points somewhere.
function lineAt(offset) { return html.slice(0, offset).split('\n').length; }

// ---------------------------------------------------------------------
// 1. JavaScript actually parses.
// ---------------------------------------------------------------------
// Every inline <script> in index.html, plus the standalone files.
// `node --check` parses without executing, which is the whole point:
// it catches a syntax error without needing a browser, a server or any
// of the app's runtime dependencies.
//
// .mjs for type="module", because module syntax is a parse error in a
// classic script and Node picks the goal symbol from the extension.

function checkJsSyntax() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fdcheck-'));
  let n = 0;

  const re = /<script([^>]*)>([\s\S]*?)<\/script>/gi;
  let m;
  while ((m = re.exec(html)) !== null) {
    const attrs = m[1] || '';
    const body = m[2] || '';
    if (/\ssrc\s*=/i.test(attrs)) continue;        // external, nothing inline to parse
    if (!body.trim()) continue;
    const isModule = /type\s*=\s*["']module["']/i.test(attrs);
    const line = lineAt(m.index);
    const file = path.join(tmp, 'inline-' + line + (isModule ? '.mjs' : '.js'));
    fs.writeFileSync(file, body);
    try {
      execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' });
      n++;
    } catch (e) {
      const out = (e.stderr ? e.stderr.toString() : '') || e.message;
      // Node reports a line relative to the extracted block; translate
      // it back to index.html so the number is usable.
      const rel = (out.match(/inline-\d+\.m?js:(\d+)/) || [])[1];
      const abs = rel ? (line + parseInt(rel, 10) - 1) : line;
      fail('index.html:' + abs,
        'inline <script> does not parse\n      ' + out.split('\n').slice(0, 4).join('\n      ').trim());
    }
  }

  for (const rel of ['pure-logic.js', 'sw.js', 'tools/make-icon.js', 'tools/check.js']) {
    const p = path.join(ROOT, rel);
    if (!fs.existsSync(p)) continue;
    try { execFileSync(process.execPath, ['--check', p], { stdio: 'pipe' }); n++; }
    catch (e) { fail(rel, 'does not parse\n      ' + (e.stderr ? e.stderr.toString().split('\n')[0] : e.message)); }
  }

  fs.rmSync(tmp, { recursive: true, force: true });
  note(n + ' JavaScript blocks/files parse');
}

// ---------------------------------------------------------------------
// 2. CSS is structurally intact.
// ---------------------------------------------------------------------
// Not a CSS validator -- it does not know a property from a hole in the
// ground. It checks the two things that silently destroy a stylesheet
// from the point of failure onward, both of which are easy to do while
// editing by hand and impossible to see in a diff:
//
//   an unterminated /* comment  -- swallows the rest of the file
//   a stray */ with no opener   -- everything after it is garbage
//   unbalanced { }              -- rules merge or leak
//
// The stray-*/ case is the one that nearly shipped: a comment was split
// in two while being rewritten, leaving its tail floating in rule
// position.

function checkCssStructure() {
  const re = /<style([^>]*)>([\s\S]*?)<\/style>/gi;
  let m, blocks = 0;
  while ((m = re.exec(html)) !== null) {
    const css = m[2];
    const startLine = lineAt(m.index);
    blocks++;

    let i = 0, depth = 0, inComment = false, commentStart = 0, line = startLine;
    while (i < css.length) {
      const two = css.substr(i, 2);
      if (css[i] === '\n') line++;
      if (inComment) {
        if (two === '*/') { inComment = false; i += 2; continue; }
      } else {
        if (two === '/*') { inComment = true; commentStart = line; i += 2; continue; }
        if (two === '*/') { fail('index.html:' + line, 'stray "*/" with no opening comment'); i += 2; continue; }
        if (css[i] === '{') depth++;
        if (css[i] === '}') {
          depth--;
          if (depth < 0) { fail('index.html:' + line, 'unbalanced "}" -- more closes than opens'); depth = 0; }
        }
      }
      i++;
    }
    if (inComment) fail('index.html:' + commentStart, 'comment opened here is never closed');
    if (depth > 0) fail('index.html:' + startLine, '<style> block ends with ' + depth + ' unclosed "{"');
  }
  note(blocks + ' <style> blocks structurally intact');
}

// ---------------------------------------------------------------------
// 3. Every data-i18n key exists in BOTH languages.
// ---------------------------------------------------------------------
// A key that exists in neither renders as the key itself. A key that
// exists only in English silently falls back, so the Spanish side looks
// translated in testing and is not. Both have happened.

function checkI18nKeys() {
  const start = html.indexOf('var translations = {');
  if (start < 0) { fail('index.html', 'could not find the translations object'); return; }
  const open = html.indexOf('{', start);
  let depth = 0, end = -1;
  for (let i = open; i < html.length; i++) {
    if (html[i] === '{') depth++;
    else if (html[i] === '}') { depth--; if (depth === 0) { end = i; break; } }
  }
  if (end < 0) { fail('index.html', 'translations object is not brace-balanced'); return; }

  let dict;
  try {
    // A pure data literal. runInNewContext gives it no globals at all,
    // so there is nothing for it to reach even if that stopped being true.
    dict = vm.runInNewContext('(' + html.slice(open, end + 1) + ')', Object.create(null), { timeout: 5000 });
  } catch (e) {
    fail('index.html', 'translations object does not evaluate: ' + e.message);
    return;
  }
  if (!dict || !dict.en || !dict.es) { fail('index.html', 'translations is missing en or es'); return; }

  const ATTRS = ['data-i18n', 'data-i18n-placeholder', 'data-i18n-title',
                 'data-i18n-tip', 'data-i18n-label', 'data-i18n-data-placeholder'];
  const used = new Map();
  for (const attr of ATTRS) {
    const re = new RegExp(attr + '="([^"]+)"', 'g');
    let m;
    while ((m = re.exec(html)) !== null) {
      const key = m[1];
      // Skip attributes built by JavaScript rather than written out:
      //   data-i18n="' + actionKey + '"
      // The key is whatever the variable holds at render time, so there
      // is nothing to look up here. Those paths go through window.t(),
      // which falls back to English and then to the key itself, so a
      // bad one is visible rather than silent.
      if (/['"+]|\$\{/.test(key)) continue;
      if (!used.has(key)) used.set(key, lineAt(m.index));
    }
  }
  let missingEn = 0, missingEs = 0;
  for (const [key, line] of used) {
    if (!(key in dict.en)) { fail('index.html:' + line, 'data-i18n key "' + key + '" is not in the English dictionary'); missingEn++; }
    else if (!(key in dict.es)) { fail('index.html:' + line, 'data-i18n key "' + key + '" is missing from Spanish (would silently show English)'); missingEs++; }
  }
  note(used.size + ' data-i18n keys checked against ' +
       Object.keys(dict.en).length + ' en / ' + Object.keys(dict.es).length + ' es entries');
}

// ---------------------------------------------------------------------
// 4. The manifest parses and every file it promises exists.
// ---------------------------------------------------------------------
// A manifest icon that 404s is invisible until somebody installs the
// app, and a manifest is only read once at install time, so a bad one
// sticks until the app is removed and re-added.

function checkManifest() {
  const p = path.join(ROOT, 'manifest.webmanifest');
  if (!fs.existsSync(p)) { fail('manifest.webmanifest', 'missing'); return; }
  let mf;
  try { mf = JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch (e) { fail('manifest.webmanifest', 'is not valid JSON: ' + e.message); return; }
  for (const icon of (mf.icons || [])) {
    const rel = String(icon.src || '').replace(/^\//, '');
    if (!rel) { fail('manifest.webmanifest', 'an icon entry has no src'); continue; }
    if (!fs.existsSync(path.join(ROOT, rel))) fail('manifest.webmanifest', 'icon does not exist: ' + icon.src);
  }
  note((mf.icons || []).length + ' manifest icons present');
}

// ---------------------------------------------------------------------
// 5. Service worker shell files exist.
// ---------------------------------------------------------------------
// cache.add() on a missing file rejects. Each one is caught
// individually so a single 404 cannot take the install down, which is
// correct -- and also means it fails quietly. This is the loud version.

function checkServiceWorkerShell() {
  const p = path.join(ROOT, 'sw.js');
  if (!fs.existsSync(p)) { fail('sw.js', 'missing'); return; }
  const src = fs.readFileSync(p, 'utf8');
  const block = (src.match(/const SHELL = \[([\s\S]*?)\]/) || [])[1];
  if (!block) { note('sw.js SHELL list not found -- skipped'); return; }
  let n = 0;
  for (const m of block.matchAll(/'\.\/([^']+)'/g)) {
    if (!fs.existsSync(path.join(ROOT, m[1]))) fail('sw.js', 'SHELL lists a file that does not exist: ' + m[1]);
    n++;
  }
  note(n + ' service-worker shell files present');
}

// ---------------------------------------------------------------------
// 6. SVG comments contain no double hyphen.
// ---------------------------------------------------------------------
// "--" is illegal inside an XML comment. An SVG carrying one is not
// well-formed, and both <img> and Chrome's manifest icon loader refuse
// it -- while curl still returns 200 and the file still looks fine in
// an editor. Cost half a day once.

function checkSvgComments() {
  const dir = path.join(ROOT, 'icons');
  if (!fs.existsSync(dir)) return;
  let n = 0;
  for (const f of fs.readdirSync(dir).filter(f => f.endsWith('.svg'))) {
    const src = fs.readFileSync(path.join(dir, f), 'utf8');
    for (const m of src.matchAll(/<!--([\s\S]*?)-->/g)) {
      if (m[1].includes('--')) fail('icons/' + f, 'XML comment contains "--", which makes the file malformed');
    }
    n++;
  }
  note(n + ' SVG files checked for malformed comments');
}

// ---------------------------------------------------------------------
// 7. The build stamp is present and plausible.
// ---------------------------------------------------------------------
// People are asked to read it back. A missing or malformed one is worse
// than none, because it is trusted.

function checkBuildStamp() {
  const m = html.match(/build (\d{4}-\d{2}-\d{2}-v\d+)/);
  if (!m) { fail('index.html', 'no "build YYYY-MM-DD-vNNN" stamp found in the footer'); return; }
  note('build stamp ' + m[1]);
}

// ---------------------------------------------------------------------

checkJsSyntax();
checkCssStructure();
checkI18nKeys();
checkManifest();
checkServiceWorkerShell();
checkSvgComments();
checkBuildStamp();

for (const n of notes) console.log('  ok    ' + n);
if (problems.length) {
  console.log('');
  for (const p of problems) console.log('  FAIL  ' + p);
  console.log('\n' + problems.length + ' problem' + (problems.length === 1 ? '' : 's') + ' -- not safe to deploy.');
  process.exit(1);
}
console.log('\nAll checks passed.');
