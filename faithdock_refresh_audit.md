# FaithDock "Requires Refresh" Audit

**Status: three named examples checked directly against the actual
code (build 2026-09-16-v46), one real bug found and fixed, plus a
systematic pattern for finding others.** This isn't an exhaustive
site-wide check — the file is 24,000+ lines now — but it's evidence,
not guesses, on the examples given, and a concrete way to keep
checking the rest.

## The three named examples

**Following churches — already fixed, thoroughly.** `applyFollowState()`
updates every matching heart button across every view (directory
card, directory row, church profile page) the moment you click one,
optimistically, before the network write even finishes, and reverts
if the write fails. The code comments show this was already a real,
reported bug — the "My Churches" page's own Unfollow button used to be
a separate code path that never told any other page's heart it had
changed, so Directory kept showing a church as followed until
something forced a fresh render. That's been fixed: both places now
call the same shared sync function. Nothing further needed here.

**Profile changes — one real gap found and fixed.** Saving a new
display name updated the Profile page's own header
(`#profile-name`) immediately — confirmed in the code before this
audit. What it *didn't* update: the nav bar's own name bubble
(`#nav-user-name`), a completely separate element set once at sign-in
and never touched by the save handler. So changing your name updated
the page you were looking at but left the nav bar showing your old
name until a hard refresh. **Fixed** — the same handler now updates
both elements. Phone number and age range don't have this problem:
neither is displayed anywhere else in the app (age range specifically
only feeds anonymized aggregate reports, never a live display), so
there's no second element that could go stale for those two fields.

**Staff permission changes — architecture already sound, one
real limit worth knowing about.** `getMyChurch()` — the function
basically everything permission-related reads from — is called fresh
at 78 separate places across the app, with only a 1.5-second
de-duplication cache to avoid redundant network calls when several UI
pieces ask "what's my church" in the same instant on page load. There's
no long-lived stale cache: no `window.myChurch` snapshot taken once at
sign-in and read forever after. Concretely, this means an admin's own
staff list refreshes immediately after saving permission changes
(confirmed: `loadTeamPanel()` is called right after a successful save),
and a staff member whose permissions were just changed will see
correct, fresh data the next time they navigate anywhere that checks
permissions — no refresh needed for that case either.

**The one real limit, and it's not really fixable without a bigger
feature:** if a staff member is already sitting on a page *when* an
admin changes their permissions elsewhere, nothing pushes that update
to their open tab in real time — they'd need to navigate somewhere (or
refresh) to see it, since there's no live subscription (e.g. Supabase
Realtime) watching for that. This is a fundamentally different kind of
problem than the other two — those were about your own action not
updating your own screen, correctly fixable with better JS. This one
is about someone else's action reaching your already-open tab, which
needs a live connection to solve properly, not just a better click
handler. Worth knowing as a real, separate feature (built on Supabase
Realtime) if it matters enough to prioritize — not a quick fix.

## The general pattern, for checking anything beyond these three

The actual bug class here is: **the same piece of data is displayed in
more than one place, and updating it in one place doesn't update the
others.** The nav-bar-name bug is the clearest example — one save
handler, two display locations, only one got touched. Use this
checklist for anything else worth checking:

1. **Does this piece of data appear anywhere else in the UI besides
   the form that edits it?** (Name appears in the nav bar *and* the
   Profile page header — two places. Phone number appears nowhere
   else — one place, nothing to keep in sync.)
2. **If yes, does the save handler update every location, or just the
   one on the current page?** Search for every `document.getElementById`
   or `document.querySelectorAll` reference to that data's display
   element(s), not just the one sitting next to the input being edited.
3. **Likely other candidates worth checking with this same method**,
   based on data that's known to render in multiple places elsewhere in
   this app: a church's name/logo (shown on its own profile page, in
   directory cards, in "My Churches," and possibly in nav/dashboard
   headers if you're viewing as its owner) — does editing a church's
   name or logo in Dashboard Settings update all of those, or just
   Dashboard's own view? Same question for a user's own profile photo,
   which — per the same reasoning as the name bug — may update
   `#profile-photo-preview` but not appear anywhere else the way the
   name does in the nav bar (worth confirming there isn't a second
   photo display elsewhere before assuming it's fine). Event details
   (title, capacity, "almost full" status) are also worth a look,
   since those can appear in a directory listing, an event detail
   page, and a calendar view simultaneously.

This checklist — not a promise that everything's now checked — is the
practical way to keep finding the rest of these without re-reading the
entire file line by line every time a tester reports another one.
