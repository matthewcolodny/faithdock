# FaithDock — Known Gotchas

Non-obvious things learned the hard way while working on this codebase. If you're picking this project up fresh — another Claude session, Claude Code, or a human — read this before touching auth, i18n, or the two-file deploy. Several of these took multiple wrong theories to actually diagnose; the goal here is to not repeat that.

---

## Deploy: two files, always together

`index.html` loads `pure-logic.js` via a relative `<script src="pure-logic.js">` tag. Both files must sit at the same root level on whatever's serving them.

This broke in production for real: manual zip uploads to Cloudflare Pages repeatedly included only `index.html`, so `pure-logic.js` 404'd — or fell through to SPA catch-all routing and came back as `index.html`'s content, which the browser correctly refused to execute as JavaScript (MIME type mismatch). `window.FaithDockPureLogic.computeWeekendRange()` — used by the "This weekend" events tab — would silently break with no visible error unless you specifically checked the console.

Now that Cloudflare Pages deploys from git, this specific failure mode should be closed — but if a "This weekend" bug ever shows up again, check that `pure-logic.js` is actually committed and present, first.

Also: Cloudflare Pages build config for this project should have **Build command** and **Build output directory** both **blank**. There's no build step — it's a plain static site with the real content sitting at the repo root.

---

## There are no `<form>` tags anywhere in this file

Every input is a bare `<input>` inside a `<div>`, submitted via a JS click handler, not real form submission. Zero `<form>` elements in the whole app.

