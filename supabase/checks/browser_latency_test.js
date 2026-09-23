// Paste this whole file into your browser console (F12 -> Console) on
// faithdock.com, press Enter, and wait about ten seconds.
//
// WHAT IT SETTLES
//
// Three things are now measured and agree with each other:
//
//   - the SQL is fast          is_platform_admin, server-side mean 6.08 ms
//   - the project is fast      170-290 ms per request, measured from a
//                              different machine, six at once, just now
//   - your browser is slow     4365-6638 ms for the same class of request
//
// So the time is going somewhere between your browser and Supabase.
// There are two candidates and they need opposite fixes:
//
//   A. The path itself is slow -- your network, a VPN, a proxy, an
//      extension intercepting requests, DNS. Then every request is
//      slow, including this one, and no amount of rewriting the page
//      helps. The fix is on your machine or your connection.
//
//   B. The path is fine and the PAGE is queuing its own requests --
//      too many at once for the browser to open connections for, so
//      most of that "6638 ms" is time spent waiting in the browser's
//      own queue rather than on the wire. Then the fix is mine: fewer
//      requests per load.
//
// This asks the same endpoint the page asks, one request at a time,
// with nothing else competing. That removes queuing from the picture
// entirely -- so whatever it reports is the real cost of one request.

(async () => {
  const URL = 'https://doerahlrdknedoknawex.supabase.co/rest/v1/churches?select=id&limit=1';
  const KEY = 'sb_publishable_zdoYSKnhvJyEdhhbCV_CAw_owRZ3f-V';

  const one = [];
  for (let i = 0; i < 5; i++) {
    const t = performance.now();
    try { await fetch(URL, { headers: { apikey: KEY } }); }
    catch (e) { one.push('FAILED: ' + e.message); continue; }
    one.push(Math.round(performance.now() - t));
  }

  // And six at once, which is the shape the page actually produces.
  // If these are much worse than the one-at-a-time numbers, the
  // browser is queuing and the page is asking for too much at once.
  const t6 = performance.now();
  const six = await Promise.all(
    Array.from({ length: 6 }, async () => {
      const t = performance.now();
      try { await fetch(URL, { headers: { apikey: KEY } }); }
      catch (e) { return 'FAILED'; }
      return Math.round(performance.now() - t);
    })
  );
  const sixWall = Math.round(performance.now() - t6);

  console.log(
    '=== FaithDock latency test ===\n' +
    'one at a time (ms):  ' + one.join(', ') + '\n' +
    'six at once   (ms):  ' + six.join(', ') + '\n' +
    'six, wall clock:     ' + sixWall + ' ms\n' +
    'connection:          ' + (navigator.connection
        ? (navigator.connection.effectiveType || '?') + ', downlink ' +
          (navigator.connection.downlink || '?') + ' Mbps, rtt ' +
          (navigator.connection.rtt || '?') + ' ms'
        : 'not reported by this browser') + '\n' +
    '=== end (select from "===" to "===" and copy) ==='
  );
})();
