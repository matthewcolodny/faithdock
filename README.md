# FaithDock

Visual concept / prototype for FaithDock — a single-file frontend deployed as a static site.

## Files
- `index.html` — the entire application (structure, styles, and logic in one file)
- `pure-logic.js` — a small shared logic module loaded by `index.html`, kept separate so it can be unit-tested independently (see the "Shared with pure-logic.js" comments in index.html)
- `manifest.webmanifest`, `sw.js`, `icons/` — what makes the site installable to a home screen and able to open without a signal. See "Installable app" below.
- `tools/make-icon.js` — regenerates the icon PNGs from the mark. No dependencies; not part of the deploy.
- `tools/prep-texas.js` — turns the IRS Exempt Organizations Business
  Master File for Texas into import-ready batches. No dependencies; not
  part of the deploy. See its header for why FOUNDATION=10 is the church
  test and why denomination and address are deliberately left alone.
- `tools/enrich-batch.js` — looks one prepared batch up against Google
  Places and splits it into found / not found / found-but-not-a-place-
  of-worship, adding phone and website. Run BEFORE importing. Needs a
  SERVER API key in `GOOGLE_PLACES_KEY` (the key in index.html is
  referrer-restricted and will refuse). One billable call per church, so
  start any batch with `--limit 5`, and use `--dry-run` to exercise it
  for free. Results are cached as they land, so an interrupted run
  resumes without paying twice. `--cached-only` re-scores what is
  already cached and buys nothing, for when the matching rules change.
  `.check.csv` is sorted by a name-similarity score; `--accept-similar N`
  promotes rows at or above N that are also in the same postal area,
  using Google's address rather than the IRS one. Off by default — set it
  after reading the sorted file, not before.

## Deploying
All of the above must be deployed together, at the same root level — `index.html` loads `pure-logic.js` via a relative `<script src="pure-logic.js">` tag, and the manifest, service worker and icons are referenced from the root (`/sw.js`, `/manifest.webmanifest`, `/icons/...`). On Cloudflare Pages, connecting this repo directly (rather than manual zip uploads) avoids them ever drifting out of sync on the live site.

**`sw.js` must stay at the root.** A service worker can only control
pages at or below its own path, so served from anywhere else it would
control nothing.

## Installable app
The site can be added to a phone's home screen and will open without a
signal. There is no separate app project and no build step: the
installed app IS this site, so **deploying a change updates it**. There
is nothing to submit, review or re-publish.

`sw.js` is deliberately **network-first** — it asks the network every
time and only falls back to its cache when that fails. It is therefore
not a speed optimisation. The reason is the build stamp in the footer:
a conventional cache-first worker would leave people running an old
build while the stamp told them otherwise. The trade is that being
installed costs nothing in freshness.

Offline it serves the shell only. Every panel still asks Supabase for
its data, so an offline launch shows the app frame with panels that
cannot load — honest, and better than a blank page, but not an offline
app. Offline check-in would mean queueing writes locally, which is
separate work.

### Icons
`tools/make-icon.js` generates the PNGs in `icons/` from the mark. Run
`node tools/make-icon.js`; it has no dependencies. Before it existed
the PNGs were binaries with no source, and regenerating one at a new
size meant rendering it elsewhere and moving the bytes across by hand —
which went wrong once, producing a file that was a structurally valid
PNG with its bottom half missing. The geometry in the script is
transcribed from `icons/icon.svg` and the two have to be kept in step
by hand.

Every icon is **fully opaque**. iOS composites a transparent icon onto
white, which is how the app first appeared as a navy mark inside a
white rounded card.

Two scales, matching the two SVGs: the plain icons at 80% for anywhere
the square is shown whole, and the `-maskable` ones at 62% for Android,
which crops the icon to its launcher's shape and only guarantees the
middle 80% survives.