Consequence: without `<form>` boundaries or explicit `autocomplete` attributes, browsers fall back to their own heuristics to guess which fields are "credential" fields — often based purely on DOM adjacency (a `type="password"` field sitting near a text/email field, no matter how it's actually used). Every password and email field now has an explicit `autocomplete` value (`current-password`, `new-password`, `email`, `name`, or `off`) specifically to stop browsers from guessing. **If you add a new password or email field anywhere, give it one too**, or this comes back.

---

## Hiding a wrapped password field needs more than `display:none`

`addPasswordToggles()` runs once at page load and wraps every `input[type="password"]` in a `.password-field-wrap` div, adding a `.password-toggle-btn` (eye icon) inside it, positioned `position:absolute; top:50%`.

If you ever need to hide one of these fields conditionally (e.g. the "Current password" field on Profile, hidden for Google-only accounts with no password set) — **setting `display:none` on the input alone is not enough.** The wrapping div has no explicit height, so it collapses to zero height when its only visible child disappears — but the toggle button is `position:absolute`, so it keeps rendering at `top:50%` of that now-empty box, which visually lands on whatever field comes next in the layout. This looked, for a while, like a browser extension or native browser autofill icon appearing on an unrelated field. It wasn't. It took inspecting the actual DOM element (not just theorizing about browser behavior) to find it.

**Use `setHiddenPasswordFieldVisible(inputEl, visible)`** (defined right after `addPasswordToggles()`) for any future show/hide toggle on a password field — it hides the wrapping div, not just the input, and also flips the input's own `type` attribute as a second layer of defense.

---

## JS can silently overwrite a correct translation

Several i18n bugs turned out to be: the static HTML had a perfectly correct `data-i18n="..."` attribute, but some JS function set that same element's `.textContent` with a **hardcoded English string** at runtime, after `applyTranslations()` had already run. Confirmed cases: the denomination dropdown label ("All selected" / "N selected"), the "N churches found" count, the pricing plan buttons, the account-type text ("Individual account" / "Church partner account"), the Church Home suffix, the password-label switching for Google-only accounts, and the delete-account warning message.

**`data-i18n` alone does not protect an element from being overwritten later.** Any JS that sets `.textContent` or `.innerHTML` on a translatable element needs to pull the string from `window.t('key')` at the exact point it's set — not rely on the one-time pass `applyTranslations()` does on load or language switch.

Rule of thumb: if a bug report is "this shows English even after switching to Spanish," check for a JS function setting that specific text dynamically before assuming the markup is missing `data-i18n`.

**Keep the two dictionaries in sync.** Both `translations.en` and `translations.es` should have exactly the same set of keys. Quick check:
```js
// paste into a node REPL after extracting the translations object
Object.keys(translations.en).sort().filter(k => !(k in translations.es))
Object.keys(translations.es).sort().filter(k => !(k in translations.en))
```
Both should return empty arrays. Run this after any batch of i18n edits.

---

## Post-login routing needs the actual intended destination, not a guess

`routeAfterLogin()` decides where to send someone right after they sign in. It used to compute a landing route purely from account type — platform admin → admin, owns/staffs a church → my-churches, brand-new OAuth signup → profile, else → home — with **zero memory of what page they were actually trying to reach** before getting bounced to the sign-up page.

Confirmed live, twice: someone hits `#profile` or `#dashboard` while signed out, gets redirected to sign-up, signs in, and lands somewhere else entirely — because `routeAfterLogin` never knew where they'd been headed in the first place.

Fix: `window.savePostLoginRoute(route)` / `window.consumePostLoginRoute()` use `sessionStorage`, not a plain JS variable — Google OAuth is a real full-page navigation away to accounts.google.com and back, so anything held only in memory is gone by the time the person returns. Call `savePostLoginRoute()` at the point of any "you're not signed in, redirecting to signup" guard; `routeAfterLogin()` checks for and prefers this over its own account-type guesswork.

This is **deliberately scoped to page-level redirects only** (Profile, Dashboard) — not to the many `showLoginRequired()` action-prompt modals (follow a church, join a group, register for an event, etc.), since those are action-based, not page-based, and resuming the underlying action after login is a separate, bigger feature nobody's built yet. Those modal buttons, and the plain nav "Log in"/"Sign up" links, explicitly call `window.clearStalePostLoginRoute()` — without that, an abandoned earlier attempt (got bounced toward Profile, gave up, came back later for something unrelated) could incorrectly resurface on a totally different sign-in.

---

## Multiple Turnstile widgets exist in the DOM simultaneously

This is an SPA — hidden page sections are never removed from the DOM, only toggled with CSS. That means the signup/login Turnstile widget and the two Profile-page widgets (email change, password change) can all be sitting in the DOM at once, even though only one is ever visible.

`turnstile.reset()` called with **no argument** is ambiguous once more than one widget exists. Every reset call in this codebase now targets a specific widget by ID: `turnstile.reset('#auth-turnstile')`, `turnstile.reset('#profile-email-turnstile')`, `turnstile.reset('#profile-password-turnstile')`. If you add a new Turnstile widget anywhere, give its container an explicit `id` and always reset it by that id.

---

## Plan naming has drifted before — check all four names

At one point the pricing page cards said "Medium"/"Large" while the button IDs, checkout logic (`startPlanCheckout('standard')`), and the dashboard billing section already said "Standard"/"Premium." If you're touching pricing or billing copy, grep for all four names (`Medium`, `Large`, `Standard`, `Premium`) to confirm nothing's drifted again — the rename doesn't always happen everywhere at once.

---

## Turnstile "flexible" sizing has a hard 300px floor — check your container width first

The auth card had only **216px of actual content width** (confirmed via DevTools box-model inspection: 36px padding + 1px border on each side of a narrow mobile card, on top of `.auth-wrap`'s own padding). Cloudflare Turnstile's `data-size="flexible"` mode enforces `min-width:300px` as a hard floor via inline style on the iframe itself. No external CSS can shrink it below that: `min-width` beats `max-width` when they conflict, and a plain (non-`!important`) inline style is still enough to win against a same-specificity external rule. Three separate attempts to fix this by overriding `overflow`, `padding`, and `max-width` on our own CSS all failed for this reason — none of them touched the actual constraint.

A fourth attempt switched to `data-size="compact"` (150px wide, 140px tall) since it's the only official size that fit inside 216px without a fight — but it looked visually wrong on the page (a small, oddly-tall, left-aligned box floating next to full-width fields) and was reverted.

**The actual fix: widen the real container instead of fighting Turnstile's requirement.** `.auth-wrap`'s own padding dropped from 28px to 16px, and `#auth-turnstile-wrap` breaks out of most (not all) of `.auth-card`'s 36px padding with a -28px negative margin — every other element in the card keeps its original spacing; only the Turnstile row uses most of the wrap's extra width, leaving 8px of breathing room so it doesn't sit flush against the card's own border. This pushes real content width comfortably past 300px on ordinary phone widths (~360px+), so `data-size="flexible"` now has the room it always needed, and renders at its native 65px height instead of compact's 140px. If this ever needs adjusting, re-measure actual content width in DevTools first — every pixel of breakout given back is a pixel closer to the original 216px-content-width bug.

If you're ever debugging a third-party embedded widget that won't respect a CSS override: check the element's actual inline style in DevTools before assuming your CSS specificity is the problem. `width`, `max-width`, and `min-width` can all be set independently by the same script, and only one of the three might actually be the binding constraint — overriding the wrong one (as happened here, twice) looks like it should work and does nothing. And before reaching for a smaller widget variant to fit a cramped container, check whether the container's own padding is actually necessary for *that specific element* — a targeted breakout can solve the real problem without changing the widget or degrading the rest of the layout.

The Profile page's two Turnstile widgets (`.side-note` cards, 22px padding) were left on `data-size="flexible"` without a breakout — their padding overhead is meaningfully less than the auth card's, so they were probably never affected by this. That's an inference from the CSS, though, not a confirmed DevTools measurement the way the auth card's number was — worth actually checking if they ever show the same problem.

---

## Working conventions worth restating

- **Bump the footer build stamp** (`build YYYY-MM-DD-vNNN`) after every round of changes — it's the fastest way to confirm whether what's live actually reflects the latest work, or whether a browser is just caching an old version.
- **Auth-related changes get live-tested with real console/DOM evidence before being trusted.** This file exists specifically because several bugs "looked safe on paper" — three separate wrong theories, in one case — before someone actually inspected the DOM or pasted a real console log and the true cause became obvious. Reasoning from the code alone was not enough for any of the bugs listed above.
- **New user-facing strings** need both English and Spanish dictionary entries plus a `data-i18n` attribute (or `data-i18n-placeholder` / `data-i18n-title` for non-text-content cases). Mixed-content elements — an icon next to text — need the text wrapped in its own `<span data-i18n="...">`, not left as loose text beside the icon.
- **Plan-gated features** follow one pattern: an inline locked/upsell panel in the UI, plus a matching server-side check at save time. Never just hide something in the UI and call it gated.
- **Theming:** `--brand` (fixed navy) for anything that must stay legible against gold; `--ink` (adaptive) for regular body text. Mixing these up is how buttons go invisible in dark mode.
