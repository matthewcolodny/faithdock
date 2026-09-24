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

Two scales, matching the two SVGs: `icon-512.png` at 80% for anywhere
the square is shown whole, and `icon-512-maskable.png` at 62% for
Android, which crops the icon to its launcher's shape and only
guarantees the middle 80% survives.

**512 matters specifically.** Chrome generates the Android launch
screen from the manifest — `background_color`, the largest icon, and
`name` — and wants a 512. Offered only a 192 it upscales, which showed
up as a visibly pixelated mark.

### The two launch screens
There are two, and only one is ours. Chrome draws its own launch screen
before a byte of the page runs and it cannot be turned off. The
in-page splash (`#fd-splash`, gated on `display-mode: standalone`)
takes over and covers the time it takes 2.5MB of HTML to become
usable — the gap Chrome's screen leaves behind.

So the in-page splash deliberately copies Chrome's layout: same navy,
mark above the name, both centred. They cannot be made pixel-identical
across devices, but matching the arrangement is what keeps the handoff
from reading as two different screens.

**A manifest change cannot reach an already-installed app.** Chrome
reads the manifest once, at install time. Testing any icon, colour or
name change means removing the app from the home screen and adding it
again.

## Build stamp
The footer of `index.html` carries a build version stamp (`build YYYY-MM-DD-vNNN`), bumped by hand after each round of changes. Check it against the latest commit here to confirm what's actually live.