**Don't expect a bigger icon to sharpen the launch screen.** It was
tried. The mark on Android's launch screen looked pixelated, so the
manifest went 192 → 512 → 1024, and it looked the same every time.
That screen is drawn from the icon baked into the installed app when
it was added to the home screen, which the system holds at its own
resolution and scales up; what the manifest offers does not change it.
The 1024s are kept because they cost a few KB and help any surface
that renders a manifest icon directly, but **they are not a fix for the
launch screen and there does not appear to be one from the web side.**

### The two launch screens
There are two, and only one is ours. **Android draws its own launch
screen before a byte of the page runs, and it cannot be turned off.**
It shows the app icon on `background_color`. The in-page layer
(`#fd-splash`, gated on `display-mode: standalone`) takes over from it
and covers the time it takes 2.5MB of HTML to become usable.

**`#fd-splash` carries no logo and no wordmark** — just navy and a
spinner. Three versions tried to blend it into the system screen: mark
beside a wordmark, mark above a wordmark, then the mark alone at a size
measured off a screenshot of the real thing. All three read as a second
screen, and the last one is why: the system's copy of the mark is
upscaled and soft, ours is drawn from vector data and is crisp. A
blurry image and a sharp one do not blend no matter how carefully they
are sized. So the mark appears exactly once per launch, on the system
screen, and this holds the colour afterwards.

**It only appears on a launch, never on a refresh.** An inline script
in the `<head>` reads the navigation type and puts `.fd-no-splash` on
`<html>` for `reload` and `back_forward`, which switches off both the
layer and the navy canvas. The script has to be in the head because the
splash is the first element in the body and paints the moment the body
starts parsing — hiding it from the script at the bottom of the file
would be thousands of lines too late.

The reasoning: a launch needs the hold, because the system screen has
just gone and 2.5MB of HTML is not usable yet. A refresh does not —
Chrome already draws its own spinner over the page you were looking at,
so ours just threw a full-screen navy interruption over a working
interaction. On a refresh the canvas goes back to `body`'s own
`--paper`, which propagates again once `html` has no background, so
there is no blue at all.

A spinner is fine and there is one, drawn with `::after` so the markup
stays a bare div. It reads as progress rather than as branding, so it
does not compete with the screen before it — that is the line, no
second logo, indicators welcome. It fades in on a 400ms delay so a
launch that beats it never flashes a spinner, and under
`prefers-reduced-motion` the ring goes complete and stops rotating
rather than sitting there as a lopsided arc.

It is dismissed on whichever comes first: `load`, or `DOMContentLoaded`
plus 250ms. Waiting for `load` alone was fine when the layer carried
the logo; a blank field that outstays the page under it just looks like
the app has hung, and `load` waits on Turnstile and DOMPurify from
their CDNs.

**A manifest change cannot reach an already-installed app.** The
manifest is read once, at install time. Testing any icon, colour or
name change means removing the app from the home screen and adding it
again.

## Loading, and not seeing it happen
The homepage used to assemble itself in front of you: the heading read
"Churches near you" and then rewrote itself to "Churches near San
Antonio", and the two card grids started at zero height and shoved the
page down when their data arrived. Three things address that, and a
full-screen cover until everything loads is deliberately **not** one of
them — see below.

**Nothing rewrites its own text.** `fd_last_geo` now remembers the place
*name* next to the coordinates it was resolved from, and an inline
script right after the headings paints it while the parser is still
working down the body. `fdPaintLocationHeadings()` is the single
implementation, called from all three places that can learn a location
(a remembered search, the cached guess, reverse geocoding finishing) —
plus `applyTranslations`, which would otherwise reset the headings to
their `data-i18n` default and undo the whole thing. First-ever visit
still transitions; nothing is known yet.

**Nothing jumps.** Both home grids ship skeleton cards in the markup, so
the grid is its full height in the first painted frame. The skeletons
reuse the real card classes (`.church-card`, `.thumb`, `.card-body`) and
hold an `&nbsp;` with transparent text, so their height matches by
construction rather than by hard-coded pixels that would drift.
`fd_grid_counts` remembers how many cards each grid really had, and
`fdTrimSkeletons()` trims to it — without that, three placeholders
standing in for one real event made the grid *shrink* by two card
heights, a bigger jump than the one being fixed.

