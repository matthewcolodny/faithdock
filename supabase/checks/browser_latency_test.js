// Paste this whole file into your browser console (F12 -> Console) on
// faithdock.com, press Enter, wait about fifteen seconds.
//
// WHAT THE LAST RUN ESTABLISHED
//
//   one at a time (ms):  138, 101, 100, 90, 86
//   six at once   (ms):  85, 167, 251, 336, 421, 513
//   six, wall clock:     514 ms
//
// Your network is fine -- a request costs about 90 ms. That rules out
// the slow-path explanation completely.
//
// But the "six at once" numbers are a perfect staircase in 85 ms steps,
// which is what strictly-one-at-a-time looks like, not what six in
// parallel looks like.
//
// THE FLAW IN THAT TEST, WHICH IS MINE
//
// I sent six IDENTICAL urls. Browsers deliberately serialise identical
// in-flight GETs so the second one can reuse the first one's cached
// response. So that staircase may be my test's own doing rather than
// anything about this app, and concluding from it would be the same
// mistake I have made repeatedly here.
//
// This run fixes that and adds the comparison that actually matters:
//
//   1. six DIFFERENT urls, raw fetch      -- can the browser parallelise?
//   2. six DIFFERENT queries, via the app's own supabase client
//
// If 1 is parallel and 2 is a staircase, the serialisation is in the
// client library or in how this page uses it, and it is mine to fix.
// If both are staircases, something below the page is serialising and
// the answer is elsewhere.

(async () => {
  const BASE = 'https://doerahlrdknedoknawex.supabase.co/rest/v1/churches';
  const KEY = 'sb_publishable_zdoYSKnhvJyEdhhbCV_CAw_owRZ3f-V';

  // Six genuinely different urls, so nothing can be coalesced with
  // anything else. Different offsets, same trivial cost.
  const urls = [0, 1, 2, 3, 4, 5].map(
    n => BASE + '?select=id&limit=1&offset=' + n
  );

  async function timeIt(fn) {
    const t = performance.now();
    try { await fn(); } catch (e) { return 'FAIL'; }
    return Math.round(performance.now() - t);
  }

  // ---- 1. raw fetch, six different urls, all at once ---------------
  const rawStart = performance.now();
  const raw = await Promise.all(
    urls.map(u => timeIt(() => fetch(u, { headers: { apikey: KEY } })))
  );
  const rawWall = Math.round(performance.now() - rawStart);

  // ---- 2. the page's own client, six different queries --------------
  let cli = ['supabase client not found on window'];
  let cliWall = -1;
  if (window.supabase && window.supabase.from) {
    const cliStart = performance.now();
    cli = await Promise.all(
      [0, 1, 2, 3, 4, 5].map(n =>
        timeIt(() => window.supabase.from('churches').select('id').range(n, n))
      )
    );
    cliWall = Math.round(performance.now() - cliStart);
  }

  // ---- 3. is an auth lock in play? ----------------------------------
  // supabase-js serialises auth work behind a Web Lock. If one is held
  // while every request waits for a token, that is the serialiser.
  let locks = 'navigator.locks not available';
  try {
    if (navigator.locks && navigator.locks.query) {
      const q = await navigator.locks.query();
      locks = 'held=[' + (q.held || []).map(l => l.name).join(', ') + ']'
            + '  pending=[' + (q.pending || []).map(l => l.name).join(', ') + ']';
    }
  } catch (e) { locks = 'lock query failed: ' + e.message; }

  console.log(
    '=== FaithDock parallelism test ===\n' +
    'raw fetch, 6 different urls (ms): ' + raw.join(', ') + '\n' +
    '   wall clock:                    ' + rawWall + ' ms\n' +
    'supabase client, 6 queries  (ms): ' + cli.join(', ') + '\n' +
    '   wall clock:                    ' + cliWall + ' ms\n' +
    'web locks:                        ' + locks + '\n' +
    'protocol (this page):             ' +
      ((performance.getEntriesByType('resource')
        .filter(r => r.name.includes('supabase.co'))[0] || {}).nextHopProtocol || 'unknown') + '\n' +
    '=== end (select from "===" to "===" and copy) ==='
  );
})();
