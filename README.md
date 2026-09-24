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

**Why 1024 and not 512.** Android 12 and up draw their own launch
screen from the app icon, at a size measured on a real phone as about
half the screen's width. Half of a 1080px screen is 540 physical
pixels, and a 512 icon only carries ~314px of actual mark inside it
(80% scale × the mark being ~77% of the viewBox). That is a 1.7×
upscale, and it looked it. 1024 puts ~630px behind the same 540, so it
is a downscale instead. The 512s stay for anything asking for that
size by name.

### The two launch screens
There are two, and only one is ours. **Android draws its own launch
screen before a byte of the page runs, and it cannot be turned off.**
It shows the app icon on `background_color` and nothing else — no name,
no text. The in-page splash (`#fd-splash`, gated on `display-mode:
standalone`) takes over from it and covers the time it takes 2.5MB of
HTML to become usable.

So the in-page splash shows **the mark alone**, at the same size, on
the same navy. Anything it shows that the system screen did not is a
visible second screen: a wordmark was tried, and it read exactly that
way — the mark shrank and a line of type appeared underneath.

Its size is a `vw` measurement, not a pixel value, because a fixed
pixel size was wrong twice. The system draws the mark at ~50% of screen
width; the mark is ~77% of the SVG's viewBox; hence `65vw`.

**A manifest change cannot reach an already-installed app.** The
manifest is read once, at install time. Testing any icon, colour or
name change means removing the app from the home screen and adding it
again.

## Build stamp
The footer of `index.html` carries a build version stamp (`build YYYY-MM-DD-vNNN`), bumped by hand after each round of changes. Check it against the latest commit here to confirm what's actually live.