**One fade, not five.** `paintGrid()` swaps a grid's contents and fades
the new set in together.

Measured after: cumulative layout shift **0**, no shift entries at all,
heading correct in its first frame.

**Why there is no "cover everything until loaded" screen.** There is no
definable moment when this app is finished loading — panels load per
route and the dashboard fetches its sections separately — so it would
mean inventing a completion signal that every panel has to report into,
and any one that doesn't hangs the cover. This file already carries
three comments about skeletons that stayed up when a path forgot to
clear them. It would also make the wait longer, since nothing is usable
until the slowest query returns.

## Checks before deploy
`node tools/check.js` — no dependencies, runs in about a second. It also
runs automatically on every push via `.github/workflows/check.yml`.

It is not a linter and has no opinions about style. Every check
corresponds to a way this project has actually broken, or could break
silently enough that only a user would notice:

- **Every inline `<script>` parses** (`node --check`, so nothing runs).
- **Every `<style>` block is structurally intact** — unterminated `/*`,
  a stray `*/`, unbalanced braces. This is the one it was written for: a
  comment split in two while being edited leaves a tail floating in rule
  position, which silently voids every rule after it while the page
  still returns 200.
- **Every `data-i18n` key exists in both dictionaries.** A key in
  neither renders as the key; a key in English only falls back silently,
  so the Spanish side looks translated and isn't. The first run of this
  check found `nav.logIn` where the dictionary says `nav.login` — the
  "Log in" link had never translated.
- **The manifest parses and every icon it names exists.** A manifest is
  read once at install time, so a bad one sticks until the app is
  removed and re-added.
- **Every service-worker shell file exists.** `cache.add` failures are
  caught individually so one 404 cannot fail the install, which also
  means they fail quietly.
- **No `--` inside an SVG comment.** Illegal in XML; the file still
  serves 200 and still looks fine in an editor, but `<img>` and Chrome's
  icon loader both refuse it.
- **The build stamp is present and well-formed.**

Cloudflare Pages does not wait for GitHub Actions, so this reports
rather than blocks — unless you use the branch workflow below and make
`checks` a required status check on `main`.

## Deploying and previewing
Cloudflare Pages builds this repository directly. **`main` is
production** (faithdock.com); **every other branch gets its own preview
URL** at `https://<branch>.<project>.pages.dev`, built the same way from
the same files.

Work on a branch when a change is worth seeing before it is live:

```bash
git checkout -b some-change
# ...edit...
git commit -am "..."
git push -u origin some-change      # Cloudflare builds a preview
```

Cloudflare comments the preview URL on the commit, and it is listed
under Workers & Pages → the project → Deployments. Test there, then
publish by merging:

```bash
git checkout main
git merge some-change
git push origin main                # this is what goes live
```

Previews run the real Supabase project, so they are not a sandbox —
data written from a preview is real data.

## Standing security checks
`supabase/checks/security_invariants.sql` asserts rather than prints,
and `.github/workflows/security-invariants.yml` runs it weekly. It
covers RLS being enabled, members-only events being invisible both
logged-out *and* to a signed-in account that is a member of nothing,
and the departures log not being readable by anon.

The second of those is the one that matters: the original hole was
missed because it was verified while signed out, where `auth.uid()` is
null — a test structurally incapable of catching a membership-keyed
bypass.

It needs one repository secret, `SUPABASE_DB_URL`; the workflow is
skipped rather than failed until that exists. Setup instructions are in
the comment at the top of the workflow. **Run the SQL by hand in the
Supabase SQL Editor once before trusting the schedule.**

The other files in `supabase/checks/` are diagnostic probes from
specific investigations — they print for a person to read and are not
meant to run unattended.

## Build stamp
The footer of `index.html` carries a build version stamp (`build YYYY-MM-DD-vNNN`), bumped by hand after each round of changes. Check it against the latest commit here to confirm what's actually live.
