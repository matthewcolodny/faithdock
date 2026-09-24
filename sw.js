/* FaithDock service worker.
 *
 * WHAT THIS IS FOR, and what it deliberately is not.
 *
 * It exists so the app can be installed to a home screen and still open
 * without a signal. It is NOT a speed optimisation, and that is a
 * choice rather than an oversight -- see the fetch handler below.
 *
 * THE ONE RULE: NETWORK FIRST, ALWAYS.
 *
 * The usual service worker serves from its cache and updates in the
 * background, which is faster and means somebody can sit on a build
 * from last Tuesday without knowing. This project ships several builds
 * a day, by hand, and the footer carries a version stamp people are
 * asked to read back. A cache-first worker would make that stamp lie.
 *
 * So every request goes to the network first. The cache is only reached
 * for when the network fails -- which is exactly and only the offline
 * case. Nobody can get a stale app while they have a signal.
 *
 * WHAT IT CACHES: the shell. index.html, pure-logic.js, the manifest,
 * the icons. Not data -- every panel still asks Supabase for its rows,
 * so opening the app offline gets you the frame and a set of panels
 * reporting they cannot load. That is honest, and better than a blank
 * page, but it is not an offline app. Real offline check-in would mean
 * queueing writes locally, which is a separate piece of work.
 *
 * WHAT IT NEVER TOUCHES: anything cross-origin. Supabase, Stripe,
 * Google Fonts and Cloudflare Turnstile all go straight through
 * untouched. Caching an API response here would be a way to serve
 * somebody another church's stale directory, and caching a Stripe
 * request is not something to be clever about.
 */

// Bump this to evict every previously cached file. It does not need
// bumping for ordinary app changes -- network-first means new builds
// arrive on their own.
const CACHE = 'faithdock-shell-v1';

// The whole app is one HTML file plus one script, so the "shell" is
// genuinely short.
// DOC is the one key every navigation is stored under, whatever URL
// was actually asked for. Without it '/' and '/index.html' become two
// entries for the same document that drift apart -- measured: a reload
// refreshed '/' to the new build while '/index.html' sat one build
// behind, so which version you got offline depended on which URL you
// happened to type.
const DOC = './index.html';

const SHELL = [
  DOC,
  './pure-logic.js',
  './manifest.webmanifest',
  './icons/icon-512.png',
  './icons/icon-512-maskable.png',
  './icons/icon-192.png',
  './icons/icon.svg',
  './icons/icon-maskable.svg',
  './icons/apple-touch-icon.png'
];

self.addEventListener('install', function (event) {
  event.waitUntil(
    caches.open(CACHE)
      // addAll rejects the whole install if ANY file 404s, which would
      // leave the app with no worker at all. Each file is added on its
      // own so one missing icon cannot take the rest down with it.
      .then(function (cache) {
        return Promise.all(SHELL.map(function (url) {
          return cache.add(url).catch(function (err) {
            console.warn('[sw] could not pre-cache', url, err);
          });
        }));
      })
      // Take over straight away rather than waiting for every tab using
      // the old worker to close. Combined with clients.claim below, a
      // deployed change reaches people on their next load.
      .then(function () { return self.skipWaiting(); })
  );
});

self.addEventListener('activate', function (event) {
  event.waitUntil(
    caches.keys()
      .then(function (names) {
        return Promise.all(names.map(function (name) {
          return name === CACHE ? null : caches.delete(name);
        }));
      })
      .then(function () { return self.clients.claim(); })
  );
});

self.addEventListener('fetch', function (event) {
  const req = event.request;

  // Only GETs, and only our own origin. Everything else -- Supabase
  // reads and writes, Stripe, fonts, Turnstile -- is none of this
  // worker's business.
  if (req.method !== 'GET') return;
  if (new URL(req.url).origin !== self.location.origin) return;

  event.respondWith(
    fetch(req)
      .then(function (res) {
        // Only a real, complete, same-origin 200 is worth keeping. A
        // 404 page cached under index.html's name would be served to
        // somebody offline as if it were the app.
        if (res && res.status === 200 && res.type === 'basic') {
          const copy = res.clone();
          // Navigations all collapse onto DOC. Every route in FaithDock
          // is a hash on the same document, so there is only ever one
          // HTML file to keep and one copy of it worth having.
          const key = req.mode === 'navigate' ? DOC : req;
          // waitUntil, not a bare promise. A service worker is killed
          // as soon as its event settles, and respondWith settles the
          // moment the response is handed over -- so a detached
          // cache.put() is a write the browser is free to abandon.
          // Observed exactly that: the page showed a new build while
          // the cache still held the previous one, which would have
          // meant going offline served a version older than the last
          // one actually seen.
          event.waitUntil(caches.open(CACHE).then(function (cache) {
            return cache.put(key, copy);
          }));
        }
        return res;
      })
      .catch(function () {
        // Offline. Serve whatever we have.
        // A navigation offline wants the document, whatever URL it
        // asked for -- matching the raw request would miss for any
        // path that was never visited while online.
        if (req.mode === 'navigate') {
          return caches.match(DOC).then(function (doc) {
            return doc || Response.error();
          });
        }
        return caches.match(req).then(function (hit) {
          return hit || Response.error();
        });
      })
  );
});
