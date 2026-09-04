// pure-logic.js
//
// Pure, dependency-free logic pulled out of index.html specifically
// so it can be unit tested outside the browser — no DOM, no
// Supabase, no fetch, nothing that only works inside a page. This
// file is loaded by index.html via a normal <script> tag and is the
// single source of truth; pure-logic.test.js requires this exact
// file rather than a duplicated copy, so a fix here can never
// silently drift out of sync with what the tests actually check.
//
// Works both as a browser global (window.FaithDockPureLogic) and as
// a Node module (module.exports), same file either way.

(function (root) {
  // Computes the Saturday/Sunday range for "this weekend" relative
  // to `now`. If today is already Saturday or Sunday, the range
  // covers the remainder of the current weekend rather than jumping
  // forward to next week.
  //
  // This exact function already shipped one real bug: a naive
  // "days until Saturday" formula (using modulo to wrap negative
  // results forward) sends Sunday all the way to *next* Saturday,
  // silently skipping the tail end of the weekend someone is
  // actually standing in. The tests for this function exist
  // specifically to keep that fixed.
  function computeWeekendRange(now) {
    var dayOfWeek = now.getDay();
    var saturday, sunday;
    if (dayOfWeek === 6) {
      saturday = now;
      sunday = new Date(now.getTime() + 86400000);
    } else if (dayOfWeek === 0) {
      saturday = now;
      sunday = now;
    } else {
      var daysUntilSaturday = 6 - dayOfWeek;
      saturday = new Date(now.getTime() + daysUntilSaturday * 86400000);
      sunday = new Date(saturday.getTime() + 86400000);
    }
    return { saturday: saturday, sunday: sunday };
  }

  var api = {
    computeWeekendRange: computeWeekendRange
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  } else {
    root.FaithDockPureLogic = api;
  }
})(typeof window !== 'undefined' ? window : this);
