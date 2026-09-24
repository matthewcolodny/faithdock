# FaithDock

Visual concept / prototype for FaithDock — a single-file frontend deployed as a static site.

## Files
- `index.html` — the entire application (structure, styles, and logic in one file)
- `pure-logic.js` — a small shared logic module loaded by `index.html`, kept separate so it can be unit-tested independently (see the "Shared with pure-logic.js" comments in index.html)
- `manifest.webmanifest`, `sw.js`, `icons/` — what makes the site installable to a home screen and able to open without a signal. See "Installable app" below.
- `tools/make-icon.js` — regenerates the icon PNGs from the mark. No dependencies; not part of the deploy.

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

## Build stamp
The footer of `index.html` carries a build version stamp (`build YYYY-MM-DD-vNNN`), bumped by hand after each round of changes. Check it against the latest commit here to confirm what's actually live.
