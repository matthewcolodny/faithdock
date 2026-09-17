# FaithDock — Known Gotchas

Non-obvious things learned the hard way while working on this codebase. If you're picking this project up fresh — another Claude session, Claude Code, or a human — read this before touching auth, i18n, or the two-file deploy. Several of these took multiple wrong theories to actually diagnose; the goal here is to not repeat that.

---

## The church-page map worked with a mouse but not with a finger

Reported plainly: "on mobile, I can't interact with the map like I can on desktop." The Location tab embedded Google Maps via a plain `<iframe src="google.com/maps/embed/v1/place?...">` — this is Google's own deliberate default behavior, not a bug in anything we wrote: an embedded map on a touch device requires **two fingers** to pan/zoom, precisely so a one-finger swipe (meant to scroll the page the map sits in) doesn't get hijacked by the map underneath it. A mouse drag on desktop has no such conflict, so it always looked fine there — the two-finger requirement is invisible until you're actually on a phone trying to swipe with one finger like any other map.

**Fix:** this page already loads the full Google Maps JavaScript API (`libraries=places`, used for address autocomplete elsewhere), so swap the iframe for a real `google.maps.Map` with `gestureHandling: 'greedy'` — the specific option that allows one-finger pan and pinch-zoom on touch, at the cost of the two-finger safety net (a map worth showing is worth letting people use). Falls back to the old iframe if `google.maps` genuinely isn't loaded yet (a fast direct link could beat the async script), retrying the real map shortly after.

**A second, separate bug hit while fixing the first:** `google.maps.Map` measures its container's size exactly once, at creation — and the Location tab panel is `display:none` by default (the church page always opens on "About"). A map created inside a hidden container renders broken/blank forever unless something explicitly fixes it. Confirmed and fixed by hooking into the existing `switchChurchTab()`: the moment the Location tab is actually selected, fire `google.maps.event.trigger(map, 'resize')` and re-set the center (a resize alone can silently recenter on 0,0). Verified live, not assumed: dispatched the real tab-switch, confirmed the `resize` event actually fired and the center landed back on the exact original coordinates.

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

**A related but distinct failure mode: a card that renders correctly once, then never re-renders at all.** Church/event cards (`churchCard()`, `eventCard()`) call `window.t()` correctly — the bug wasn't wrong text, it was that these cards are built once from a network fetch and the HTML is never touched again; a language toggle only ever re-ran cheap, isolated fixes (a count number) while the actual card grid sat untouched until the next real search. Confirmed as a real, live bug by an actual test, not just a suspicion: distance ("mi away"), "Next service", and a later-added "Next event" line all stayed in the old language until a manual refresh.

Fix pattern: cache the already-fetched rows (`window.directoryLastRenderedRows` and three siblings — home churches, events, home events), and on toggle, re-run them through `churchCard()`/`eventCard()` again in place — no network call, no pagination reset. For anything with its own randomization (`applyFeaturedRotation()` on the events grid), cache the *already-rotated* output, not the raw rows, or a toggle re-shuffles which "featured" events show first as an unrelated side effect nobody wanted.

**One layer deeper, and easy to miss even after applying that fix:** if what's cached is a *pre-formatted string* rather than the raw data, re-rendering the card only fixes the static label around it — the value baked into the string is still stuck in whatever language was active when it was formatted. Real example: caching `c.next = formatChurchServiceTimes(serviceTimes)` (a string with real day names inside it, e.g. "Sunday 9:00 AM") meant a toggle correctly flipped "Next service" → "Próximo servicio" while "Sunday" stayed English right next to it. The actual fix was caching the **raw** `service_times` array alongside the formatted string, and recomputing the formatted string fresh from that raw data on every toggle, not reusing the cached one. Worth checking for this exact shape — a formatter that calls `window.t()` internally, whose *output* (not inputs) gets cached — anywhere else a "just re-render from cache" fix gets applied.

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

## A CSS Grid track won't shrink below its content's natural width unless you tell it to

The whole dashboard was unusable on a real phone — reported as "the Upgrade plan button is too wide," but that was just the most visible symptom of the entire page being ~700px wide inside a 375px viewport. `.dash{grid-template-columns:220px 1fr}` already had a `@media (max-width:860px){.dash{grid-template-columns:1fr}}` collapse to a single column, and looked right in isolation — but a grid item's default `min-width` is `auto` (its content's own min-content width), not `0`. So even collapsed to one `1fr` track, that track grew to fit `.dash-main`'s widest descendant (an un-scrollable 8-column table, a toolbar with four buttons and no wrap, a 3-column stat row with no mobile breakpoint) instead of shrinking to the viewport — dragging the *entire* grid, sidebar included, along with it. Three separate, individually-correct-looking fixes (a stat-row breakpoint, `flex-wrap` on the toolbar, `overflow-x:auto` on the table) all did nothing until this was added:
```css
.dash-side, .dash-main{min-width:0;}
```
Confirmed via direct measurement, not assumption: `getComputedStyle(dash).gridTemplateColumns` reported `"703.797px"` for what should have been a single, viewport-width column — that's what made the actual mechanism visible, rather than just re-guessing at more child-level fixes that would have kept failing the same way.

**The lesson:** if a flex or grid container is supposed to shrink on mobile and visibly isn't — despite the responsive rule for the container itself looking correct — check `min-width`/`min-height` on the *items*, not just the container's own track sizing. This class of bug reads exactly like "my breakpoint isn't being applied" when the breakpoint is actually working fine; it's the track size computation that's ignoring it.

**A separate, smaller trap hit while fixing this:** a media-query override for one specific property (`overflow-x:auto`) written *before* an unconditional base rule that sets the shorthand (`overflow:hidden`, which sets both x and y) silently loses — `@media` doesn't add specificity, so two equal-specificity rules resolve by source order, and the later, unconditional one won. Moving the conditional rule after the shorthand fixed it.

---

## Turnstile "flexible" sizing has a hard 300px floor — check your container width first

The auth card had only **216px of actual content width** (confirmed via DevTools box-model inspection: 36px padding + 1px border on each side of a narrow mobile card, on top of `.auth-wrap`'s own padding). Cloudflare Turnstile's `data-size="flexible"` mode enforces `min-width:300px` as a hard floor via inline style on the iframe itself. No external CSS can shrink it below that: `min-width` beats `max-width` when they conflict, and a plain (non-`!important`) inline style is still enough to win against a same-specificity external rule. Three separate attempts to fix this by overriding `overflow`, `padding`, and `max-width` on our own CSS all failed for this reason — none of them touched the actual constraint.

A fourth attempt switched to `data-size="compact"` (150px wide, 140px tall) since it's the only official size that fit inside 216px without a fight — but it looked visually wrong on the page (a small, oddly-tall, left-aligned box floating next to full-width fields) and was reverted.

**The actual fix: widen the real container instead of fighting Turnstile's requirement.** `.auth-wrap`'s own padding dropped from 28px to 16px, and `#auth-turnstile-wrap` breaks out of most (not all) of `.auth-card`'s 36px padding with a -28px negative margin — every other element in the card keeps its original spacing; only the Turnstile row uses most of the wrap's extra width, leaving 8px of breathing room so it doesn't sit flush against the card's own border. This pushes real content width comfortably past 300px on ordinary phone widths (~360px+), so `data-size="flexible"` now has the room it always needed, and renders at its native 65px height instead of compact's 140px. If this ever needs adjusting, re-measure actual content width in DevTools first — every pixel of breakout given back is a pixel closer to the original 216px-content-width bug.

If you're ever debugging a third-party embedded widget that won't respect a CSS override: check the element's actual inline style in DevTools before assuming your CSS specificity is the problem. `width`, `max-width`, and `min-width` can all be set independently by the same script, and only one of the three might actually be the binding constraint — overriding the wrong one (as happened here, twice) looks like it should work and does nothing. And before reaching for a smaller widget variant to fit a cramped container, check whether the container's own padding is actually necessary for *that specific element* — a targeted breakout can solve the real problem without changing the widget or degrading the rest of the layout.

The Profile page's two Turnstile widgets (`.side-note` cards, 22px padding) were left on `data-size="flexible"` without a breakout — their padding overhead is meaningfully less than the auth card's, so they were probably never affected by this. That's an inference from the CSS, though, not a confirmed DevTools measurement the way the auth card's number was — worth actually checking if they ever show the same problem.

---

## Password recovery: the classic-script router runs before Supabase's client even exists — don't let it touch an auth hash

Clicking the emailed "reset password" link landed on the hero page instead of "Set new password" — confirmed as a real, live bug **twice**, the second time by an actual production round-trip (real Gmail, real click, DevTools showing the exact final URL: a bare `https://faithdock.com/#home`, every token gone).

**First attempt (wrong — left as a lesson, not deleted, because the wrong theory looked completely reasonable and cost real time before the second bug report exposed it):** listening for the `PASSWORD_RECOVERY` event on `supabase.auth.onAuthStateChange`, reasoning that the original `location.hash.indexOf('type=recovery')` check was racing Supabase's own async `detectSessionInUrl` handling. That diagnosis was based on real evidence (reading the actual `auth-js` bundle, a synthetic-hash browser test) and the fix was real and worth keeping — but it was solving a downstream symptom, not the actual root cause, which sat in a completely different script.

**Actual root cause:** `showRouteFromHash()` — a *classic* (non-module) script that runs at initial page load, well before the deferred `type="module"` script where `createClient()` and the listener above even exist — has its own explicit, deliberate guard against touching an OAuth-shaped `#access_token=...` hash, specifically because doing so (even just defaulting to 'home' and calling `replaceState`) destroys the token before Supabase's client ever gets a chance to read it. That guard already special-cased `type=recovery` to exclude it from the OAuth-*stall-timer* logic (a 4-second "still not signed in, something failed" safety net that would otherwise wrongly fire mid-reset) — but excluding it from the condition also, accidentally, excluded it from the early `return` right below that guard. A recovery hash fell straight through to `resolveRouteFromHash()` a few lines down, which doesn't recognize it as any real route, defaults to `'home'`, and `go('home', ...)` rewrites the URL hash to a bare `#home` — wiping the recovery token in the *classic* script, long before the *module* script's `PASSWORD_RECOVERY` listener from the first attempt ever ran. That listener was completely correct; it just never had anything left to catch.

**Fix:** restructure so *both* OAuth and recovery hashes hit the same early `return` (hash left completely untouched), and only the OAuth-specific stall-timer logic is conditional on `type=recovery` being absent — instead of the exclusion also, incorrectly, gating the `return` itself.

**The actual lesson:** when a bug spans a hash the app doesn't fully control (an external redirect, in this case) and multiple scripts touch `location.hash` at different points in the page's lifecycle, check *every* place that reads or writes it, in *execution order*, before trusting a fix that only addresses the last one you looked at. The first fix here was validated with real console evidence and still turned out to be one script too late.

If you ever need to verify an `onAuthStateChange`-driven flow without a real email round-trip, `supabase.auth._notifyAllSubscribers('EVENT_NAME', fakeSession)` dispatches a real event through the SDK's own listener list — closer to true end-to-end evidence than manually calling your own handler function directly. It's still not a substitute for an actual round-trip, though, precisely because it starts downstream of exactly this kind of bug.

**Third attempt (the actual, final root cause — found via real Supabase Auth Logs, not more code review):** after the routing fix above, the reset link correctly landed on "Choose a new password" — but submitting it failed with Supabase's own `AuthSessionMissingError` ("Auth session missing!"). The Auth Logs showed exactly one `/auth/v1/verify` request, from a real browser user-agent, with a clean `303` response — ruling out a burned/pre-scanned token (the first suspicion) entirely. The actual cause: `resetPasswordForEmail()`'s `redirectTo` was `https://faithdock.com/#reset-password` — our own app deciding where the reset page lives. Supabase's server redirects the browser to `redirectTo` **with its own hash fragment of real tokens appended** (`#access_token=...&type=recovery&...`). Since `redirectTo` already ends in a `#`-fragment, the two concatenate into a single browser-level hash: `#reset-password#access_token=...`. A second `#` inside a fragment has no special meaning to a browser — confirmed directly in a console, not assumed: `new URLSearchParams('reset-password#access_token=X&type=recovery').get('access_token')` returns `null`; the actual parsed key is `"reset-password#access_token"`. `type` still parses correctly (it's untouched, at the end of the string) — which is exactly why routing kept working while the session never got established. Supabase's own client hits this identical parsing failure internally, so it silently never extracts a real session from the URL at all.

**Fix:** `resetPasswordForEmail`'s `redirectTo` is now the bare origin (`window.location.origin + window.location.pathname`, no hash). Supabase's appended fragment is then the *only* hash in the URL, so it parses cleanly on both sides — this app's own `type=recovery` detection (an `indexOf` substring check, unaffected either way) and Supabase's own `access_token` extraction (which was the one actually broken). **Never put a hash fragment in a Supabase `redirectTo` value that Supabase itself will also append tokens to** — email confirmation and OAuth redirects that rely on the same mechanism are worth double-checking for the same pattern if this ever resurfaces elsewhere.

The general lesson standing after all three attempts: a single reported symptom ("lands on the wrong page") can have multiple independent bugs stacked behind it, each only visible once the previous one is fixed. Real evidence at each step — a browser test, then Auth Logs, then a console-verified `URLSearchParams` call — is what actually separated them; reasoning from any single vantage point (the code, the docs, or a synthetic test that skips the real URL/redirect chain) missed at least one layer every time.

---

## One sign-in fans out into a dozen-plus duplicate queries — `getMyChurch()` had no cache

Real Supabase Auth Logs from a normal dashboard session (captured while chasing the password-reset bug above) showed the same `auth/v1/user`, `churches`, and `church_staff` requests firing many times back-to-back within the same second, for one real, otherwise-normal login. Not a symptom of the auth listener firing repeatedly — the 400ms `authRefreshTimer` debounce already collapses a burst of `onAuthStateChange` events into a single run. The actual cause: that single debounced run unconditionally calls ~14 independent panel loaders (dashboard header, events, groups, team, directory, giving, billing, check-in, admin, my-groups, my-churches, event-filter follow state, my-events, pending invites) every time, regardless of which page is actually visible, and nearly all of them call `getMyChurch()` themselves — which had zero caching across its 66 call sites. One login was quietly issuing a dozen-plus fully redundant round trips to the same two tables.

**Fix:** `getMyChurch()` now caches its own in-flight *promise* (not just the resolved value) for 1.5 seconds, keyed by user id. Concurrent calls within that window all share the one real network request; anything even a few seconds later — a manual nav click, or a refresh right after editing a church — still gets a fully fresh query. The retry-on-not-yet-visible-staff-row logic (a separate, pre-existing mechanism) is untouched: it lives in a new `getMyChurchUncached()` that the cached wrapper calls into, so retries still happen per-attempt, just once per *batch* instead of once per *caller*.

Verified in the console (not against a real backend — a fake user id triggers the existing invalid-UUID retry path, which is itself a useful counter): 5 concurrent `getMyChurch()` calls produced exactly one shared execution's worth of underlying queries, not 5x that; a call issued after the 1.5s window produced a distinctly fresh new one.

**The lesson:** a debounce that collapses *when* something runs doesn't do anything about *how much* work that one run fans out into. Any function called from many independent, unconditionally-firing loaders in the same tick is worth checking for exactly this — it's invisible from the UI (everything "just works") and only shows up as request volume in server-side logs.

**Follow-up, found by re-testing the fix above against real Auth Logs from an actual OAuth login:** the getMyChurch() dedup only collapses calls *within* one refresh batch — it does nothing if *multiple full batches* run. And they were: `onAuthStateChange`'s `clearTimeout(authRefreshTimer); authRefreshTimer = setTimeout(...)` re-arms for **every** event Supabase emits — `TOKEN_REFRESHED`, `INITIAL_SESSION`, `USER_UPDATED`, not just `SIGNED_IN`/`SIGNED_OUT` — and a single OAuth login routinely fires more than one of these within a few seconds (confirmed: admin-panel-only RPCs, which don't touch `getMyChurch()` at all, showed up exactly twice in that same log). Each firing is individually legitimate; none of them actually changed who's signed in, so none of them needed the expensive batch to run again.

**Fix:** track `window._lastAuthRefreshUserId` and skip the entire batch when the resolved `uid` matches it — a real sign-in/sign-out always differs from whatever ran last (including the very first run ever, since the tracker starts `undefined`), so those still always refresh; a same-user echo event doesn't. Verified live: stubbed `supabase.auth.getUser()` to bypass the unrelated stale-session guard, then fired `INITIAL_SESSION(user-A)` → `TOKEN_REFRESHED(user-A)` → `SIGNED_IN(user-B)` via `_notifyAllSubscribers` — the batch ran for the first and third, and only the middle one (same identity, no real change) logged "skipping refresh batch."

**Remaining known duplication, accepted as-is:** a real OAuth login for a platform admin still shows admin-only queries (`search_all_churches_admin` etc.) exactly **twice**, confirmed via matching real Auth Logs against the console's `[FaithDock auth]` trace. Root cause, fully understood, not a bug in the fix above: `SIGNED_IN`'s handler does `await checkIsFirstEverSignIn(...)` (a real network round trip) before it ever reaches the refresh-batch code, while `INITIAL_SESSION`'s handler has no such wait — so `INITIAL_SESSION`'s batch fires and completes *first* (a real, once-through load), and `SIGNED_IN`'s own attempt correctly gets caught by the identity check above and skipped. The second admin-query wave comes from `routeAfterLogin` separately navigating an admin straight to `/admin`, which loads that page's data as completely normal SPA routing — independent of, and unaware of, the auth-batch that just loaded the same panel a moment earlier under the "whichever page they land on next already has fresh data" design. Fully collapsing this would mean making the auth-refresh batch route-aware (only load panels for the page actually visible) — a real trade-off against that existing "any page is instantly ready" design, not a clear bug — so left alone deliberately. Confirmed harmless either way: every request here is read-only and returns 200, and `dashboardRefreshGeneration` already prevents any of this from ever applying stale data over fresh. Revisit only if it starts actually costing something measurable (Supabase usage limits, noticeable login latency).

---

## Two tables the client already queries aren't set up right in Supabase — client code can't fix this

Same Auth Log session surfaced two more errors, both from features (member invites, ownership handoff) that are fully built client-side but apparently never finished on the Supabase side:

- **`church_member_invites` → 404.** PostgREST returns 404 when it doesn't see a table in its exposed schema at all — not a client-side typo (grepped: used consistently across 8 call sites), and not a naming drift either (confirmed against the actual table list: `church_staff_invites` exists, but that's a *different* feature — staff invites, paired with the `send-staff-invite` edge function — not this one). `church_member_invites` was simply never created. Fires on *every single sign-in* via `checkPendingMemberInvite()`, not just when someone actually uses the invite feature. Fix is a real `create table` + RLS policies (worked out from the client's own query shapes — see the table's insert/select/update/upsert call sites for the exact columns needed).

- **`church_ownership_handoffs` → 403, and the standalone `permission denied for table users` — same root cause, confirmed via `pg_policies`.** First guess (a non-`SECURITY DEFINER` `get_user_id_by_email` RPC) was wrong — checked Database → Functions directly and it's already `Definer`. The actual cause was sitting in the RLS policy text itself:
  ```
  "Recipient can view handoffs addressed to their email" (SELECT):
    lower(to_email) = lower((SELECT users.email FROM auth.users WHERE users.id = auth.uid())::text)
  ```
  This policy queries `auth.users` directly from inside RLS, and the `authenticated` role has no grant on that table — so evaluating it throws `permission denied for table users`. Critically, **Postgres RLS doesn't isolate one broken policy from the others**: when multiple SELECT policies apply (here, this one *and* the otherwise-correct `EXISTS (... c.owner_id = auth.uid())` owner policy, OR'd together), an error thrown while evaluating *any* of them aborts the entire query — it doesn't just count as "false" and fall through to the next. That's why even the *owner*, who should have cleanly passed the other policy, got a blanket 403: the query never survived long enough to reach it. Fix: replace the `auth.users` subquery with the JWT claim, which needs no special grant:
  ```sql
  create policy "Recipient can view handoffs addressed to their email"
  on church_ownership_handoffs for select
  using (lower(to_email) = lower(auth.jwt() ->> 'email'));
  ```
  Worth a one-time sweep for the same mistake anywhere else: `select tablename, policyname, cmd, qual, with_check from pg_policies where qual ilike '%auth.users%' or with_check ilike '%auth.users%';`

- **A third instance of the same underlying pattern:** the Households panel failed with `Could not find a relationship between 'household_members' and 'profiles' in the schema cache`. `household_members.user_id` had a real foreign key — just pointing at `auth.users(id)`, not `public.profiles(id)`. PostgREST can only auto-resolve an embedded join (`household_members(...profiles(full_name))`) through a direct FK between the two exact tables named in the query; a transitive relationship (`profiles.id` mirrors `auth.users.id` for every real user, but that's not a FK PostgREST can see) doesn't count. Fix: add a second FK on the same column pointing at `profiles` instead — safe to have both, since the values always agree — then `notify pgrst, 'reload schema';` so PostgREST picks it up immediately instead of waiting for its own periodic refresh:
  ```sql
  alter table household_members
    add constraint household_members_user_id_profiles_fkey
    foreign key (user_id) references profiles(id) on delete cascade;
  notify pgrst, 'reload schema';
  ```

**None of this is fixable from this repo** — there's no backend/migration code here (per the project's own single-file-static-site constraint), so both fixes are entirely in the Supabase dashboard/SQL Editor. The general lesson: a client-side feature shipping cleanly (no console errors during development, matching table/column names in the code) gives no signal at all that the database side — the table existing, RLS actually matching, a policy not silently referencing a table it has no grant on — is actually finished. Check Auth Logs against real usage, not just the browser console, before calling a table-backed feature done.

---

## `checkExistingChurch()` only runs at page-load/auth-change — a plain SPA click doesn't re-trigger it

Clicking "Edit church profile →" (from the dashboard sidebar or settings) intermittently opened a *blank* "create new church" form instead of an edit form — for the actual owner of a real church, not a permissions edge case. Refreshing the page immediately fixed it. That "fixed by refresh" symptom is the tell: `checkExistingChurch()`, which populates that form, only ever runs from three one-time guards (page load, auth-state-change) — never from the shared `[data-route]` click handler that this link, like every other in-app link, actually goes through. So clicking it just reveals whatever the form happened to still be showing from the last time one of those guards ran, which can easily be stale (blank, if page-load's own run hadn't caught up to a specific church yet) by the time someone actually clicks it a moment later.

This exact gap was already identified once, during the multi-church ownership work — but only patched for "Add a church" (`data-add-church`), which got its own inline `checkExistingChurch(undefined, 'new')` call right before `go()` reveals the page, matching how `church`/`event`/`group` links already populate their target page inline. The plain "Edit church profile" link never got the equivalent treatment, on the apparent assumption that page-load's own run would already have it covered by the time anyone could click it — which is exactly the assumption that doesn't hold up under a real, fast click right after signing in.

**Fix:** the same inline-populate treatment, the other direction — call `checkExistingChurch(undefined, undefined)` right before `go()` for any `register-church` click that *isn't* `data-add-church`. Verified live: spied on `checkExistingChurch` and dispatched real clicks — the edit link now calls it with no routeKey (the "resolve my existing church" path), while "Add a church" still calls it with `'new'`, exactly as before.

**The lesson:** a fix scoped to "the one case that was reported" (`data-add-church` here) is worth double-checking for siblings sharing the same root cause (every other `register-church` link) before calling the gap closed — the multi-church plan's own exploration notes had already spelled out the general mechanism, just not followed all the way through to every affected link.

---

## Password fields need to be cleared on every page visit, not just after a successful save

The Profile password-change fields (`autocomplete="current-password"`/`"new-password"`, per the convention above) still showed old values after refreshing, signing out, and signing back in — confirmed as a real, reported bug, not just a theoretical autofill concern. The `autocomplete` attribute stops the browser from *guessing* which field is which; it doesn't stop the browser's own password manager from *repopulating* a field it remembers, on a later, completely unrelated visit to that same page.

Clearing these fields once, right after a successful password update, isn't enough — the browser can refill them again the next time the page loads, well after this app's own JS has finished running. `loadProfilePage()` now explicitly blanks all three password inputs at the start of every call, and again on the next tick and ~300ms later (`setTimeout(..., 0)` and `setTimeout(..., 300)`) — covering both an autofill pass that lands before this function's own synchronous work, and one that lands after it. The login form's email/password fields are also explicitly cleared on `SIGNED_OUT`, for the same reason.

---

## Event capacity was only ever checked client-side — and the check itself was reading the wrong rows

QA report: "the site currently allows users to register beyond capacity," plus a related one — a second visitor viewing an event already filled to its 1-participant cap saw the count as "0/1" instead of "1/1."

Both trace back to the same two things:

1. **No enforcement lived in the database.** The only capacity check was a `SELECT count(...)` in `completeEventRegistration()`, run in JS *before* the insert — the code's own comment already admitted it was "best-effort... not race-proof." Worse than the comment let on: since it was never backed by anything at the database layer, it wasn't a race-condition edge case, it was the *entire* enforcement, and it could be skipped by anyone calling the database directly, not just by two people clicking at the same instant.

2. **That same check (and the display code on the event detail page, `checkEventCapacity()`) queried `event_registrations` directly as the viewing user.** If RLS on that table restricts `select` to a user's own rows (the normal, privacy-correct default for a table holding who signed up for what), then a visitor who hasn't registered yet always gets back *zero rows* for the whole event, no matter how full it actually is — the pre-check always read "0 confirmed," so it never blocked anything, and the on-page count always showed 0 to anyone but the registrants themselves.

**Fix, in two parts:**

- A `before insert or update` trigger on `event_registrations` (`enforce_event_capacity()`) that locks the event row (`for update`) and rejects any write that would push a role's confirmed count past `max_participants`/`max_volunteers`. This is the real fix — atomic, and it applies to *every* writer, including whatever inserts the confirmation row after a successful Stripe payment (that edge function's source isn't in this repo, so this was the only way to close that path too). It signals the specific case with a fixed `EVENT_CAPACITY_FULL` message so the client can show its normal localized copy instead of a raw Postgres error.
- A `SECURITY DEFINER` RPC, `get_event_registration_counts(p_event_id)`, returning just the aggregate participant/volunteer counts — not the underlying rows — and both `checkEventCapacity()` and the pre-check in `completeEventRegistration()` now call it instead of selecting the table directly. This fixes the counts for every viewer without having to widen RLS to let everyone read everyone else's registration rows.

**One accepted gap, not fixed here:** the trigger also protects the paid-checkout path, but if it ever actually rejects a payment's confirmation insert (only possible if the event fills in the seconds between starting checkout and payment completing), that customer would have been charged with no seat reserved — the edge function that would need a refund-on-rejection path for that isn't in this repo.

---

## A translated suggestion chip stopped being translated the moment you clicked it

QA report: "the tags, +volunteer, +book club, etc. are not translating on event creation page." The suggestion chips themselves (`+ Volunteer`, `+ Book Club`, ...) already translated correctly — `loadChurchTagSuggestions()` looks up each of the 7 baseline tags through `baselineTagI18nKeyMap` and `window.t()` before rendering, and is wired into the language-toggle dispatcher. The gap was one step later: clicking a suggestion adds its canonical English value (`"Volunteer"`) to the `ceTags` array — deliberately English, so the same tag doesn't fragment into a different stored value depending on which language it was clicked in — but `renderCeTags()`, which draws the "already added" chip list, printed that stored value straight to the page with no `window.t()` lookup at all. So the moment a suggested tag was actually selected, it locked into English regardless of the active language, and toggling afterward did nothing because `renderCeTags()` wasn't even in the toggle dispatcher's `create-event` block to begin with.

**Fix:** `renderCeTags()` now runs the same tag through `baselineTagI18nKeyMap`/`window.t()` that the suggestion chip itself uses (falling back to the raw value for a church's own freeform tags, which were never meant to be translated), and is added to the `create-event` toggle dispatcher alongside `renderCeContacts`/`renderCeQuestions`/`loadChurchTagSuggestions`. `baselineTagI18nKeyMap` itself is exposed on `window` since the two functions using it aren't declared in the same lexical scope.

**Not live-verified**: the create-event page requires a logged-in church account, and this session had no test credentials to sign in with — confirmed only via careful code reading and a syntax check, not by actually clicking through it like the other fixes above. Worth a real click-through (add a suggested tag, toggle language, confirm the chip re-translates) next time someone's signed in.

---

## The Events table's registration count dropped its own label the moment a max was set

QA report: "the volunteer count should read '#/# Volunteers'." `formatRegCell(count, max, label)` on the Dashboard → Events table had two branches — no max set: `"3 volunteers"` (label included); max set: `"3/10"` (label silently dropped, no matter which of participants/volunteers/registrations the number was actually counting). The max-set branch was the common case for any church actually using capacity limits, so the cell read as a bare, context-free fraction most of the time it mattered.

**Fix:** `formatRegCell` now always includes a label in both branches (singular for a count of exactly 1 in the no-max case, plural otherwise — matching `"#/# Volunteers"` for the max case). This table had never been localized at all before, so the labels are now real `window.t()` calls (`events.roleParticipant`/`events.roleVolunteer` for singular, reusing them; new `dashEvents.participantsPlural`/`volunteersPlural`/`registrationSingular` keys, `dashEvents.registrations` reused for the plural "registration" case) rather than the hardcoded English strings it used before — which also meant adding `loadDashboardEvents()` to the language-toggle dispatcher's `dashboard` block, since this cell's text is now dynamic and would otherwise get stuck in whichever language was active when the table first loaded.

**Not live-verified** — same reason as the tag-chip fix above: this table lives behind a church-owner login and this session had no test credentials.

---

## The Events table only ever showed registration counts from whenever the dashboard first loaded

QA report: "requires a refresh to update the number of participants, can that update automatically?" `loadDashboardEvents()` only ran once when the dashboard's Events tab first rendered (plus a handful of specific after-I-just-changed-something call sites elsewhere in the file) — someone registering for an event from a different device or tab never showed up on the church owner's screen until they manually reloaded the page.

There's no realtime plumbing anywhere in this app — no Supabase Realtime subscriptions at all (confirmed: nothing in the codebase calls `.channel(...)` or subscribes to `postgres_changes`) — so wiring up genuine push updates would mean setting up Realtime replication on `event_registrations` from scratch, sight unseen, for one dashboard table. Given that, the pragmatic fix here is a quiet poll instead of new infrastructure:

- Switching *to* the Events tab (`goDash('events')`) now refreshes immediately, covering "I switched to another tab and back."
- A `setInterval` re-runs `loadDashboardEvents()` every 20 seconds, but only while the browser tab is actually visible (`document.visibilityState`) **and** the current route is `dashboard` **and** the Events panel specifically is the active one — `.dash-content` panels stay in the DOM permanently and keep whatever `active` class they last had even after navigating away entirely, so checking the panel's class alone would have kept this quietly polling in the background for anyone signed in and browsing the public site.

**Not live-verified** — same reason as the two fixes above.

---

## Splitting participant and volunteer registration questions into two real lists

QA request: "the questions for participants should be separate from questions for volunteers - make sure there's 2 sets of questions." Before this, `event_questions` had no concept of audience at all — every question showed to everyone who registered, participant or volunteer, with no way to ask a volunteer-only question ("what shift can you cover?") without also showing it to every participant.

**Requires a one-time SQL migration** (nothing here touches the database directly):
```sql
alter table event_questions
  add column applies_to text not null default 'both'
  check (applies_to in ('both', 'participant', 'volunteer'));
```
`'both'` is the default so every question that already exists keeps behaving exactly as it always did — shown to everyone — until the event it belongs to is actually saved again through the (now-split) create-event form.

**Design decision, not a per-question toggle:** two genuinely separate lists in the create-event form — the existing question list (now labeled "Questions for participants" once volunteer signups are turned on, "Registration questions" when they're not — same list either way) plus a new one inside the volunteer-signup section, only visible when "Also accept volunteer signups" is checked. Matches what was literally asked for ("2 sets of questions") more directly than a per-question audience dropdown would have, and reuses the exact same render/wire code for both lists (`questionsListHtml()` + `wireQuestionsList()`, parameterized) rather than duplicating ~60 lines of chip-builder logic twice.

**The subtle part was not breaking existing answers on save.** A question can't be blind deleted-and-reinserted on every save — if anyone already registered and answered it, their answer references that row's id via a foreign key, and deleting it destroys real collected data (an allergy, a childcare need) the instant an organizer edits anything else about the event. The existing "match by question text, preserve the id" logic (`saveEventQuestions()`) already handled this for one list; extending it to two required deciding what an old `'both'` row matches against — it's matched into the **participant** group specifically (never volunteer, since nothing was ever volunteer-scoped before this existed), which is what lets a legacy question's id and answers survive the first time its event is saved through the split form. After that first resave it's tagged `'participant'` explicitly, same as everything created directly in that list.

**One deliberate, worth-knowing behavior change:** until an event's questions are resaved this way, its old shared questions keep showing to volunteers too (registration reads `applies_to === 'both' OR applies_to === role`). The first time that event's questions are saved again, though, sharing stops being implicit — a `'both'` row becomes `'participant'`-only, and if volunteers should still see it, it now needs to be added to the volunteer list explicitly. That's the intended, honest consequence of "2 real sets of questions" rather than a bug, but it's not obvious from the UI alone, so it's worth mentioning to whoever's using this: resaving an existing volunteer-accepting event's questions, without touching the new volunteer list, will silently stop showing those questions to volunteers going forward.

**Not live-verified** — same reason as the fixes above (no test credentials this session); this one in particular is worth a real click-through given how much of it depends on the save-time id-preservation logic actually behaving as designed.

---

## Adding guest counts: a per-registrant number, not a role

QA request: an "Are guests allowed?" checkbox on event creation; if checked, whoever registers is asked how many guests they're bringing, tracked separately from the participant/volunteer count, with an organizer-set cap on the total.

**Requires a one-time SQL migration:**
```sql
alter table events add column allow_guests boolean not null default false;
alter table events add column max_guests int;
alter table event_registrations add column guest_count int not null default 0 check (guest_count >= 0);

create or replace function enforce_event_capacity()
returns trigger as $$
declare
  v_max int;
  v_current int;
  v_max_guests int;
  v_current_guests int;
begin
  if new.status <> 'confirmed' then
    return new;
  end if;

  select
    case when new.role = 'volunteer' then max_volunteers else max_participants end,
    max_guests
  into v_max, v_max_guests
  from events where id = new.event_id;

  perform 1 from events where id = new.event_id for update;

  if v_max is not null then
    select count(*) into v_current
    from event_registrations
    where event_id = new.event_id and role = new.role and status = 'confirmed'
      and id is distinct from new.id;
    if v_current >= v_max then
      raise exception 'EVENT_CAPACITY_FULL';
    end if;
  end if;

  if v_max_guests is not null then
    select coalesce(sum(guest_count), 0) into v_current_guests
    from event_registrations
    where event_id = new.event_id and status = 'confirmed'
      and id is distinct from new.id;
    if v_current_guests + coalesce(new.guest_count, 0) > v_max_guests then
      raise exception 'EVENT_GUESTS_FULL';
    end if;
  end if;

  return new;
end;
$$ language plpgsql;
```
This extends the same `enforce_event_capacity()` trigger from the earlier capacity fix — same function name and signature, so `create or replace` takes effect on the existing trigger binding immediately, no need to re-create the trigger itself. Also dropped that trigger's earlier same-role-and-already-confirmed early-exit: it was a minor optimization, not a correctness requirement (the count query already excludes the row being written via `id is distinct from new.id`), and keeping a single unconditional path made it obviously correct for guest_count changes too, rather than having to reason about whether the old skip condition covered them.

**Where the guest count is asked, and why there.** Rather than a separate step, the guest-count input was added into the existing registration-questions modal (the same "collect more info before confirming" surface already used for custom questions and the paid-checkout discount-code field) — registering now opens that modal whenever the event allows guests, even if it has no custom questions and isn't paid, since there needs to be *somewhere* to ask.

**`allow_guests`/`max_guests` aren't in the `search_events` RPC's return shape** — same constraint noted elsewhere in this file: that RPC's SQL isn't in this repo, so it can't be extended from here. Rather than thread two more fields through every place an event gets shown, the register-click handler does one small direct `events` table lookup for just `allow_guests` at the moment someone actually clicks Register, which is the only place this was actually needed.

**One real gap, not fixed here:** the guest count is threaded through to the paid-checkout edge function's request body (`stripe-event-checkout`) on a best-effort basis, but whether it actually lands on the registration row depends on that function accepting and forwarding the field — its source isn't in this repo to confirm or fix.

**Not live-verified** — no test credentials this session, same as the other fixes above.

---

## A two-line badge wrapped left-aligned, not centered

QA report, with a screenshot: "Open to anyone" on a narrow card wrapped onto two lines, ragged-left instead of centered. The shared `.tag` class (used for every badge/pill in the app — category tags, "Registration open," denomination, etc.) never set `text-align`, so it inherited the page's default left alignment; invisible on a single line, obvious the moment text wraps on a narrow card. Added `text-align:center` to `.tag` itself rather than a one-off fix on this specific badge, since every other tag using this class was one long word away from the same thing. Verified live against the exact page from the screenshot (mobile viewport, same church).

---

## Suggested donations for free events: reusing Give, not rebuilding it

QA request: "for free events, add giving option so churches can suggest a donation amount to attend event." Rather than a separate donation flow, this reuses the church's existing Give tab/Stripe Checkout wholesale — an organizer sets an optional suggested amount on a free event (mutually exclusive with a ticket price by design: setting a price clears it on save, since a paid event already has its own direct charge), and a registrant sees a "This is a free event — a suggested donation of $X helps support {church}" prompt with a Give button.

**Requires a one-time SQL migration:**
```sql
alter table events add column suggested_donation_cents integer
  check (suggested_donation_cents is null or suggested_donation_cents > 0);
```

**The button had to cross a real architectural gap to get there.** The event detail page and a church's Give tab are different pages/routes, and — confirmed by reading the routing code directly, not assumed — **this app has no `hashchange` listener anywhere**. Every real navigation site calls `go()` (which only swaps page visibility and pushes history) and then separately, explicitly, re-resolves and populates from the hash right where the click happens; there's no central router reacting to hash changes on its own. A first attempt at this button that only called `go('church/...')` looked like it navigated correctly (URL updated, right page section became active) but silently left the church's own data — including whether Give is even enabled for it — completely unpopulated, because that population step never got triggered. Caught by scripting the actual click through a real browser and inspecting the resulting DOM state, not by reading the code and assuming it would work. Fixed by also calling `window.showRouteFromHash(true)` right after `go()` — the same "re-populate from whatever the hash currently says" catch-all this file already uses in four other places (e.g. right after sign-in) — rather than duplicating the church-lookup/populate logic inline.

**Getting the prefilled amount into a tab that doesn't exist yet on the current page** works by stashing `window.pendingGiveAmountCents`/`pendingGiveChurchId` before navigating, then having `checkChurchGivingEnabled()` — which every church-page load already calls, and which already knows whether Give is actually enabled — check for and resume that pending intent once the panel it needs actually exists and is populated, clearing it either way so a stale amount can't leak into some later, unrelated visit to that church's Give tab.

**Verified live**, including the routing gap above and the full happy path (donation prompt renders with the right text and amount, clicking through lands on Give with the amount prefilled) — via a real running preview and scripted browser interaction, with the two Stripe-dependent lookups (an event's suggested amount, a church's onboarding status) stubbed at the network boundary rather than the whole thing merely reasoned about.

---

## New pricing model: a FaithDock fee on Free tier, pass/absorb choice, donor fee-covering

Product decision (not a bug fix): Free-tier churches can now create **paid** events — previously blocked outright — monetized instead by a FaithDock service fee; Starter and above pay no FaithDock fee, on either giving or tickets. Landed in stages this session; here's the full current state in one place.

**The numbers, as decided:**
- **Giving, Free tier only:** 1% FaithDock fee. Paid tiers: 0%.
- **Paid event tickets, Free tier only:** 3% per ticket (flat percentage — no fixed cents component; this replaced an earlier Eventbrite-mirroring "3.7% + $1.79" design). Paid tiers: 0%.
- **Stripe's own real card-processing cost** (roughly 2.9% + $0.30, varies by card) is separate from both of the above, charged on every tier regardless of plan, and is not something FaithDock controls or can waive — it comes out of the connected church's own Stripe account on every transaction, same as before any of this existed.

**Requires a one-time SQL migration:**
```sql
alter table events add column fee_mode text not null default 'pass' check (fee_mode in ('pass', 'absorb'));
```
`fee_mode` is a per-event choice the organizer makes when setting a ticket price:
- `'pass'` — fees are added on top of the ticket price; the attendee pays the sticker price plus whatever fees apply.
- `'absorb'` — the attendee pays exactly the sticker price; fees come out of the church's payout instead.

**What changed client-side, now that Free tier can sell tickets:**
- The old hard block (`ce-price-locked`, an "upgrade to add a ticket price" message) is gone — `updatePaidEventsAccess()` now always shows the price section for every plan, and the submit-time check that rejected a new price on Free tier is removed.
- In its place: a live fee disclosure under the price field (re-rendered on every keystroke via a new `input` listener on `ce-price`, since there was none before) — the actual FaithDock fee text for a Free-tier church, or a "no FaithDock service fee on your plan" note for Starter and above — plus the pass/absorb radio choice, both hidden until a price is actually entered.
- The registration modal shows a plain-language note ("card processing and any applicable service fee will be added at checkout") whenever `fee_mode` isn't `'absorb'` — deliberately **not** a precise dollar estimate. The real total depends on live Stripe processing and the authoritative server-side calculation below; a client-guessed number that turns out to not match what Stripe actually charges is worse than a correct, vaguer disclosure. This is the same pattern ticketing platforms with this exact fee model already use: the sticker price is the base price, the real total appears at actual checkout.
- Giving gained a donor-facing "cover the fee" checkbox (`give-cover-fee-wrap`), shown only when `checkChurchGivingEnabled()` determines the church is on Free tier. Checking it grosses up the charged amount via `charged = intended / 0.99` — the algebraic solution to "after 1% comes out of what's charged, the church still nets what the donor meant to give," not "charge the intended amount and hope 1% is already baked in." Verified with real arithmetic ($100 intended → $101.01 charged → exactly $100.00 net after a 1% cut), not just read through.

**What the client deliberately does NOT try to do: compute or send the actual FaithDock fee amount.** Both `fee_mode` (on `events`) and plan type (on `churches`) are already stored server-side — the two edge functions below must read them fresh from the database at checkout time and compute the real charge and `application_fee_amount` themselves, authoritatively. Never derive the platform's own cut from anything the client sends; a client-submitted fee amount is trivially tamperable, and the whole point of storing `fee_mode` on the event (an organizer-level, server-side setting) rather than accepting it as a per-checkout client parameter is to remove that exact class of manipulation.

**Exact spec for `stripe-event-checkout`** (not in this repo — this is what needs to change there):
1. Look up `events.price_cents`, `events.fee_mode`, `events.church_id` for the event, and `churches.plan_type` for that church. Do not accept any of these from the request body.
2. `isFreePlan = plan_type is null or plan_type = 'free'`.
3. `faithdockFeeCents = isFreePlan ? round(price_cents * 0.03) : 0` — computed on the organizer's set ticket price, not on any fee-inclusive total (matches how the fee is quoted: "3% per ticket").
4. If `fee_mode = 'absorb'`: charge the attendee exactly `price_cents`. Set `application_fee_amount = faithdockFeeCents`. The church's net naturally comes out to `price_cents` minus Stripe's real processing cost minus `faithdockFeeCents`.
5. If `fee_mode = 'pass'`: the attendee should cover *all* fees, including Stripe's own, so the church still nets the full `price_cents`. That needs the full gross-up, not just adding the FaithDock fee on top:
   ```
   chargeAmountCents = ceil( (price_cents + 30 + faithdockFeeCents) / (1 - 0.029) )
   ```
   (30 = Stripe's ~$0.30 fixed fee in cents, 0.029 = Stripe's ~2.9% rate — use whatever this codebase's Stripe account's actual rate is if it differs.) Set `application_fee_amount = faithdockFeeCents` on this larger charge. Stripe's own cut comes out of the charge automatically as always; this gross-up is what makes the *attendee's* total include an amount that, once Stripe's real fee is deducted, still leaves enough for the church to net `price_cents` after `application_fee_amount` too.
6. Whichever Stripe Connect charge pattern this function already uses (destination charge, direct charge with `application_fee_amount`, or separate charge+transfer) — apply `application_fee_amount` the way that pattern expects; the financial formulas above are integration-pattern-agnostic, but the exact API call shape depends on which pattern is already in place there, which isn't visible from this repo.

**Exact spec for `stripe-create-checkout`** (giving — not in this repo either): the `amountCents` this receives already reflects the donor's "cover the fee" choice if they made one (grossed up client-side, same as if they'd typed a larger custom amount — nothing new to trust or not trust there). What this function needs to add: look up the church's `plan_type` itself, and if it's Free, set `application_fee_amount = round(amountCents * 0.01)` on the charge; 0 for every paid tier. Same rule as above: read plan type fresh from the database, never from the request.

---

## Pricing cards: full feature matrix instead of "Everything in X, plus..."

Design change, not a bug: each tier's card used to only list what it *adds* on top of the tier below ("Everything in Starter, plus…"), so reading any card except Free meant mentally chaining back through every cheaper plan first. Replaced with the same full feature list in every card — 15 rows, a green check with the tier's actual value for what's included, a clay X for what isn't — so any single card is readable standing alone.

Built as one data table (`renderPricingFeatureMatrix()`) driving all five `<ul>`s, rather than five hand-written, near-duplicate lists — a boolean feature is just `true`/`false` per tier; a scaling one (events/month, groups, staff invites) carries its actual per-tier value and still gets a check, since every tier has *some* level of it except where a tier genuinely gets zero (Free's 0 staff invites is a real X, not "0"). The table is rebuilt fresh inside the function on every call rather than held as a constant, specifically so its `window.t()` calls re-resolve on a language-toggle re-render instead of freezing in whichever language was active on first load.

Verified live: checked the actual computed style of every Free-tier row (sage `rgb(143,203,170)` on included, clay `rgb(226,145,122)` on excluded — not just that the right CSS class was present), confirmed Premium's "Multiple churches" row correctly shows as included with its real "Up to 5" value, and confirmed the whole matrix re-renders correctly in Spanish on toggle.

---

## Working conventions worth restating

- **Bump the footer build stamp** (`build YYYY-MM-DD-vNNN`) after every round of changes — it's the fastest way to confirm whether what's live actually reflects the latest work, or whether a browser is just caching an old version.
- **Auth-related changes get live-tested with real console/DOM evidence before being trusted.** This file exists specifically because several bugs "looked safe on paper" — three separate wrong theories, in one case — before someone actually inspected the DOM or pasted a real console log and the true cause became obvious. Reasoning from the code alone was not enough for any of the bugs listed above.
- **New user-facing strings** need both English and Spanish dictionary entries plus a `data-i18n` attribute (or `data-i18n-placeholder` / `data-i18n-title` for non-text-content cases). Mixed-content elements — an icon next to text — need the text wrapped in its own `<span data-i18n="...">`, not left as loose text beside the icon.
- **Plan-gated features** follow one pattern: an inline locked/upsell panel in the UI, plus a matching server-side check at save time. Never just hide something in the UI and call it gated.
- **Theming:** `--brand` (fixed navy) for anything that must stay legible against gold; `--ink` (adaptive) for regular body text. Mixing these up is how buttons go invisible in dark mode.

---

## Connecting the tier/pricing page to Stripe (sandbox) — `stripe-subscription` handed off

The pricing page's Starter/Standard/Premium buttons (`window.startPlanCheckout`, `index.html` ~14885) and the dashboard's "Manage billing" button (~15351) were already fully wired client-side to a `stripe-subscription` edge function — it just didn't exist yet. Wrote and handed over two full edge functions plus a migration (not committed to this repo — same reasoning as `stripe-event-checkout`/`stripe-create-checkout` above: edge function source lives outside this repo).

**Exact contract `stripe-subscription` must implement** (already called with this shape by the client — don't change the client, match this):
- `{ action: 'start_checkout', churchId, plan, successUrl, cancelUrl }` → `{ url }` (a Stripe Checkout Session URL, `mode: 'subscription'`) or `{ error }`.
- `{ action: 'confirm_subscription', sessionId }` → called from `checkForCompletedSubscription()` right after the redirect back (`?sub_session_id=...#dashboard`); best-effort immediate UI feedback, not the source of truth (see webhook below).
- `{ action: 'create_portal_session', churchId, returnUrl }` → `{ url }` (a Stripe Billing Portal session) or `{ error }`, called from `billing-manage-btn`.

**Storage decision: a new `church_billing` table, NOT new columns on `churches`.** `churches` is read with `select('*')` from several places the public can reach — most importantly `findOrFetchChurchByName()` (`index.html:5680`), which anonymous visitors hit on every church detail page — so a Stripe customer/subscription id put directly on that table would leak to anyone viewing the page. `plan_type` / `subscription_status` / `current_period_end` were left exactly where they already are on `churches` (already public today, already read by `loadBillingPanel()` and the giving-fee check) — only the two actually-sensitive ids (`stripe_customer_id`, `stripe_subscription_id`) moved to the new table, RLS'd to `select` by the owning church's owner only, written exclusively by the edge functions' service-role client. Full SQL handed to the user directly (`church-billing-migration.sql`).

**Two functions, not one — deliberately:**
- `stripe-subscription` (JWT-verified, called by the client) — the three actions above.
- `stripe-webhook` (deployed with `--no-verify-jwt`, called by Stripe itself, authenticated via `Stripe-Signature` instead) — the actual source of truth for `plan_type`/`subscription_status`/`current_period_end`, since a user closing the tab before the redirect completes would otherwise leave `confirm_subscription` never called at all. Subscribed to `checkout.session.completed`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.payment_failed`; a cancelled/expired subscription resets `plan_type` back to `'free'` rather than leaving it stamped with a stale paid tier.

Full code for both functions and the migration handed directly to the user (not pasted into this file — see chat) since they're Deno/TypeScript, not something this HTML+JS repo runs or checks.

**Correction, same day, after actually connecting this to sandbox Stripe:** the section above was written before discovering that `stripe-subscription` and its webhook counterpart (real name `stripe-subscription-webhook`, not `stripe-webhook` — that name belongs to a separate, pre-existing, unrelated function for donations/event tickets, never touch it for subscription work) **already existed** and already worked against `churches.stripe_customer_id` / `churches.stripe_subscription_id` directly — not a separate `church_billing` table. That table was proposed before this was known; it was never adopted and is safe to ignore/drop. The real gaps, found only by actually wiring this up end-to-end with the user watching Stripe's own dashboard in parallel:

- **`start_checkout` didn't support the `starter` plan at all** — it predated this session's Starter tier and only validated `standard`/`premium`. Fixed by mapping all three plans to their own `STRIPE_PRICE_*` secret.
- **No caller-ownership check** on `start_checkout`/`create_portal_session`/`confirm_subscription` — any signed-in user could pass a different church's id. `create_portal_session` in particular would have handed out a real billing-portal session (payment methods, cancel-subscription) for a church the caller doesn't own. Fixed with a shared `requireOwnedChurch()` check.
- **Stripe SDK on Deno needs `httpClient: Stripe.createFetchHttpClient()` explicitly.** Without it, the SDK's default Node-style networking triggers `Deno.core.runMicrotasks() is not supported in this environment` — which is a **real crash that can 500 the in-flight request**, not just harmless isolate-teardown noise (confirmed via the Function's own "Errors in last 24h" table showing this tied to an actual `POST`/500/635ms entry, not just a log line after the response was already sent).
- **This Stripe account's webhook payloads are pinned to a newer API version than the code's `apiVersion: '2023-10-16'`** (visible on the webhook destination's own "Destination details" panel in Stripe's dashboard). In that newer version, `current_period_end` moved off the top-level Subscription object onto each subscription item. Reading `sub.current_period_end` directly on a raw webhook payload throws `Invalid time value` when it's `undefined`. Fix: `sub.current_period_end || sub.items?.data?.[0]?.current_period_end`, falling back to `null` rather than crashing.
- **`churches.plan_type` had a check constraint that was never updated when the Starter tier was added** — every write of `plan_type = 'starter'` was silently rejected by Postgres. This was invisible for a long time because **neither edge function checked the `error` returned by `supabase-js`'s `.update()` call** — a Postgres rejection doesn't throw in supabase-js v2, it comes back as `{ data, error }`, so the functions kept returning 200/success to both Stripe and the client while writing nothing. Fixed the constraint (`in ('free','starter','standard','premium','multi_church')`) and — more importantly — now check and surface that `error` in both functions, so a future rejection shows up instead of vanishing. **This is the one worth remembering generally: any Supabase Edge Function that writes via `supabase-js` must check `error` on every `.update()`/`.insert()`, or a real failure looks identical to success on both ends.**
- **Multiple simultaneous active subscriptions per church** — switching plans previously always created a brand-new Checkout subscription without cancelling whichever one already existed, so a church that tried Starter → Standard → Premium in sequence ended up with several active subscriptions at once, each firing its own webhook events that raced to overwrite `churches.plan_type` — this produced a very confusing "plan flickers on refresh" symptom that looked unrelated to everything else above. Fixed: `start_checkout` now cancels the church's existing active subscription (if any) before creating a new one.
- Added a **downgrade-to-Free flow** (`cancel_subscription` action + `churches.cancel_at_period_end` column): schedules cancellation at the end of the already-paid period rather than cutting the church off immediately; the Billing panel and Pricing page's Free-tier button both surface it. Previously there was no way to downgrade at all — the Free card's button always sent an existing paid owner to "Register your church," which made no sense for someone who already had one.

**Lesson for next time:** when a client-declared "not in this repo, spec handed off" backend piece turns out to already exist, get and read its actual current source before writing any replacement code — several rounds of this debugging were spent on a function (`stripe-webhook`) that was never the right one, and on a storage design (`church_billing`) that never matched what was already live.

---

## Billing panel simplified; "Giving" became "Revenue" (giving + ticket sales combined)

Product decision, following directly from the Stripe work above: the dashboard's Billing panel had grown Upgrade/Downgrade buttons that didn't make sense there (Downgrade showing at every paid tier, including ones nowhere close to Free, was the concrete complaint) — removed both, leaving just "Manage billing." Upgrading and downgrading both already exist properly on the Pricing page (highlights the current tier, offers every plan including Free), now reachable via a new **"Plans" sidebar nav item** (plain `data-route="pricing"` link, deliberately not a `[data-dash]` item — those get intercepted by `goDash()`'s delegated click handler and would try to switch to a nonexistent in-dashboard panel instead of navigating away).

Separately, "Giving" (nav item + page) is now **"Revenue"** — it still contains everything Giving did, plus a new Ticket sales section, plus two combined summary tiles at the top (Total income, Net after fees). `id="dash-giving"` and every `dashGiving.*`/`giving-*` id were deliberately left unchanged internally — only the user-facing label changed (`dash.revenue`) — to avoid a wide, riskier rename across `loadGivingHistoryPanel()` and its dozen `giving-*` element ids.

**"Net after fees" needs data that doesn't exist yet.** Stripe computes the real fee numbers at charge time (its own cut via the charge's `balance_transaction.fee`, FaithDock's cut via `application_fee_amount`), but nothing previously wrote either back into `donations` or `event_registrations` — only `amount_cents`/`amount_paid_cents` (what the payer paid) is stored. Added `stripe_fee_cents`, `application_fee_cents`, `net_amount_cents` to both tables (migration handed to the user) and a spec for the one change needed in the **real, already-working `stripe-webhook`** function (donations + event tickets — not `stripe-subscription-webhook`): fetch the charge's `balance_transaction` inside the existing `checkout.session.completed` handler and write the three new columns alongside what it already does, wrapped in try/catch so a fee-lookup failure never blocks recording that the payment itself succeeded.

**Null-safe by design, not by accident:** `loadGivingHistoryPanel()`/`loadTicketSalesPanel()` explicitly distinguish "no rows have fee data yet" (every relevant `net_amount_cents` is null → show "—") from "$0 net" — a transaction whose fee lookup hasn't run yet (pre-migration row, or the webhook update not deployed yet) is excluded from the net sum entirely rather than counted as zero. Verified with mocked Supabase responses: a $150 giving + $50 ticket month with one donation missing `net_amount_cents` correctly summed only the known net amounts ($143 total, not $143 mistaken for $150, and not blocked entirely by the one null row); an all-null dataset correctly showed "—" for net while still showing the real $120 gross total.

Both halves (`loadGivingHistoryPanel()`, `loadTicketSalesPanel()`) now return `{ totalCents, netCents }` and are combined by a new `loadRevenuePanel()` wrapper that also fills the two summary tiles — call sites that used to call `loadGivingHistoryPanel()` directly (dashboard render dispatcher, post-login load) now call `loadRevenuePanel()` instead so both halves refresh together.

---

## Events denomination filter, plan-before-registration, pricing page polish

Four small-to-medium changes landed together:

**Events page denomination filter**, mirroring the Directory page's dropdown UI exactly (same checkbox list, search box, "N selected" label) but under new ids/class (`events-denom-filter`, not `denom-filter`) — reusing the Directory's class name would have made its checkboxes also fire the Directory's own document-wide change/click delegation. `search_events()` has no `p_denominations` param the way `search_churches()` does, so this resolves to a church-id list client-side (`supabase.from('churches').select('id').in('denomination', [...])`, the same query shape already used for the "For You" tab's denomination expansion) and feeds it into the existing `p_church_ids` param. When the followed/home/For-You OR-set is *also* active, the two are **intersected**, not unioned — the denomination filter is a genuinely restrictive filter, not another way to add churches into that OR-set. Verified live against the real backend: unchecking a denomination correctly re-queried and changed the real event count, with the label updating to "8 selected" etc.

**Plan required before a first church exists.** The existing "Add a church" click handler already called `get_my_plan_and_usage()` to enforce the church-count cap — reused that same already-fetched result: `churches_owned === 0` now redirects to Pricing instead of opening the registration form. A 2nd–5th church under an existing plan (`churches_owned >= 1`) is deliberately untouched — that path already inherits the owner's existing `plan_type` and forcing a plan re-choice there would be pointless. The chosen plan survives the trip through `#register-church` via `sessionStorage['faithdock_pendingPlan']`, and is picked back up in the register-church submit handler's new-church branch: a paid pending plan calls `startPlanCheckout()` immediately after the church is created (still on Free `plan_type` at that point — never set optimistically) instead of `go('dashboard')`; Free (or no pending plan) falls through to the normal dashboard redirect. The Free card's own button clears any stale pending plan from an abandoned earlier attempt.

**"Claim this church" was deliberately NOT changed the same way** — claiming submits an admin-reviewed request (`churchClaim.submitted`: "we'll review it and follow up by email"), not immediate ownership; there's no real church-management moment at claim time to attach a plan choice to.

**Pricing page now reads correctly for an existing partner church**: title becomes "Manage your plan" (`pricing.titleExisting`) instead of "Become a Partner Church" once `myChurch` resolves, and a standalone "Cancel subscription" link appears near the top (in addition to the Free card's own dynamic downgrade button) for anyone on a paid plan — same `cancel_subscription` action, factored into a shared `performPlanDowngrade()` helper so the two entry points don't duplicate the confirm/error-handling logic. Both reset to their signed-out defaults at the top of `populatePricingPage()`, same pattern as the plan buttons already used.

**Update, same day:** the standalone top-of-page cancel link was relocated per follow-up feedback — it now lives directly under whichever paid card (Starter/Standard/Premium) matches the viewer's actual current plan (`pricing-cancel-sub-starter/standard/premium`, one per card, only one ever visible at a time), never under Free. The Free card's own "Downgrade to Free" button was left as-is alongside it — a second, harmless way to reach the same action, not something this follow-up asked to remove.

**Denomination dropdowns (Directory and Events) both got Select all / Uncheck all controls.** Adding "Uncheck all" surfaced a real latent bug in the Directory's own filter resolution: `else if (f.checkedDenoms.length)` is falsy at exactly zero checked, so unchecking everything fell through to the unreachable default (`denominations` stays `null`, meaning "no filter" — i.e. paradoxically showed *every* church) instead of the obviously-intended "show none." Fixed to `else { denominations = f.checkedDenoms; }` — an explicit empty array is a real, distinct value from `null` and correctly matches zero rows. The Events filter's own resolution (written this same session, one entry earlier) already handled zero-checked correctly by construction.

---

## Claim-a-church flow: plan choice inserted, resuming across a sign-up detour

Product decision: "Claim this church" now sends *everyone* — a brand-new sign-up and an existing account alike — through Pricing before they ever see the actual claim form, on the theory that most will pick Free just to get started. Previously, being signed in landed straight on the claim modal.

**The claim modal is no longer opened directly from the church page.** It's now driven entirely by a `faithdock_pendingClaim` sessionStorage value (`{id, name}`, via new `window.setPendingClaim/getPendingClaim/clearPendingClaim`) set the moment "Claim this church" is clicked, and consumed by a shared `openClaimModal()` — the only thing that actually opens it now, called from the Pricing page's button-click override once a plan is chosen. Both the church-page click and the claim submission itself now read from this value instead of the old `church-unclaimed-banner` DOM attributes, since by the time the claim form is reached the visible page is Pricing, not the church's own page (the banner element may not reflect the right church at all by then).

**Real gap found and worked around, not papered over:** the existing `login-required-modal`'s own Sign Up/Log In buttons unconditionally call `clearStalePostLoginRoute()` as they navigate away — correct for that modal's normal callers (nothing in particular to resume), but it would have silently discarded a route saved via `savePostLoginRoute()` for *this* flow the instant someone clicked Sign Up. Rather than touch that shared modal's behavior (used by many unrelated callers relying on the stale-clearing to *not* resume some unrelated old intent), the post-login landing-route computation now checks `getPendingClaim()` first, independently of `consumePostLoginRoute()` — a completely separate sessionStorage key that button never touches, so it survives the OAuth/email round trip intact regardless of what the login modal does with the other one.

**Plan choice during a claim is honest about what it can't do yet.** There's no owned church to attach a paid plan to at claim time — the claim is just a request awaiting admin review, and Stripe checkout has nothing real to attach to. Free proceeds straight to the claim form. A paid tier is remembered (`faithdock_pendingPlan`, same key the "Add a church" flow uses) but **not currently applied anywhere** — no backend hook exists for "when this claim gets approved, resume that person's chosen paid plan," since claim approval is an async admin action this repo has no visibility into. Flagged here rather than silently pretended-solved; a real fix needs whatever the admin-approval process actually is to read and act on that stored preference.

**"Did you mean to add a church instead?"** sits inside the claim modal itself, reusing the exact same `data-add-church="true"` link pattern (and therefore the exact same plan-required flow) as every other "Add a church" entry point — clicking it also closes the modal and clears the pending claim, so it can't linger and contaminate an unrelated add-a-church attempt afterward.

Verified live against the real backend: clicking Claim on a real unclaimed church stores its real id/name and redirects to Pricing; the banner interpolates the real church name; every plan button opens the modal pre-filled with that name and the signed-in email; "Did you mean to add a church" closes the modal, clears the pending claim, and proceeds toward registration; submitting inserts with the pending claim's `church_id` (not a stale banner attribute) and clears it afterward.

**Reverted the same day, on user reflection:** requiring a plan choice *before* claim submission put the cart before the horse — there's nothing to attach a paid plan to until (if) the claim is actually approved, and forcing the choice pre-emptively meant asking someone to commit before knowing the outcome. "Claim this church" now opens the modal directly again. All the `faithdock_pendingClaim` infrastructure (`setPendingClaim`/`getPendingClaim`/`clearPendingClaim`, `openClaimModal()`) stayed — it's still what lets the claim survive a sign-up detour for a not-yet-signed-in visitor, reopening the modal automatically once they're back (now via a direct call in the post-login landing logic, not by forcing `landingRoute` to `'pricing'`). The `populatePricingPage()` button override, the pending-claim banner, and `churchClaim.choosePlanFirst` were removed as dead weight (the i18n key was left in the dictionary, unused, in case this design comes back in a different shape).

**Proposed instead — plan choice after approval, not before submission** (not built; genuinely can't be, from inside this repo, without more visibility):
- There is **no admin-side claim review UI anywhere in this repo** — only the `church_claim_requests` insert exists. Whatever "approving" a claim currently means happens entirely outside anything visible here (direct Supabase table edits, presumably).
- The buildable shape of this, once that's confirmed: a Postgres trigger on `church_claim_requests` firing on transition to some `status = 'approved'` (add the column if it doesn't already exist) that (a) sets the target church's `owner_id` to the requester and (b) calls an edge function to email them — reusing whatever pattern the existing `smooth-action` function already uses for its other email-sending (welcome emails, ownership handoff), not a new one-off mechanism.
- That email's link should land the recipient on `#pricing` while genuinely signed in and now actually owning the church — at which point the Pricing page already does the right thing with zero further work: it resolves `myChurch`, shows "Manage your plan" instead of "Become a Partner Church," and every plan button already works normally (real checkout for a real owned church, no `pendingPlan` gymnastics needed the way the pre-submission version required).
- **Whoever picks this up needs to say how approval currently happens** before any of the above can be written for real — this file can specify the shape, not the actual trigger/email code, without that.

---

## `toLocaleDateString(undefined, ...)` follows the browser's system locale, not this app's language toggle

Found from a real, reported bug: the Revenue/Insights giving charts' 12 month labels stayed in English after toggling to Spanish, while every other label on the same page correctly went Spanish. `undefined` as the locale argument to `toLocaleDateString`/`toLocaleTimeString` means "use the browser/OS's own locale" — completely independent of `window.currentLang`. It only ever looked correct when a Spanish-speaking tester's OS/browser also happened to be set to Spanish, which is presumably why this went unnoticed until now, in both this week's newly-written code (`loadGivingInsights()`'s and `loadRevenuePanel()`'s 12/6-month chart labels — both already had refresh-on-toggle wiring, so once the locale itself is fixed they update immediately, no extra plumbing needed) and evidently in code from well before this session (`formatEventWhen()`, which an earlier GOTCHAS entry incorrectly assumed was "already locale-aware" without actually checking what locale argument it passed).

Added `window.appLocale()` (`'es-ES'` when `window.currentLang === 'es'`, else `'en-US'`) — pass this instead of `undefined` anywhere a date/time gets formatted for display.

**Update, full sweep done:** all **53** occurrences of this pattern across the whole file are now fixed, not just the two originally reported — `toLocaleDateString`/`toLocaleTimeString`/`toLocaleString`, both the `(undefined, {...})` form (36) and the bare `()` form with no arguments at all (17, same bug — `toLocaleDateString()` with zero arguments *also* silently follows the browser's locale, and additionally changes the actual date field order: `es-ES` renders day-before-month). Verified live: `new Date(2026, 2, 9).toLocaleDateString(window.appLocale())` correctly gives `"3/9/2026"` in English and `"9/3/2026"` in Spanish (that specific date deliberately chosen with day ≠ month, since day/month values that coincide can mask an order bug); number formatting via `.toLocaleString()` also confirmed locale-correct (`"123,457"` vs `"123.457"` thousands separator).

---

## Admin church-claim review already existed — it just wasn't discovered

Asked to "build the admin review of church claims" on the assumption it didn't exist. It does — fully. `git log -S "admin-claims-list"` traces it to the **very first commit** in this repo (`88e8ac6`, before any work this session), not something built and forgotten partway through. The "Pending church claims" section sits on the Admin page below "All churches" — search UI, per-request cards (church, requester name/role/email, note, date), Approve/Reject buttons wired to a real `review_church_claim` RPC, plus a separate "Claim history" section for resolved ones. Confirmed live against the real backend, not just by reading the code: `get_pending_church_claims` returns `{data: [], error: null}` (works, just nothing pending right now) and `review_church_claim` on a fake UUID returns a real business-logic error ("Claim request not found or already reviewed"), not a "function does not exist" error — both genuinely deployed and callable.

**Worth a look, not confirmed as a real problem:** that fake-UUID test returning a *business-logic* error rather than an auth error doesn't by itself prove `review_church_claim` checks `is_platform_admin` before acting — the not-found check may simply run first regardless of who's calling. Recommend confirming the function's own body actually gates on the caller being a platform admin (`auth.uid()` + a `profiles.is_platform_admin` check, same pattern the rest of this admin surface presumably uses) before treating this as fully trustworthy — this wasn't (and, without a real admin session or the function's source, couldn't safely be) tested further here.

**Added instead, per request:** a phone number field on the claim form itself (`church-claim-phone`), required alongside name and email — genuinely missing "standard contact info" for reviewing a claim. New `requester_phone` column on `church_claim_requests` (migration handed to the user) and the admin claims list now displays it. **`get_pending_church_claims` needs one matching line added** (`cr.requester_phone` alongside `cr.requester_email`, in both its SELECT and `RETURNS TABLE`) — its source isn't in this repo, so rather than guess at rewriting the whole function, the migration file asks for its current body back before touching it, same lesson as the Stripe functions earlier this session.

**This turned into a real, confirmed security incident, not a hypothetical.** The user pasted `get_pending_church_claims`'s actual source in response to that ask, and it contained a literal `-- ADMIN CHECK HERE` comment with nothing after it — no check at all, confirmed exploitable (called it anonymously, got a real result instead of a permission error). Asked for `review_church_claim` next: same pattern, and far worse — `approve = true` sets `churches.owner_id = requesting_user_id` directly, meaning any signed-in user could submit a claim on any church and then call this function on their own request id to become its owner instantly, no admin involved. Fixed both immediately (`is_platform_admin()` check added, `get_pending_church_claims` also needed a drop-and-recreate since adding `requester_phone` changed its return row shape — Postgres won't let `create or replace` do that in place).

**That prompted a full list of every function in the database** (`Database → Functions` in Supabase), which turned up **6 more** with the identical gap, found by reading every `security definer` function's actual source rather than guessing from names:
- `get_churches_without_coordinates` — same bare placeholder (this repo already had this function's source from earlier in the session, from before the vulnerability was known — fixed without needing to ask again).
- `search_users_admin` — the worst of this batch: full user directory (email, name, church affiliation) with zero check, to anyone.
- `admin_delete_unclaimed_church` — destructive; anyone could delete any unclaimed listing.
- `get_church_claims_history` — same requester PII exposure as the claims functions above, for resolved claims.
- `search_all_churches_admin` — exposed every church's `owner_id`.
- `admin_import_churches` — anyone could bulk-insert arbitrary church listings.
- `get_group_notification_recipients` — worse than the others in one way: it didn't even have the placeholder comment. No check was ever attempted, at all. Fixed using the same owner-or-`is_church_staff_member` pattern `get_mass_email_recipients` already used correctly, reached through the group's own `church_id`.

**Confirmed properly protected already** (read, not just assumed): `get_pending_verifications`, `get_recent_client_errors`, `get_directory_people`, `get_staff_with_permissions`, `get_mass_email_recipients`, `update_staff_permissions`, `get_person_giving_history`, `get_person_event_signups`, `find_church_people_by_email`. The owner-or-staff pattern (`exists (... owner_id = auth.uid()) or is_church_staff_member(...)`) is used consistently and correctly across all of these — whoever wrote this codebase clearly knew the right pattern; the vulnerable ones are specifically the *platform-admin*-gated functions where the checklist item got left as a TODO instead.

**Total: 9 functions fixed** across `get_pending_church_claims`, `review_church_claim`, `get_churches_without_coordinates`, `search_users_admin`, `admin_delete_unclaimed_church`, `get_church_claims_history`, `search_all_churches_admin`, `admin_import_churches`, `get_group_notification_recipients`.

**One real bug this introduced, caught by re-verifying live rather than trusting the fix:** the first two functions (`get_pending_church_claims`, `get_churches_without_coordinates`) both have `id uuid` in their own `RETURNS TABLE`, which PL/pgSQL exposes as an implicit variable throughout the function body — so their inline permission check's bare `where id = auth.uid()` was ambiguous (Postgres couldn't tell if `id` meant `profiles.id` or the function's own output column) and the functions errored out for *everyone*, admin included. Failed closed, not open — no security regression, but a real availability bug. Fixed by switching both to the same `is_platform_admin()` helper the other 7 fixes already used (which never references a bare `id` at all, avoiding the collision entirely) — this is also why that helper is the safer default over inlining the `profiles` check by hand.

**Final state, confirmed live, not assumed:** all 9 fixed functions, called anonymously with no session, now correctly return a permission-denied error and zero data — tested directly against the real database after every round of fixes, including this last one.

**Not fully closed yet:** the pg_trgm extension functions (`gin_trgm_*`, `gtrgm_*`, `similarity*`, `word_similarity*`, etc.) were correctly identified as PostgreSQL internals, not app code, and excluded from this review. Everything else in the list has now actually been read, not assumed — but any function created *after* this review obviously isn't covered by it. Worth treating "add the permission check" as a mandatory step when writing a new `security definer` function from here on, not a follow-up TODO.

---

## `churches.stripe_customer_id`/`stripe_subscription_id` exposed via public `select('*')` — closed

Flagged as a lower-severity, non-urgent finding twice earlier this session (while first connecting sandbox Stripe, and again while reviewing the churches table's public columns) but never actually fixed — closed now while doing a broader security pass. Confirmed live: an anonymous, unauthenticated `select('*')` on a real church (reachable via `findOrFetchChurchByName()`, which every visitor to a church's own public page hits) returned real `stripe_customer_id`/`stripe_subscription_id` values. Severity stayed correctly assessed as information-disclosure, not "someone can charge the church" — a bare Stripe id is useless without the account's own secret key, which never leaves the server.

**Two-part fix, both required — one alone doesn't close it:**
1. **Client-side:** all 5 `churches.select('*')` call sites now use a new shared `PUBLIC_CHURCH_COLUMNS` constant (explicit column list) instead. This alone only stops leakage through *this app's own UI* — anyone can still query the REST API directly with the public anon key regardless of what the client code does.
2. **Database-level (the actual boundary):** `revoke select (stripe_customer_id, stripe_subscription_id) on churches from anon, authenticated` (migration handed to the user). After this, even a raw `select('*')` from those roles fails outright for the whole query — which is exactly why step 1 had to happen first, not instead: every remaining `select('*')`-shaped call needed to already be column-scoped before the revoke could safely land, or those five call sites would have started erroring.

**`stripe_account_id` was deliberately kept public, not swept in by mistake.** It's Stripe Connect's account id (for accepting donations/tickets), a different field from the two platform-subscription-billing ids being closed here — and unlike those two, it already has real, legitimate client-side reads: the church owner's own Give-setup check (`checkChurchGivingEnabled`-style code) and the admin panel's "Stripe connected: Yes/No" display both need it. `PUBLIC_CHURCH_COLUMNS` includes it on purpose. Verified live after the fix: the same anonymous query now returns every other column correctly, with `stripe_customer_id`/`stripe_subscription_id` genuinely absent from the result — not just null, not present at all.

---

## Spanish month labels: correct language, wrong case for a standalone axis label

Real, reported issue, distinct from the earlier locale-argument bug: Intl's Spanish month abbreviations are correctly lowercase by default ("abr", "sept") — that's standard Spanish typography, not a translation gap. It only reads as "not fully Spanish" because a few abbreviations (may, jun, jul) happen to share spelling with English, and because every English label on the same chart is Title Case, making the lowercase Spanish ones look unstyled by comparison.

Added `window.capitalizeFirst()` and applied it **only** to the two chart-axis month labels that use `month: 'short'` in isolation (the Insights 12-month and Revenue 6-month giving trend charts) — checked the other ~20 places `month: 'short'` appears first, and all of them format a full date (`day: 'numeric'`, often `weekday: 'short'` too), where a lowercase embedded month is correct, standard Spanish sentence-style formatting and shouldn't be touched. Verified live: the chart now reads "Abr, May, Jun, Jul, Ago, Sept" instead of "abr, may, jun, jul, ago, sept".

---

## Correction: the first `stripe_customer_id`/`stripe_subscription_id` migration didn't actually work

Re-verified live after the user ran it — `stripe_customer_id`/`stripe_subscription_id` were **still** fully readable anonymously, both via `select('*')` and by naming them directly. The migration (`revoke select (col1, col2) on churches from anon, authenticated`) was valid SQL and *should* restrict those two columns in isolation, but Supabase grants blanket table-level `SELECT` to `anon`/`authenticated` on every table by default (relying on RLS for row-level restriction, not columns) — and a narrower column-level `REVOKE` does not override a pre-existing table-level `GRANT`. Postgres checks "does this role have table-wide SELECT?" first; if yes, that wins regardless of what's revoked underneath it at the column level. This is a real, easy-to-miss Postgres privilege-model gotcha, not a "ran it wrong" issue.

**Correct fix:** revoke the table-wide `SELECT` entirely, then `GRANT SELECT` back on an explicit allowlist of the columns that should stay public (everything except the two subscription-billing ids). Cross-checked every distinct `.select(...)` call on `churches` across the whole file (not just the ones already using `PUBLIC_CHURCH_COLUMNS`) before finalizing the allowlist, to make sure no legitimate narrower query (billing panel's `cancel_at_period_end`, the register-church form's `churchFields`, the Give-setup check's `stripe_account_id`, etc.) would break.

**Verified live, this time actually closed:** `select('*')` and directly naming the two sensitive columns both now fail with `permission denied for table churches`; the app's own `PUBLIC_CHURCH_COLUMNS` query and three other real narrower queries (billing panel, register-church fields, Give-setup) all still return correctly with no error.

---

## `profiles.is_platform_admin` readable by anyone, for anyone — found via a full anonymous table sweep

After the `churches` leak above, did a broader empirical pass rather than assuming that was the only one: anonymous `select('*').limit(2)` against every distinct `.from('...')` table used anywhere in the app (~29 tables). `donations`, `event_registrations`, `groups`, `church_claim_requests`, and everything else scoped by RLS correctly came back empty for anonymous access even when tested against churches/rows known to have real data — but **`profiles` returned full real rows**, including a real user's row with `is_platform_admin: true`. That's a materially worse exposure than a generic info leak — it directly tells anyone who your platform admins are, a real targeting risk.

**Why this one is architecturally different from the `churches` fix above:** column-level `revoke`/`grant` can restrict *which columns* are readable, but not *which row* — it can't express "only readable on your own row." `is_platform_admin` (and `phone`, in the same boat) both need to stay privately readable by their own owner for legitimate app features (an admin-nav-link check, post-login routing, the Profile settings page), so a blanket revoke on the column would break those, not just outsiders.

**Fix used:** route the self-read through the existing `is_platform_admin()` RPC instead of a raw column select — it's `security definer`, takes no arguments, and by construction can only ever answer for the caller (`auth.uid()`) themselves, regardless of what the raw table's own grants allow. Switched the two client call sites that read this column — `updateAuthUI()`'s admin-nav-link check and `routeAfterLogin()`'s post-signin routing — to call the RPC (in parallel with their existing profile query via `Promise.all`) instead of selecting `is_platform_admin` directly. Confirmed live that the RPC itself is safe to call anonymously (`{data: false, error: null}` — never leaks anyone else's status). With both call sites off the raw column, `revoke select (is_platform_admin) on profiles from anon, authenticated` (migration handed to the user) closes it at the database level with nothing left depending on the old read path.

**Deliberately not touched in the same pass:**
- **`profiles.phone`** is in the identical situation (readable for anyone, any row) but has no RPC equivalent yet — the Profile settings page currently reads/writes its own phone number via a direct column select. Revoking now would break that with nothing to fall back to. Needs a small new "read my own phone" RPC (or a public-view/tightened-RLS split, same shape as the fix above) before it can be closed the same way.
- **`full_name`/`avatar_url`** are also broadly public on `profiles`, unauthenticated visitors included — flagged as lower severity, likely acceptable given the app's social/directory nature (these are the fields shown in staff lists, group rosters, etc.), but the same underlying gap in principle. Left alone pending a call on whether that's actually intended.

**Rest of the sweep came back clean** — every other table tested correctly returns empty rows to an anonymous caller even when scoped to real data, confirming RLS is doing its job everywhere except this one table.

---

## `profiles` hardened fully — phone RPC built, full_name/avatar_url exposure closed, and a more severe write-side hole found along the way

Follow-up to the `is_platform_admin` fix above, closing the two items explicitly deferred there: `profiles.phone` (needed a self-read/write RPC that didn't exist yet) and `profiles.full_name`/`avatar_url` being broadly public including to signed-out visitors.

**A second, more severe hole turned up while building this fix, not asked about but too important not to close in the same pass:** probing the write side (an anonymous `update(...).eq('id', <a UUID that does not exist>)`, chosen so nothing real could be touched either way) returned a clean success instead of a permission error. The only way that's possible is if `anon` currently holds an unrestricted, table-wide `UPDATE` grant on `profiles` with nothing scoping it to "your own row only" — meaning, in the worst case, anyone (no login required) could set **any** user's `is_platform_admin` to `true`, or overwrite their phone/name/anything else, just by knowing their user id. Confirming this against a *real* row would have meant writing to real user data even idempotently, which this session's own safety controls correctly declined to do without asking first — so this is reported as a near-certain finding, not a 100%-confirmed one. Closed regardless: every legitimate write now goes through a `SECURITY DEFINER` function, and the raw `UPDATE` grant is revoked entirely for both `anon` and `authenticated`.

**Every real client-side read/write of `profiles` was checked (not guessed) before deciding what stays on the raw table grant vs. moves to a function** — grepped every `.from('profiles')` call in the file:
- `full_name` stays broadly readable by `authenticated` — genuinely load-bearing for ~15 already-shipped features that read *other* users' full_name (church_staff/group_members/donations/event_registrations/support_messages/platform_feedback embeds via PostgREST relationships, the admin people directory, Insights donor/attendee name lookups).
- `age_range` stays broadly readable by `authenticated` too — the Insights donor/attendee age-bucket breakdowns read other people's `age_range` by id list, a legitimate existing feature.
- `account_type` and `avatar_url` turned out to have **zero** real cross-row read dependency anywhere in the app once actually checked — every "other user's avatar" spot already goes through the `get_directory_people()` RPC, not a raw select, and every `account_type` read is the caller's own. Both moved fully to self-only, closing them further than just "not to anon" — not even other signed-in users can read them off the raw table anymore.
- `phone`, `is_platform_admin`, `welcome_email_sent`, `full_name_changed_at` — same self-only treatment, continuing the pattern from the `is_platform_admin` fix.
- `plan_type` — not read by the client anywhere at all; dropped from the grant on general principle.
- `anon` gets no `SELECT` and no `UPDATE` on `profiles` at all now, full stop — no feature anywhere reads or writes a profile while signed out.

**New functions** (all `SECURITY DEFINER`, scoped internally to `auth.uid()`, matching the `is_platform_admin()`/`update_profile_name()` precedent already in this codebase): `get_my_private_profile()` (one call replacing the Profile settings page's old combined select — full_name/account_type/phone/avatar_url/age_range/full_name_changed_at), `get_my_account_type()` (paired with the existing `is_platform_admin()` in `updateAuthUI()`/`routeAfterLogin()`), `update_my_phone()`, `update_my_avatar()`, `update_my_age_range()`, `mark_my_account_type_church()`, and `mark_my_welcome_email_sent()` (atomic check-and-set, replacing what used to be a separate read then a separate write with one round trip). Every raw `.update(...)` call against `profiles` is gone from the client entirely.

**Also fixed in passing, same line already being touched:** the phone-save status message hardcoded `'Saved!'` in English regardless of language — swapped for the existing `common.saved` key, same one the age-range save status right next to it already used correctly.

**Sequencing note, unlike every other SQL fix this session:** this one can't ship client-first — the edited client code calls RPCs (`get_my_private_profile`, etc.) that don't exist in the database yet, so pushing before the migration runs would break the Profile settings page and church-registration account-type sync live. The migration needs to run *before* this commit reaches production.

---

## Remove (×) button on the profile photo

Small addition alongside the `update_my_avatar()` RPC above — the Profile page could set a photo but never clear one. Added a small × button over the photo (same visual pattern as the register-church logo's own remove button), shown only when a photo is actually set, calling `update_my_avatar(null)` and refreshing the page's own reload path. No confirmation dialog, matching how every other save action on this page already behaves (immediate, no "are you sure").

---

## Dashboard "Plans" tab now stays inside the dashboard shell instead of navigating away

Reported with a screenshot: clicking "Plans" in the dashboard sidebar used to be a real route change (`href="#pricing"`) to the entirely separate standalone Pricing page — every *other* sidebar item (Events, Billing, Settings, etc.) instead swaps a panel without ever leaving the dashboard, so Plans was the one link that visually "closed" the dashboard (sidebar and all) instead of behaving like its neighbors.

**Fix avoids duplicating the plan-card grid and all of `populatePricingPage()`'s logic a second time.** The standalone Pricing page's actual content div (`#pricing-content-root` — the `.wrap` inside `#page-pricing`) is a single real DOM node that now gets *relocated* into a new empty `#dash-plans` panel while the Plans tab is active, and given back to `#page-pricing` the moment it's not — `populatePricingPage()` only ever looks its elements up by id, so it works identically no matter which parent currently holds them, no changes needed there at all.

New `restorePricingContentToStandalonePage()` handles the "give it back" side, called from two places: `goDash()` whenever switching to any dash tab *other than* `plans` (covers switching tabs while already in the dashboard), and `go()` whenever navigating to any page *other than* `dashboard` (covers leaving the dashboard entirely — clicking a top-nav link, going Home, etc.). Deliberately **not** called unconditionally inside `go()` — a bare `go('dashboard')` (several post-action redirects already call this with no sub-route) must never yank the content out from under an already-active Plans tab; only an actual tab *change* moves it. Verified live, all as a real signed-in owner would see them: switching Plans → another tab restores it; leaving the dashboard entirely restores it; calling `go('dashboard')` alone while Plans is already active leaves it untouched; a direct/refreshed `#dashboard/plans` link lands correctly with Plans active and the dashboard sidebar showing (this last one worked for free — `showRouteFromHash()`'s existing `#dashboard/<tab>` deep-link handling didn't need any changes).

The sidebar link itself changed from `<a href="#pricing" data-route="pricing">` to a plain `<a data-dash="plans">`, matching every other sidebar item's markup exactly — no route, no href, just a tab switch.

**Follow-up bug from the same change, reported with a screenshot:** the plan cards' feature list (built by `window.t()` calls inside `renderPricingFeatureMatrix()`, not static `data-i18n` HTML) stayed in English on a language toggle while viewing Plans inside the dashboard, needing a refresh to catch up — everything else on the card (headings, prices, buttons) toggled correctly. Cause: the language-toggle dispatcher only re-ran `populatePricingPage()` when `currentBase === 'pricing'`; viewing Plans through the dashboard means `currentBase` is `'dashboard'` instead, so that line never fired. Added a matching `currentBase === 'dashboard'` entry alongside the other dashboard-loader re-renders already there (Insights, Revenue, Events, etc.) — safe to call unconditionally like those, since `populatePricingPage()`'s elements exist wherever `pricing-content-root` currently lives, whether or not Plans happens to be the active tab. Verified live via an actual toggle click: the feature list now flips to Spanish immediately, no refresh needed.

---

## "No data yet." staying in English on an otherwise-fully-Spanish Insights chart

Reported with a screenshot: an Insights mini-chart's empty state showed "No data yet." in English while everything else on the page was Spanish. Root cause was the ordinary one from the earlier locale sweep — a hardcoded English literal (`renderMiniBarChart()`'s empty-data branch) never routed through `window.t()`. Added `insights.noDataYet` to both dictionaries and swapped the literal for `window.t('insights.noDataYet')`. `renderMiniBarChart()` is shared by every Insights mini-chart (giving trend, giving-by-age, attendance, attendance-by-age, involvement breakdown/movement) so this closes it everywhere at once, not just the one chart in the screenshot. No extra re-render wiring needed — the functions that call it (`loadGivingInsights`, `loadAttendanceInsights`, `loadInvolvementPanel`) are already in the language-toggle dispatcher, so an already-rendered "no data" empty state updates immediately on toggle, same as everything else that dispatcher covers.

---

## Full sweep: dashboard toggle-refresh gaps, plus a bigger separate cluster of hardcoded-English panels

Asked directly after the Plans-tab fix above: "is there any other issues on the site like this — where the translation won't translate without a refresh?" Rather than guess, mapped every dashboard-tab loader function against the language-toggle dispatcher and the sign-in refresh batch (a second list, a few hundred lines up, that already treats a set of dashboard panels as "always DOM-resident regardless of active tab, safe to refresh unconditionally" — the same reasoning the toggle dispatcher itself was built on). Cross-referencing those two lists surfaced two distinct, previously-undiscovered problems.

**Same bug class as the Plans tab — properly `window.t()`-built, just missing from the toggle dispatcher:** `loadTeamPanel()` and `loadDashboardGroups()`'s row-action tooltips. Added both to the dispatcher, alongside the rest of this pass (see below) — same one-line fix as the Plans tab.

**A second, bigger, distinct bug found while doing this check — not "stays stale until refresh," but *never translates at all, in either language, ever*, because the strings were hardcoded English with no `window.t()` call in the first place:**
- `loadGivingStatus()` — the entire "Connect your bank account" donations-setup panel: every verification-gate state (pending/rejected/not verified), every connection state (connected/setup incomplete/not connected), every button label. The biggest one, ~16 new `dashGiving.*` keys.
- `loadBillingPanel()` — plan name and "Next billing date:"/"Access ends:"/"Ending, moving to Free:" text. Its `planLabels` map used to be a plain object built *once* at module-load time (`var planLabels = {...}`) — meaning even after adding `window.t()` calls, a stale object built in whichever language was active when the script first ran would never update again, the exact same class of bug as everything else in this pass, just one level deeper (data, not a missing dispatcher entry). Rebuilt as `planLabelsForLocale()`, called fresh inside `loadBillingPanel()` on every invocation. Also switched its plan-name wording from a `Medium`/`Large` naming this one panel invented on its own to the same `pricing.*.name` keys ("Standard"/"Premium") the pricing page, admin panel, and everywhere else in the app already use — one name per tier, not two.
- `loadDirectoryPeople()`/`renderDirectoryTable()` — the People/Directory admin table: role tags (Owner/Staff/Member/Event sign-up/Group sign-up), "Loading directory...", "No one matches this filter."
- `loadRoomsPanel()` / `loadFundsPanel()` — "No rooms added yet." / "No designated funds yet — everything goes to the General Fund.", plus their row "Remove" aria-labels.
- `loadCheckinEventPicker()` / `renderCheckinTable()` / `loadCheckinList()` — the "Select an event..." dropdown placeholder (a *static* `data-i18n` version of this exact string already existed elsewhere in the HTML — this was the one JS-rebuilt copy that never got the same treatment), "Walk-in"/"Volunteer"/"Participant" row tags, "No one matches that search."/"No one has registered for this event yet.", "Loading...".
- `loadDashboardGroups()` — beyond its already-translated tooltips: "Couldn't load groups:", the pluralized "N group(s)" count label, "No groups yet...", the "On"/"Off" contact-visibility tag, the "N pending" badge, and its own copy of the `myChurch` guard message below (missed on the first pass through this function — caught by a follow-up grep for the literal string across the whole file, not assumed fixed).

**One string was duplicated across four different panels** (`loadDashboardEvents`, `loadGivingHistoryPanel`, `loadDirectoryPeople`, `loadDashboardGroups`) — "Register a church first, or ask an owner to add you as staff." — consolidated into one shared `dashHeader.registerChurchFirst` key instead of four separate near-identical ones. Reused several other existing keys where the exact wording already matched rather than creating duplicates: `dashDir.loadingDirectory`, `dashSettings.ownerRoleLabel`, `dashDir.staff`, `dashGroups.roleMember`, `myEvents.volunteer`/`myEvents.participant`, `common.loading`, and the existing static `dashCheckin.selectEvent` key.

**All of these were also added to the toggle dispatcher** (`loadGivingStatus`, `loadBillingPanel`, `loadDirectoryPeople`, `loadRoomsPanel`, `loadFundsPanel`, `loadCheckinEventPicker`, alongside `loadTeamPanel`/`loadDashboardGroups` from the first bug class) — fixing the hardcoded strings alone wasn't enough on its own; without dispatcher wiring an already-open panel would only pick up the fix on next load, not immediately on toggle, same lesson as the Plans tab.

**Verified, not assumed:** wrote a script to extract every key from both the `en` and `es` dictionary blocks and diff them — 1,467 keys each side, zero mismatches either direction. Live-checked all 35 new/reused keys resolve to real translated text (not a fallback to the raw key name) in both languages. Re-grepped the whole file afterward for every literal string that got replaced, specifically to catch a duplicate occurrence in a spot the first pass missed — which it did (`loadDashboardGroups`'s own `myChurch` guard, colspan="5", still had the raw string after the rest of that same function was already fixed) — fixed once actually found, not assumed clean from the first pass.

**Confirmed NOT part of this pass, intentionally:** every other place `aria-label="Remove ..."` appears in JS-built strings (remove-contact, remove-question, remove-tag, remove-exception-date, remove-staff, remove-membership, remove-household, remove-member — a wider tail than just the two fixed here) is also hardcoded English. Left alone this round since aria-labels are invisible to sighted users (screen-reader-only), a different severity than the visibly-broken panels above — worth a dedicated follow-up pass, not mixed into this one.

---

## The flagged aria-label tail, closed out

Follow-up pass on the "wider tail of hardcoded `aria-label="Remove ..."` strings" flagged (not fixed) above. All screen-reader-only text — invisible to sighted users, but real accessibility content that was silently staying English regardless of the site's language toggle.

**Fixed, one `window.t()` key each, reusing an existing key wherever the wording already matched something else in the app:** `renderCeContacts()` (Remove contact), `questionsListHtml()`/`renderCeQuestions()` (Remove question), `renderCeTags()` (Remove tag), `renderCeExceptions()`/`renderGroupExceptions()` (Remove exception date — one shared key, since both create-event's own recurring exceptions and a group's meeting exceptions use the identical label), `loadTeamPanel()` (Remove from team), `loadRecentlyJoinedPanel()` (Remove from church), `loadHouseholdsPanel()` (Remove household).

**Found while in there, not part of the original flag but the same bug in the same function — fixed anyway rather than leaving half a modal translated:** `loadGroupMembersModal()` had four *more* hardcoded aria-labels sitting right next to the one flagged "Remove" button — Approve, Deny, Demote to member, Promote to leader. All five closed together (`groupMembers.approve/deny/demoteToMember/promoteToLeader/remove`).

**Also fixed, found by the same grep sweep:** the message-composer's "Remove link" rich-text button (`msg-body`'s unlink control) was missing the `data-i18n-title` attribute its identical twin on the event-description editor already has — the only one of the five static Remove/unlink buttons in the whole file without it. `data-i18n-title` sets both `title` *and* `aria-label` from one key (confirmed by reading `applyTranslations()`), so the other four (photo/logo/image remove buttons, the description-field unlink) were already correct and didn't need touching.

**`renderCeExceptions()` had a second, separate gap:** it wasn't exposed on `window` at all, so even after fixing its own aria-label text it still couldn't be added to the create-event language-toggle dispatcher the way `renderCeContacts`/`renderCeQuestions`/`renderCeTags` already were. Exposed it and added the dispatcher entry — matches the other three exactly now.

**While auditing the dashboard dispatcher for these fixes, found two more always-loaded panels missing from it entirely** (same class of bug as `loadTeamPanel`/`loadDashboardGroups` from the previous pass, not the aria-label bug) — `loadRecentlyJoinedPanel()` and `loadHouseholdsPanel()`, both under the Directory's "housekeeping" section. Added both.

**Verified:** en/es key-parity script re-run (1,479 keys each side, zero mismatches — 12 new keys added on both sides). Live-checked all 12 new/reused keys resolve to real text in both languages. Grepped the whole file afterward for every literal aria-label string that got replaced — zero remaining.

**Confirmed intentionally out of scope, still:** general (non-"Remove") aria-labels scattered across the site that were never wired to any `data-i18n`/`data-i18n-title` at all — "Toggle dark mode", "Menu", "Search location", the social-share buttons, etc. Those aren't a toggle-refresh bug like everything above (they were never translated to begin with, in either direction), and are a distinctly separate, much larger a11y-copy audit — not part of what was flagged or asked for here.

---

## The rest of the aria-label audit: everything non-"Remove" too

Asked directly to close out the broader tail flagged above. Read every `aria-label="..."` in the file (~80 of them) and classified each as either already correctly wired (`data-i18n-title` on a static element, or `window.t()` inside a JS-built one) or genuinely hardcoded — closed every one of the latter.

**The single biggest cluster: 21 identical modal close buttons.** Every `<button class="modal-close" ...>×</button>` across the whole file used the literal `aria-label="Close"` with no i18n hook at all. Added one `common.close` key and applied it to all 21 via a single scoped find-and-replace on the exact `aria-label="Close">` substring (verified first that all 21 occurrences were byte-identical and none needed different treatment) rather than 21 near-duplicate manual edits.

**Static elements, one `data-i18n-title` each:** the dark-mode toggle (`common.toggleDarkMode`), the mobile hamburger menu (`common.menu`), both directory/events location-search buttons (`common.searchLocation`, reused across both — identical meaning, identical button), the events-calendar prev/next-month buttons (`common.previousMonth`/`common.nextMonth`), and all five event-share buttons (Facebook/X/Instagram/email/copy-link — new `events.*` keys, reusing the `events.` prefix already established for `events.shareQrCode`).

**The message composer's rich-text toolbar was the other static gap:** its Bold/Italic/Numbered-list/Bulleted-list/Add-link buttons had zero `data-i18n-title` at all (only its Remove-link button had one, fixed in the previous pass) — its identical twin on the event-description editor already had all five wired correctly. Reused the same existing `rte.*` keys rather than duplicating them for a second toolbar instance.

**JS-built, found while doing the full read-through, not part of the original "Remove" list:** `loadTeamPanel()`'s "Cancel invite" button (plus its neighboring "Pending" status tag — reused the existing `admin.pending` key rather than adding a duplicate), `loadDashboardGroups()`'s "View members" button, and `loadScheduledMessages()`'s "Cancel" button on each scheduled message — which turned up a real hardcoded-content bug too, not just an aria-label one: "Nothing scheduled right now." was plain English with no `window.t()` at all. Fixed both in the same pass, and added `loadScheduledMessages()` to the toggle dispatcher (it was already exposed on `window` but missing from the list, same gap as the two dashboard panels found in the previous pass).

**Verified:** re-ran the en/es key-parity script (1,494 keys each side, zero mismatches — 15 new keys). Live-checked all 15 resolve to real text in both languages, and confirmed via a real toggle click that `aria-label` *and* `title` update immediately on four representative static elements (theme toggle, hamburger, location search, calendar nav) with no refresh. Grepped every remaining `aria-label="..."` in the file afterward and confirmed each one now has either `data-i18n-title` or a `window.t()` call — zero hardcoded strings left anywhere in the file.

---

## New feature: coming-soon waitlist banner + landing page + admin view

Requested: a closable site-wide banner ("FaithDock is coming soon...") that links to a standalone email-signup page with promotional copy, meant to also be linked to directly for outreach — plus a way to actually see/use the collected emails.

**Banner** (`#waitlist-banner`, first element in `<body>`, above the sticky nav so it scrolls away independently): gold bar, `data-route="waitlist"` so the existing global `[data-route]` click delegate handles navigation with no extra JS — clicking anywhere on it except the close button routes to `#waitlist`. Dismissal is `localStorage`-backed (`fd-waitlist-banner-dismissed`), same durable-per-browser pattern the theme toggle already uses, so it doesn't reappear once closed. The close button is explicitly excluded from the `[data-route]` delegate's own click handling (same exclusion pattern already used for `.qr-btn` etc.) so dismissing it doesn't also navigate.

**Landing page** (`#page-waitlist`, standalone — written to stand on its own for someone arriving via a direct link, not assuming they saw the banner): reuses the home page's `.hero`/`.search-bar` treatment for visual consistency rather than inventing new styling, plus a 3-card "why join early" section using the existing `.side-note`/`.grid` classes. Promotional copy covers what was asked: showcasing events and studies to the community, and helping people find their church home through the directory/events/groups. Submits to a new `waitlist_signups` table; a Postgres unique-violation (duplicate email) is caught and shown as a friendly "you're already on the list" message rather than a raw error.

**Database, same hardening pattern as everything else this session:** `waitlist_signups` (migration handed to the user) — RLS enabled, anonymous `INSERT` allowed (the whole point of a public signup form) but scoped to just `(email, source)` columns, `SELECT` revoked entirely from `anon`/`authenticated`. The only way to see the actual list is `get_waitlist_signups()`, a new RPC gated on `is_platform_admin()` exactly like every other admin-only RPC in this codebase — nobody, not even a signed-in non-admin, can read raw signups off the table directly.

**Admin panel:** new "Waitlist signups" section, following the existing `loadAdminXList()` pattern — deliberately *not* paginated like the churches/claims/users lists below it (the RPC just returns everything), since the admin's actual stated need was "email this group," not paging through a UI. A "Copy all emails" button (`navigator.clipboard`) puts the full comma-separated list on the clipboard for pasting straight into an email tool.

**Sequencing note, same as the profiles-hardening commit earlier this session:** the admin panel's `get_waitlist_signups()` call and the signup form's `waitlist_signups` insert both need the migration to have already run — pushing before that would show a live "table not found" error to a real visitor who clicked through, on a page explicitly meant to be shared for outreach. Migration needs to run before this reaches production.

**Verified:** en/es key parity (1,517 keys, zero mismatches — 23 new keys). Confirmed live: banner renders and dismisses correctly (with the dismissal surviving a reload), clicking it navigates to `#waitlist` without also triggering on the close button, both banner and page text switch fully to Spanish on toggle, and the signup form correctly reaches Supabase (confirmed via the expected "table not found" error, proving the request path itself is wired right — it'll succeed the same way once the migration runs).

---

## The churches column-grant fix broke live directory search — `search_churches` needed `c.*` replaced too

Reported live, with a screenshot: the Churches directory ("San Antonio" keyword search) failed outright with "permission denied for table churches" for every visitor. A real regression from the `churches` column-lockdown earlier this session (the corrected `stripe_customer_id`/`stripe_subscription_id` fix), only now surfacing.

**Root cause:** `search_churches`'s `bounded` CTE did `select c.*` — every column on `churches`, including the two Stripe billing ids just locked down — even though the function's own final `SELECT` only ever returns a small, already-public subset. This function runs `SECURITY INVOKER` (confirmed in the Supabase dashboard, not assumed) — the caller's own privileges apply, not an elevated set — so it's bound by the exact same column grant as any direct client query. Postgres checks column-level privilege for *every column a query touches*, including ones pulled in by `c.*` and immediately discarded downstream — it doesn't matter that the final output never includes them. The earlier column-lockdown work was verified against every *client-side* `.select(...)` call in the repo (all of which were fine), but had no visibility into what an opaque, invoker-mode RPC touches internally — this was exactly the kind of gap that review couldn't have caught without the function's actual source, which wasn't requested at the time.

**Fix:** got `search_churches`'s real source from the user (same established pattern as every other opaque-function fix this session — never guessed at it), and replaced `c.*` with an explicit list of the exact columns the function's own WHERE/distance-calc/output logic actually uses — never touching `stripe_customer_id`/`stripe_subscription_id` at all. Zero behavior change otherwise: identical filtering, sorting, pagination, output shape. This closes the gap correctly rather than reopening the churches grant to work around it.

**Checked `search_events` for the identical risk proactively, since it also joins `churches`** — got its source too. Clean: its join only ever selects `c.id, c.name, c.plan_type, c.lat, c.lng`, all already in the public grant, no `c.*` pattern anywhere. No fix needed.

**Verified live, not assumed:** called `search_churches` anonymously directly (no keyword/location filters) — real rows back, no error, confirmed the Stripe fields are genuinely absent from the response (not just unused). Then reproduced the *exact* reported flow end-to-end through the real UI — typed "San Antonio" into the directory keyword search, called `renderDirectory()` — one real card rendered, count text correct, no error banner, screenshot matching what a real visitor would now see instead of the permission error.

**Lesson for next time a table's grants get tightened:** client-side `.select(...)` calls aren't the only thing to check — any `SECURITY INVOKER` RPC that touches the same table needs its actual source read too, specifically checking for `t.*`/`table_alias.*` patterns that pull in more than the function's own output needs. `SECURITY DEFINER` functions are unaffected by table grants entirely (already understood from earlier in the session) — this gap only applies to invoker-mode ones.

---

## Church card fallback text read as a grammatically broken sentence fragment

Reported with a screenshot: a church with no service times set showed "Regular service contact church for times" on its directory card — two half-sentences mashed together, not a real sentence in either language. `formatChurchNextText()`'s fallback branch concatenated two separate keys (`church.nextService` + `church.contactForTimes`) that were only ever meant to combine with a real time value (`"Regular service is at 9:00 AM"`), not with each other. `church.contactForTimes` turned out to be used nowhere else in the file, so rewrote it as a complete standalone sentence ("Contact church for regular service times" / the equivalent full sentence in Spanish) and dropped the `church.nextService` concatenation from the fallback branch entirely. Verified live both directly (`formatChurchNextText(null, 0)` in both languages) and through the real UI — searched "Isis" in the directory, confirmed the actual card now reads correctly.

---

## Create-event page's room checklist stuck on "Loading..." forever after a refresh

Reported: added a room in Settings, but the "Rooms used" checklist on the create-event page stayed on its static "Loading..." placeholder indefinitely — even after refreshing.

Root cause: `loadEventRoomChecklist()` (the function that actually fetches and renders the checklist) was only ever called from two places — the dashboard's "Create event" button click handler (`resetCreateEventForm()`, for a brand-new event) and `editEvent()` (for `#create-event/<id>`, editing an existing one). Landing on plain `#create-event` any *other* way — a refresh, browser back/forward, a bookmark — skipped both entirely, since neither runs on a route being reached directly through the hash. The static "Loading..." placeholder just sat there forever with nothing left to ever replace it.

Fixed by adding a matching case to `showRouteFromHash()` (the function that already handles this exact class of "reached this route directly, not through a button" case for editing — `#create-event/<id>` → `editEvent()`, `#church/<name>` → `populateChurchPage()`, etc.): plain `#create-event` with no id now also calls `loadEventRoomChecklist([], null)` directly. Verified live: before the fix, landing on `#create-event` via a direct hash change left the container's static "Loading..." HTML completely untouched; after the fix, the same navigation actually invokes the function (confirmed by the container changing — it can't be tested end-to-end for a real church's real rooms without a live authenticated session, but the call firing at all was the entire bug).

---

## Description/announcement rich-text boxes weren't resizable

Requested: let people drag-resize the create-event Description box (and, by the same logic, the Messages announcement body — the only other rich-text `contenteditable` field in the app) instead of being stuck with a fixed `max-height` and an internal scrollbar once content outgrows it.

Added `resize: vertical` to the shared `.rte-editable` class (both fields already use it, so one rule covers both) — `resize` requires a non-`visible` `overflow` to take effect, which both fields already had (`overflow-y: auto`), so no other CSS was blocking it. The `resize` CSS property also can't expand an element past its own `max-height`, so raised both fields' `max-height` from their old caps (260px / 340px — enough to make the resize handle nearly pointless) to 700px, giving a real, generous range to drag into rather than a token few dozen pixels.

Verified live: both `#ce-description` and `#msg-body` compute to `resize: vertical` with `overflow-y: auto` and the new `max-height`, confirmed via computed styles on the real elements (this is a pure native-browser feature — no JS involved, so a correct computed style is the complete verification; there's no separate "does the drag actually work" behavior to test beyond that CSS actually applying).

---

## Rich-text "Add link" silently did nothing after clicking OK

Reported with a screenshot: selected a word ("Family") in the event Description, clicked the link toolbar button, typed a URL into the browser's prompt, clicked OK — nothing happened, no link appeared.

Root cause: `prompt()` is a native, blocking, OS-level modal dialog — opening it reliably clears the page's live text selection (confirmed by reproducing it directly: selecting text, clearing the selection the same way a `prompt()` interruption does, then calling `execCommand('createLink', ...)` with nothing selected — it silently no-ops, exactly matching the report). Bold/Italic/lists never hit this because they run `execCommand` synchronously in the same click handler with no dialog in between; only the link command opens a prompt.

Fixed by saving the exact selection `Range` right before calling `prompt()`, then explicitly restoring that saved range immediately after the user clicks OK — right before `execCommand('createLink', ...)` runs — regardless of what the browser did to the live selection while the dialog was open.

**Verified live, both the failure and the fix, not assumed:** reproduced the exact bug directly (select "Family", clear the selection the way a real prompt() does, call `execCommand('createLink', ...)` — confirmed zero effect, no `<a>` tag, text unchanged) — then ran the actual fixed code path (save the range, clear it the same way, restore it, call `execCommand`) — confirmed `Family` now correctly wrapped in `<a href="...">`.

---

## "Select all" / "Uncheck all" for create-event Categories and "Who is this for?"

Requested directly, with a screenshot of the audience checklist. Added the same "Select all"/"Uncheck all" pair already used on the directory/events denomination filter — same styling, and reused the existing `filters.selectAll`/`filters.uncheckAll` keys rather than adding duplicates. Simpler wiring than the denomination version: these are plain form checkboxes with no dependent re-render to trigger (the denomination filter's buttons also re-run `renderDirectory()` after toggling; these two just set `.checked` on every `.ce-category`/`.ce-audience` box). Verified live: clicking each of the four buttons produces the exact expected checked/unchecked state across both full checkbox groups.

---

## Event contact "Notify" now actually sends an email — and a real pre-existing gap found along the way

Requested directly: the event-contact "Notify" checkbox was already saved to the database but explicitly documented in its own hint text as not sending anything ("that's a separate feature not built yet"). Built the actual send.

**Only notifies genuinely new contacts, not on every re-save.** A new `ceOriginalContacts` snapshot captures what was actually saved before this edit started (`[]` for a brand-new event, the event's real saved contacts when editing one) — at save time, a contact only gets emailed if they're either not in that snapshot at all, or were in it with `notify` still unchecked. Re-saving an event whose contacts and notify state haven't changed never re-sends anything. Best-effort, fire-and-forget from the caller's perspective (matches the `ownership_handoff` pattern already in this file) — the event save itself never depends on or waits on the notification email.

**Needed a new email template in the `smooth-action` edge function**, which lives outside this repo — same process as the Stripe functions earlier this session: got the current full source from the user, added the new `event_contact_notify` type (personalized per-recipient, batched the same way `mass_email` already batches), and handed back the complete file to redeploy.

**Found a real, separate, pre-existing bug while reading that source, not part of what was asked — fixed anyway since it's the exact same failure shape the user had just found and fixed for `ownership_handoff`:** the `member_invite` type (the "Import congregation members" bulk CSV import, and each row's individual "Resend invite" button) had **no matching branch at all** in the consolidated function. Every one of those calls was silently falling through to the default staff-invite branch, which destructures a completely different body shape (a single `email` field, not the `recipients` array `member_invite` actually sends) — so `email` was always `undefined`, and Resend would have rejected every one of these as an invalid recipient. Added the missing branch, personalized per recipient like the new contact-notify type.

**Verified live, thoroughly, after a testing detour:** hit a confusing false negative first — calling the real (already-redeployed) `smooth-action` endpoint directly with a `to: 'faithdock-test-verification@example.com'` address failed with a Resend `validation_error` about test/fake domains, which turned out to be Resend correctly rejecting the address, not a bug — switching to Resend's real sandbox test address (`delivered@resend.dev`) confirmed both `event_contact_notify` and the fixed `member_invite` genuinely work end-to-end. Separately, mocking `supabase.functions.invoke` (and even `window.fetch`) from the browser console to verify the dedup logic kept silently failing to intercept anything — traced to the Supabase client having already captured its own internal reference at load time, not a bug in the actual code — worked around it with a temporary debug return value (removed before commit) that directly reported whether the function decided to send, then confirmed all three real cases correctly: an already-notified contact is skipped, a contact whose Notify box was newly checked is sent, and an unchecked contact is always skipped.

---

## Three create-event polish fixes, reported together

**"Use my church's address" only filled the address, not Venue name.** The checkbox's own label says "address," but a church's own *name* is exactly what belongs in Venue name, and that handler is the one place that already knows it. Now fetches `name` alongside `address` and fills both, disabling Venue name the same way Location already was; unchecking clears and re-enables both.

**The rich-text Description/announcement box never actually had a border, in either theme.** Reported as "the border disappears in dark mode," but checking the real computed style live turned up something more basic: `border: 0px none` in both themes. The div only carries `class="field rte-editable"`, and the site's `.field` CSS rule is scoped to `input.field, textarea.field` — it was never selecting this plain `<div>` at all, in light mode or dark. Whatever visible edge showed up in light mode was incidental (its sibling toolbar's own border, or a browser focus ring), not this element's own style. Gave `.rte-editable` an explicit `border`/`background`/`padding` using the same `var(--line)`/`var(--card)` tokens `.field` inputs already use, so it now has a real, theme-correct border in both modes rather than accidentally none in either.

**Links had no visual indication they were links, and re-opening "Add link" on already-linked text always showed a blank prompt with no way to see or edit the existing URL.** Added `.rte-editable a{color:var(--gold);text-decoration:underline;cursor:pointer;}` so an inserted link is now visibly distinct from plain text. For the edit case: before opening the URL prompt, the click handler now checks whether the saved selection's `commonAncestorContainer` sits inside an `<a>` that's actually a descendant of the field (not some unrelated link elsewhere in the DOM) — if so, the prompt opens pre-filled with that link's current `href`, and confirming updates that same anchor's `href` directly (`setAttribute`) instead of running `createLink` again, which would have tried (and likely failed or behaved oddly) against a selection that may no longer exactly match the original link's boundaries.

**Verified live:** the border/background compute correctly (theme-appropriate colors) in both light and dark; a real inserted `<a>` renders gold/underlined/pointer-cursor; placing the selection inside that link correctly detects it and reads back its exact `href`; the no-existing-link path still creates a fresh link correctly (regression-checked against the exact "Family" scenario from the previous link fix); and the church-address checkbox correctly disables/fills (and un-disables/clears) both Venue name and Location together with no exceptions.

---

## "Posts under the church you registered while signed in." — reworked, and the bigger multi-church question deferred on purpose

Flagged as confusing for a single-church account (redundant, since you're already signed in as that church) — but the user's own follow-up made clear the real issue is bigger: for a multi-church owner, this line doesn't actually say *which* church the event posts under, and that's the tip of a much larger question (staff scoped to specific churches, a church picker on create-event, church-scoped tags/rooms). Asked directly which scope to build now; the answer was the minimal fix only — rework this one line, write the rest up as a plan, no schema or permission changes yet.

**What shipped:** the static line is now `window.t('ce.postsUnderChurchName')` ("Posts under {church}.") filled in dynamically via `getMyChurch()` — re-fetched fresh every time rather than cached, so it can't go stale if the active church is switched elsewhere (relevant today too: an owner of multiple churches already has a working dashboard church-switcher). Wired into every place the create-event page's dynamic content already gets (re)rendered: `resetCreateEventForm()` (new event), `editEvent()` (editing one), the direct-`#create-event`-landing case fixed earlier this session (refresh/back/bookmark), and the language-toggle dispatcher. Verified live: both languages render the church name correctly substituted into the sentence; the no-church fallback renders empty rather than a confusing message.

**What's deliberately NOT built yet — documented here as the hand-off spec for when it's actually prioritized:**

Current state, confirmed by reading the code (not assumed): an owner can already own up to 5 churches (Multi-Church plan) with a working dashboard church-switcher (`ownedChurches`, `#dash-church-switcher`). **Staff, however, are modeled as belonging to exactly one church** — `church_staff` is queried with `.eq('user_id', userId).limit(1)` wherever a user's staff role is resolved (`getMyChurchUncached`, the account-access checks in `updateAuthUI`/`routeAfterLogin`), meaning there's no way today to grant one staff account access to more than one specific church, or to a subset of a multi-church owner's churches.

Full scope, as described:
1. **`church_staff` needs to support one user having access to multiple specific churches**, not just one row per user. This is a real schema change (today's `.limit(1)` pattern assumes a single row and would need to become a real per-church-membership list everywhere it's read), plus every permission check downstream (`canManageEvents`, `canManageGiving`, `canManageBilling`, `canEditProfile`) needs to become per-(user, church) instead of per-user.
2. **An admin UI for assigning staff to specific churches** — today's "Add staff by email" (Settings → Team) has no concept of "which of my churches" to grant since an owner's own single active church is implicit; a multi-church owner needs to pick which owned church(es) a staff invite applies to.
3. **A church selector on create-event** — a dropdown at the top, shown only when the signed-in user has access to more than one church (owner of several, or staff granted more than one under the new model), replacing the single implicit "active church" this page currently always uses. Everything the page currently scopes to `myChurch`/`myChurches[0]` (the event's `church_id`, room checklist, tag suggestions, the church-address autofill this session's other fix touched) needs to follow whatever's selected in that dropdown instead.
4. **Tags and rooms are already church-scoped at the query level, confirmed by reading both** — rooms (`church_rooms.church_id`, filtered in `loadRoomsPanel()`/`loadEventRoomChecklist()`) and tag suggestions (`loadChurchTagSuggestions()` filters `events.tags` by `.eq('church_id', myChurch.id)`, not all events platform-wide). Neither needs new scoping logic — both already only ever look at `myChurch.id`. The actual gap is (3) above: `myChurch` itself is always whatever the dashboard's single "active church" happens to be, not whatever's chosen for *this* event, so once a real per-event church selector exists, these two just need to read from it instead of the implicit active church — no new filtering to write.

---

## Multi-church staff support — built, and turned out to need no migration at all

This is the full picture deferred above, now built. The first item on that list ("a real schema change") turned out to be **wrong** once actually checked — worth recording exactly how, since it changed the whole shape of the work: asked the user to run `select conname, contype, pg_get_constraintdef(oid) from pg_constraint where conrelid = 'church_staff'::regclass;` live, which came back with `UNIQUE (church_id, user_id)`, not `UNIQUE (user_id)`. The database has always fully allowed one person staffing several churches — the `.limit(1)` in `getMyChurch()`'s staff branch was a purely client-side restriction with nothing backing it up. Confirmed via plan mode's own research pass, not assumed: `loadMyChurches()` already queries `church_staff` with no `.limit(1)` at all and already correctly lists every church a user staffs — this whole feature only needed `getMyChurch()` (the function everything else actually reads from) to catch up to that.

**The core fix reuses a mechanism that already fully existed for multi-church owners**, unchanged: `getActiveChurchId()`/`setActiveChurchId()` (`localStorage`-backed), the self-correcting resolution logic already in `getMyChurch()`'s owner branch, `setActiveChurchAndReload()`, and the dashboard's `#dash-church-switcher`. `getMyChurchUncached()`'s staff branch now drops `.limit(1)`, fetches every `church_staff` row for the user, and mirrors the owner branch's active-church selection exactly — plus a new `staffedChurches` array (parallel to `ownedChurches`) carrying each staffed church's *own* permission flags, since those can differ per church for the same person. The dashboard switcher and the My Churches "Manage" button (previously gated to owned churches only) both now also show for a staff member with access to more than one.

**Create-event gets its own picker instead of reusing `setActiveChurchAndReload()`** — that function's full-page reload would destroy an in-progress title/description, so this page needed a lighter approach: a new `<select id="ce-church-picker">`, hidden whenever there's only one church available, backed by a local `ceSelectedChurchId` that changes without navigating away. Its `change` handler re-runs the room checklist and tag suggestions for the newly-picked church (both functions gained an optional trailing `churchId` param for this — `loadEventRoomChecklist(selectedRoomIds, primaryRoomId, churchId)`, `loadChurchTagSuggestions(churchId)` — falling back to `getMyChurch()`'s active church when omitted, so every pre-existing call site keeps working unchanged) and re-fills the address/venue-name fields if "Use my church's address" is currently checked. Editing an existing event defaults the picker to *that event's own* `church_id`, not necessarily the dashboard's current active church — those can genuinely differ if the active church was switched since the event was created. The update path previously never set `church_id` on save at all (an edit couldn't move an event to a different church even by accident) — now it does, so changing the picker while editing actually applies.

**A permission detail worth being explicit about:** an owner's `canManageEvents` is unconditionally `true` for every church they own, but a staff member's can genuinely differ per church (each `staffedChurches` entry carries its own flags). The picker's available-churches list is filtered to `can_manage_events !== false` — a no-op for owner entries (they have no such property, so the check passes), but it keeps a multi-church staff member from ever being offered a church in the dropdown they don't actually have event-creation permission for, and the submit handler re-derives the same filtered list rather than trusting whatever `ceSelectedChurchId` happens to hold, so a stale value can't silently post to an unpermitted church either.

**Team panel: one invite, several churches at once.** "Add staff by email" now shows a checkbox list of the owner's own churches — but only when they actually have more than one, same progressive-disclosure pattern as the picker above, invisible for the common single-church case. The single-church insert-and-email logic was extracted into `inviteStaffToOneChurch()` unchanged in behavior, and the click handler loops it once per checked church (defaulting to just the active one when nothing's checked, reproducing the exact original single-church behavior byte-for-byte). Results are aggregated into one status line — a single-church invite still reads exactly like the original single-outcome message; a multi-church one lists which churches succeeded and names any that failed (already-on-team, at their staff limit, etc.) individually, since `UNIQUE (church_id, user_id)` means one of several checked churches can fail without affecting the others.

**Verified live, within the real limits of not having a real multi-church test account:** the single-church ("no picker, no checkboxes") path was regression-tested end-to-end against the real backend — picker stays hidden, "Posts under" text and address-fill behave exactly as before. The actual multi-church selection/filtering algorithm (available-church list construction, active-church matching and fallback, the `can_manage_events` filter, the picker's HTML-building including proper `<` escaping) and the team-invite target-resolution/result-aggregation logic were both verified by replicating the exact code in the browser console against crafted multi-church data — confirmed correct for: an owner defaulting to their active church, a staff member with one church correctly excluded by permission, an explicit picker change overriding any prior selection, a language-toggle-style re-render preserving an existing selection instead of resetting it, the single-church fallback list, and every team-invite outcome combination (all-succeeded, mixed success/failure, and the single-church case reading identically to the pre-existing single-outcome message). `getMyChurch()`'s new staff-branch query (no `.limit(1)`, joined `churches` columns) was confirmed to run without a query-shape error live. What couldn't be verified end-to-end without a real second church and a real staffed account: the actual DOM rendering of a populated multi-option picker, and a real round-trip invite landing two genuine `church_staff` rows for the same person. Worth a real click-through once there's a live multi-church account to test with.

---

## Supabase-side source now backed up in the repo (`supabase/`)

Every piece of Supabase-side infrastructure touched this session — every Edge Function and RPC/RLS/migration SQL statement — has, up to this point, existed **only** in the Supabase dashboard. This file records the *reasoning* behind each fix, but not verbatim current source; a brand-new chat session had no way to see any of it without the user re-pasting it, which is exactly the friction that kept coming up whenever an already-fixed function needed touching again (the `search_churches` outage, the ambiguous-`id` re-fix, and the profiles hardening superseding an earlier partial fix all involved re-deriving or re-requesting source that had already been produced once before).

Added a real, git-tracked backup: `supabase/README.md` (what this is, how to keep it in sync, and an explicit list of what's still *not* covered), `supabase/functions/smooth-action.ts` (the one Edge Function whose current source is actually available — confirmed deployed and working), and `supabase/migrations/001` through `014` — every SQL statement gathered this session, numbered in the order it was run, including the two files marked `SUPERSEDED`/`FAILED_ATTEMPT` (the column-level-revoke attempt on `churches.stripe_*` that didn't actually work, and the earlier partial `profiles.is_platform_admin` revoke that `harden-profiles-table` fully superseded) — kept rather than deleted, since they're real history of what shipped first and why it changed.

**Deliberately not fabricated:** the Stripe-related Edge Functions (`stripe-subscription`, `stripe-subscription-webhook`, `stripe-connect-onboarding`, `stripe-create-checkout`, `stripe-event-checkout`), `delete-account`, `ai-writing-assist`, and a handful of RPCs referenced by name but never pasted in full (`is_platform_admin()`, `update_profile_name()`, `get_directory_people()`, `find_church_people_by_email()`, `get_mass_email_recipients()`, `is_church_staff_member()`) are **not** in this backup — `supabase/README.md` lists them explicitly as "source not available" rather than guessing at their bodies, matching this project's standing rule of never inventing an opaque Supabase-side implementation. Also added a persistent cross-session memory note (`supabase-infrastructure-map`) pointing at this backup, so a future session's first move on anything Supabase-side is to read `supabase/README.md` rather than ask the user to re-paste source that's already sitting in the repo.

No client-side code changed as part of this — it's a pure repo-organization/documentation task, so no build-stamp bump.

---

## Two "requires a one-time SQL migration" notes that never actually ran

Publishing any event started failing live with `Could not find the 'suggested_donation_cents' column of 'events' in the schema cache`. Root cause wasn't a code bug — it was that two earlier features each shipped their client code with a **"Requires a one-time SQL migration"** note in this file but the SQL was never run against the live database and never captured under `supabase/migrations/`:

- "Suggested donations for free events" → `events.suggested_donation_cents`
- "New pricing model / pass-absorb fee choice" → `events.fee_mode`

The create/edit-event form unconditionally sends **both** columns in its insert and update payloads (`suggestedDonationCents`, `feeMode`), so every publish/save failed at PostgREST before reaching the table. PostgREST names only the first unknown column it hits (`suggested_donation_cents`), which made it look like a one-column problem — `fee_mode` was missing too.

Fix is `supabase/migrations/015_events_suggested_donation_and_fee_mode.sql` — run by hand in the Supabase SQL Editor (no migration runner in this project). Written idempotently: `add column if not exists` for both, `pg_constraint`-guarded `add constraint` for the two check constraints from the original notes, and a trailing `notify pgrst, 'reload schema'` so PostgREST picks the columns up immediately instead of on its next periodic cache refresh. Existing rows get `fee_mode = 'pass'` and `suggested_donation_cents = NULL`, both of which the client already handles.

**Lesson for next time:** a "requires a one-time SQL migration" note in this file is not evidence the migration ran. Anything Supabase-side now belongs in `supabase/migrations/` as a numbered file in the same commit as the client change, per `supabase/README.md`.

---

## "No signup needed" events still showed Register / participant-volunteer radios

QA: a published event with registration **not** required still rendered "Register as a participant" / "Register as a volunteer" radios on its detail page (the Register button itself was already correctly hidden, so the radios just sat there attached to nothing).

Two independent spots, both keyed only on `allowVolunteers` and never on whether registration is even required:

- `populateEventPage()` — the role-choice block (`#event-role-choice`) showed whenever `e.real && e.allowVolunteers`. Now also gated on `!regNotRequired`, and a new `#event-no-registration-note` (`events.registrationNotRequired` i18n key, EN + ES) shows in its place. `regNotRequired` uses `!e.registrationRequired` to match the "No signup needed" badge's own truthiness check for legacy rows where the column could be null.
- `eventCard()` — the public Events grid had the same bug (button + radios on a no-signup card). Same treatment: for `!e.registrationRequired` real events it emits just the note, no button, no radios.

**The re-show trap:** `checkEventRegistrationStatus()` runs right after `populateEventPage()` on every event-page load and, when not registered, calls `setEventRegisteredUI(btn, false)` which unconditionally does `choiceEl.style.display = 'block'` — that would have undone the fix a beat later. Guarded it with an early `if (btn.style.display === 'none') return;` (the button is exactly what `populateEventPage` hides for these events), which also skips a pointless `event_registrations` query. `checkEventCapacity()` needs no guard — it only writes into hidden count spans and is already call-site-gated on `allowVolunteers`.

Verified live against the local static server + real backend: no-signup event (detail + card) shows the note; a registration-required event (`Ritual of Isis`, with a full participant cap) still renders the complete participant/volunteer/Register UI unchanged. Build stamp bumped to `2026-09-09-v253`.

---

## A Premium owner still got bounced to /pricing when adding a 2nd church

QA: subscribed a church to Premium, then "Add a church" from the Profile page still redirected to Pricing — even though Premium's own pricing copy says "Up to 5 churches" (`pricing.large.churchCap`).

Not a client bug. `get_my_plan_and_usage()` (the RPC the "Add a church" gate calls — [index.html:6195](index.html) and again in `checkExistingChurch`'s `routeKey === 'new'` branch) was broken by **two layers of drift**, found by pasting its source and the `plan_tiers` table contents out of the dashboard:

1. **It resolved the caller's plan from `profiles.plan_type` — a column nothing maintains.** The entire Stripe subscription system (`stripe-subscription-webhook`, [see above](#connecting-the-tierpricing-page-to-stripe-sandbox--stripe-subscription-handed-off)) writes **`churches.plan_type`** as the source of truth, and it was correct (`premium`). The owner's `profiles` row was still `free` and always would be — so the account had Free limits (`max_churches = 1`) everywhere the RPC is read.
2. **`plan_tiers` had drifted to an older tier naming** — `free / starter / growth / multi_church / enterprise` — with **no `standard` or `premium` row at all**, i.e. the names the live `churches.plan_type` CHECK constraint and the whole client actually use. So even the "5" had nowhere to live.

Fix is `supabase/migrations/016_plan_from_owned_churches.sql`, **no Edge Function change** (`churches.plan_type` is already right):
- Adds `standard` + `premium` rows to `plan_tiers` (`premium.max_churches = 5`), purely additive — legacy `growth`/`enterprise` rows left untouched in case anything still references them. `multi_church.max_churches` set to `NULL` (unlimited) per product decision.
- Rewrites `get_my_plan_and_usage()` to derive the plan from the **churches the caller owns** — highest tier among them (`multi_church > premium > standard > starter > free`) — dropping the `profiles.plan_type` + stale-`plan_tiers`-name dependency. Matches how the rest of the app already reasons about plan (`myChurch.planType` → the client's hardcoded `planLimits`) and handles a multi-church owner correctly. Only `max_churches` / `churches_owned` are actually consumed by callers; the other returned columns are kept in the signature for compatibility.

**Known remaining drift, deliberately not touched here:** `plan_tiers`' per-tier event/group/staff numbers and `monthly_price_cents` don't all match the client's own pricing copy ($19 card vs `1500` cents, etc.). Nothing reads those fields from this RPC, so a full pricing reconciliation is left for a deliberate pass.

Verified live: after the migration, `get_my_plan_and_usage()` from the owner's browser returns `plan_type: "premium"`, `max_churches: 5`, `churches_owned: 1`, and "Add a church" opens the registration form.

**Then the church insert itself failed: `permission denied for table churches`.** Same root cause as the Stripe-column lockdown ([above](#the-two-sensitive-stripe-columns-on-churches-were-world-readable) / GOTCHAS "select('*') ... now fail with permission denied for table churches"): `authenticated` has **no table-wide SELECT** on `churches` any more, only column-level SELECT on a list that excludes `stripe_customer_id` / `stripe_subscription_id`. The register-church submit handler's two mutation calls — `.insert(payload).select()` and `.update(payload).eq(...).select()` — use a **bare `.select()`, which compiles to `RETURNING *`** and trips on those two columns. They were missed when every *read* switched to `PUBLIC_CHURCH_COLUMNS`. The first church ("Test 2") predated the lockdown, so only the 2nd church exposed it (church editing was broken too, same line). Fix: pass `PUBLIC_CHURCH_COLUMNS` explicitly to both `.select()` calls. Client-only, no migration.

**Known hardening gap, made sharper by migration 016:** `authenticated`'s column-level INSERT/UPDATE grant on `churches` *includes* `plan_type`, and the INSERT RLS policy only checks `auth.uid() = owner_id` — so a crafted REST call can self-assign `plan_type = 'multi_church'`. Pre-016 that bought nothing (the RPC read `profiles.plan_type`); post-016 it derives from `churches.plan_type`, so it would grant unlimited churches. Real fix is a `SECURITY DEFINER` create-church RPC (sets the inherited plan server-side) plus dropping `plan_type` from the client INSERT/UPDATE grants — deferred, not done here.

---

## Multi-church owner: the dashboard's account-level Overview shell

For an owner of **2+ churches** (`getMyChurch().ownedChurches.length > 1` — `role === 'owner'` only; staff-of-several still use the existing `#dash-church-switcher` `<select>`), the Church dashboard grows a two-state shell. This is **commit 2a — navigation plumbing only**; the Overview's aggregate content (staff-per-church, rolled-up totals, per-church quick stats) is a later commit.

**The two states**, both inside the existing `#page-dashboard`:
- **Overview** — a new `.dash-content` panel `#dash-churches` (route `#dashboard/churches`): a `.church-tile` grid of owned churches built from `window._dashOwnedChurches` (which `loadDashboardHeader` copies off the `getMyChurch()` result — that query gained `logo_url, subscription_status`), plus a dashed "Add a church" tile reusing the same `data-add-church` gated flow. Sidebar here is a separate `#dash-nav-overview` block: **Overview · Billing · Plans**.
- **Church selected** — the original per-church nav (`#dash-nav-church`) + a "‹ All churches" link back. Billing/Plans are **removed from this nav** for a multi-owner (via a `.dash-overview-owner` class on `.dash-side` + a `display:none !important` rule — chosen over JS style-toggling so `loadDashboardHeader`'s per-permission `style.display` on the Billing link keeps working untouched for everyone else).

**Key wiring:**
- `updateDashSidebarMode(view)` swaps the two states based on whether `view ∈ {churches, billing, plans}` and `window._dashMultiOwner`. Called at the **end** of `loadDashboardHeader` (after its per-permission toggles) and at the end of `goDash`.
- `loadDashboardHeader` redirects a bare `#dashboard` (no sub-view) to `goDash('churches')` for a multi-owner — so that's the landing. Every other `go('dashboard')` caller that wants a specific view already calls `goDash(...)` right after (checked); church **creation** was the one exception and now explicitly `goDash('events', true)` so a new 2nd church lands in itself, not the grid.
- Billing/Plans from the Overview sidebar go through `enterBilledDashView()`, which resolves the **one** church that actually carries the subscription (`subscription_status` active/trialing/past_due → else first non-`free` `plan_type` → else first owned) via `pickBilledChurchId()` and only reloads if the active church must change. This is why Billing/Plans "don't move" for a multi-church account — churches 2..5 inherit `plan_type` at creation but have no subscription of their own (see the plan-inheritance note above). Cascading a plan *change* across all a multi-owner's churches is still not done — `stripe-subscription` acts per-church.
- The grid is rebuilt from `window.t` at render time, so `applyLang` re-runs `loadDashboardChurchesPanel()` on a language switch while it's the active panel.

Single-church owners and staff see **zero change** — verified in the browser by toggling `_dashMultiOwner` both ways (Billing/Plans stay visible in their nav, no Overview affordances, no `.dash-overview-owner` class). Not yet verified against a real 2-church account — that's the user's live test. Build stamp `2026-09-09-v256`.

---

## Private-testing invite gate on the write side

The site is deployed and fully functional but not open to the public yet. Rather than gate the whole thing, **browsing stays open** (home / directory / events / church / event pages — the waitlist banner is the "not for you yet" signal there) and only the **account-creating surfaces** are gated behind an invite code:

- **`#signup` page** — `showRouteFromHash` opens `#invite-gate-modal` when `base === 'signup'` and the browser isn't unlocked. Backstops: the `#auth-submit-btn` handler and the `#oauth-google-btn` handler both bail to the gate if locked (Google OAuth silently creates accounts for a new email, so it needs the same gate — not just the password form).
- **"Add a church"** — the `data-add-church` click handler gates before its plan check and re-fires the click via the `onUnlock` callback; `checkExistingChurch`'s `routeKey === 'new'` branch gates the direct-URL path (`#register-church/new`). Bare `#register-church` (an existing owner editing their church) is **not** gated.
- **`#dashboard`** is not gated — you can't reach it without a church, and you can't get a church without passing the above.

Mechanics: `window.fdInviteUnlocked()` reads `localStorage['fd-invite-ok']`; `window.openInviteGate(onUnlock)` shows the modal; a valid code (trimmed, lower-cased, checked against the `FD_INVITE_CODES` array near the top of the first `<script>`) sets the flag for good on that browser. **Client-side only** — the code is in page source, so it's a speed bump against casual/accidental signups, not a security boundary. To make it real later: a Supabase `invite_codes` table + a validation RPC called from `fdTryInviteCode()`.

Same commit: `footer.disclaimer` went from "FaithDock prototype — visual concept, not a live product" (false — it takes real signups and Stripe subscriptions) to "FaithDock — private testing" (EN + ES). Build stamp `2026-09-10-v260`.

**Copy pass to match the gated reality (build `v263`).** The banner and `#page-waitlist` still said "coming soon" / "be a first adopter" / "notified when it launches" — a launch framing that contradicts a deployed, invite-gated site with real churches on it. Reframed to **request-access**: banner → "FaithDock is in private testing — invite-only for now. Click here to request access."; `waitlist.eyebrow` "Private testing", `waitlist.headline` "Request access to FaithDock", `waitlist.joinBtn` "Request access", `waitlist.whyHeading` "Why FaithDock". Deliberately avoided "we'll send you an invite when a spot opens" — there's no queue/capacity mechanism; the real flow is an admin reviewing `waitlist_signups` and following up, so `waitlist.thanksJoined` is "Request received — we'll review it and follow up by email." `invite.waitlistLink` (the invite-gate modal's link) → "Request access" to match. `legal.adaLimitations1` "early-stage prototype, not a finished product" → "early-stage product in private testing" (matches the footer + `legal.termsWarranty1`); `legal.privacyFooterNote` and `legal.termsWarranty1` were already accurate and left alone. Dict + inline HTML fallbacks + EN/ES all updated; conference-page "Join the waitlist" buttons left (that page is unreachable and carved out).

**Follow-up commit — the rest of the "looks unfinished" audit** (build `v261`):

- **Bare / stale detail routes showed sample data.** `#church` and `#event` with no id (or an id that matches nothing) fell through to the static page template, which is pre-filled with `churches[0]` / `events[0]` — "Grace Fellowship Church," "Fall Community Picnic," Austin addresses, working-looking Register/Give buttons. `showRouteFromHash` now redirects: keyless-or-unmatched `#church` → `#directory`, `#event` → `#events` (added right after `resolveRouteFromHash`, plus an `else` on the existing `findOrFetch*` blocks). Real deep-links still resolve (verified against a live church).
- **`#app`, `#give` — and then `#conference` + `#compare` (build `v262`) — removed from `validRoutes`.** `#page-app` markets a **mobile app that does not exist** ("Download on the App Store" / "Get it on Google Play" — non-functional `<div>`s); `#page-give` is a **dead** standalone donation page (the real giving flow is a tab on the church page — nothing ever routes to `#give`); `#page-conference` / `#page-compare` are old pages whose nav links were removed long ago but whose sections + route entries were still live, so typing the URL still rendered them (several full of the same unlabeled "Grace Fellowship Church" sample content). All four now resolve to `#home` via the `validRoutes.indexOf(base) === -1` fallback. The dead `#page-*` HTML sections stay in place (unreachable, harmless). Dead `nav.app` and `nav.conference` i18n keys deleted (EN + ES). `pricing.compareLink` left alone (already an unused key, pricing-page carve-out); its stale "still reachable at #compare" HTML comment updated to match.
- **`#church-event-grid` no longer pre-seeded at load** — it was set to `mapJoin(events.filter(church === "Grace Fellowship Church"), eventCard)` on script run, which could flash sample events before `populateChurchPage()` replaced them with the real church's. Now starts `''`.

**Commit 2b — the Overview's actual content.** `loadDashboardChurchesPanel()` became async: it renders the plain grid synchronously (never blank), then fires **one query each** — `events`, `church_memberships`, `donations` (`status='succeeded'`), `church_staff` (`profiles!user_id(full_name)` embed) — all `.in('church_id', <owned ids>)`, and aggregates client-side into a per-church map + grand totals. A `window._dashChurchesGen` counter drops a stale render if the owner navigates away and back before the queries resolve; a query error is swallowed (`.catch`) leaving the plain grid rather than a broken panel. It produces: a rolled-up `.stat-row` (churches / upcoming events / members / giving this month — `#dash-churches-summary`, its own `auto-fit` grid override so 4 tiles sit on one row), a quick-stat line per card (next event date, member count, this-month giving), and a "Staff by church" section (`.overview-staff-card` per church, each staff row = name + short permission chips derived from the `can_manage_*` / `can_edit_profile` flags, or a "no staff" line). All labels via `window.t` at render time (not `data-i18n`), and `applyLang` re-runs the whole function when the panel is active so a language switch re-localises the built markup. "Giving this month" is gross `amount_cents` since the current month start; registrations were left out of the rollup for now (would need an extra `event_registrations` `.in('event_id', ...)` round). Build stamp `2026-09-09-v257`.

**Follow-on, same fix:** the register-church page's eyebrow was a hardcoded "Free listing" — wrong once a paid-plan owner is adding a 2nd–5th church (it inherits their plan) or editing a paid church. Gave it `id="rc-eyebrow"` and a `setRcEyebrow(planType)` helper (in `checkExistingChurch`'s `new` branch, reusing the already-fetched `get_my_plan_and_usage` row; and in the edit branch, from the church row's `plan_type`). Paid → "{Plan} plan" (`rc.planListing`, e.g. "PREMIUM PLAN"), `free`/null → the original "Free listing". Language-switch-safe via `window.rcEyebrowPlan` re-applied in the i18n re-render, same pattern as `rc-heading`. Verified locally incl. EN↔ES toggle. Build stamp `2026-09-09-v254`.

---

## Church status terminology: four public-facing states

Reworked how a church's status reads to visitors. The data has two independent axes — **ownership** (`churches.owner_id` null = unclaimed) and **verification** (`churches.verification_status`, only ever gated donations, a Stripe/KYC check) — plus **plan** (`plan_type`). The UI now presents a single four-rung ladder:

| State | Condition | Label |
|---|---|---|
| Unclaimed | `owner_id IS NULL` | **Directory listing** |
| Claimed, free | `owner_id` set, `plan_type = 'free'`, not verified | **Managed by this church** |
| Claimed, verified | `owner_id` set, `verification_status = 'verified'` | **Verified church** |
| Claimed, paid | `owner_id` set, `plan_type != 'free'` | **FaithDock Partner** |

**Directory cards** (`churchCard()`) now carry one status tag right after the denomination tag, via a new `churchStatusTag(c)` helper (highest applicable rung wins; nothing for non-`real` sample cards). This renders in `#directory-grid` (Directory page) **and** `#home-church-grid` (homepage "Churches near you"). `.tag.neutral` is a new outlined chip style for the two lower rungs; Verified uses `.tag.sage`, Partner `.tag.gold`. Language-switch-safe — `refreshDirectoryCardsText()` / `refreshHomeChurchesText()` already re-run `churchCard()` on the stored rows.

**Church profile page** (`populateChurchPage()`): the states are **not** mutually exclusive here — a claimed church always shows the muted **"Managed by this church"** line (`#church-managed-line`, new); if paid it *also* gets a filled gold **"FaithDock Partner"** badge (`#church-partner-badge`, new); if its giving account is verified it *also* gets the **"Verified church"** badge (`#church-verified-badge`, relabeled from "Verified", now with a `data-i18n-title` tooltip clarifying it's about the connected giving account, not general legitimacy). `#church-unclaimed-banner` reworded ("This is a community directory listing — the church hasn't set it up yet.").

**Dashboard sidebar tag** (`loadDashboardHeader()`): the blanket "PARTNER CHURCH" is gone. Now conditional on the resolved `myChurch.planType` — paid → **"FAITHDOCK PARTNER"**, free → **"MANAGED CHURCH"**. Old `dashHeader.partnerChurch` key deleted (EN + ES); new `dashHeader.faithdockPartner` / `dashHeader.managedChurch`.

**Left untouched, deliberately:** every admin-panel label (Verified / Pending / Rejected / Not verified / Unclaimed) and the `dashGiving.*` verification-gate tags — internal or accurate as-is. `pricing.title` "Become a Partner Church" stays (Partner = paid plan, so it's a coherent CTA).

**Needs `migrations/017`** — `search_churches()` didn't return `plan_type`, so the directory-card **"FaithDock Partner"** rung can't show until that migration runs (pre-migration those churches fall back to "Managed by this church"). 017 is 014's function verbatim + `plan_type` added to the CTE and the `RETURNS TABLE`. `mapSearchRow()` and `findOrFetchChurchByName()` now carry `planType`. Verified locally (helper ladder, all four profile-page state combos, EN↔ES); the Partner rung on cards is the one thing pending the migration. Build stamp `2026-09-10-v265`.

---

## `churches.is_hidden` — keep test churches out of public discovery

Every one of the 5 churches in the live directory is a test/internal entry (Lorem-ipsum descriptions, `test.com` sites, "Test N" names, "Isis" as a denomination, no connected payout account) — there are **zero real churches** yet. Rather than delete them (they're needed for ongoing testing), added a flag.

**`migrations/018`:** `churches.is_hidden boolean not null default false`. A hidden church stays fully usable by its owner (dashboard, My Churches, event creation, direct `#church/<name>` URL) but drops off public discovery.

- `grant select (is_hidden) on churches to anon, authenticated` — `search_churches` is SECURITY INVOKER and its `WHERE` now reads the column (same privilege-model lesson as the `churches.*` / stripe-column lockdown).
- `search_churches` re-created (017's body + `and c.is_hidden = false` in the `bounded` CTE — return shape unchanged, so `create or replace`, no DROP). This covers the **directory grid, homepage "Churches near you", and all church search** in one place.
- `admin_set_church_hidden(target_church_id uuid, hidden boolean)` — SECURITY DEFINER, `is_platform_admin()` gate (a church's normal UPDATE RLS is owner/permitted-staff only, so an admin can't flip this directly), same pattern as `review_church_verification`.
- `update churches set is_hidden = true` on the 5 test ids.

**Client:** the admin "All churches" list (`loadAdminChurchesList`) now pulls `is_hidden` for the page of rows (a small `churches.select('id, is_hidden').in('id', …)` after the RPC — `search_all_churches_admin` doesn't carry it and modifying that RPC's return shape wasn't worth it), shows a "Hidden" tag + dims the row, and renders a **Hide / Show** button next to Un-verify / Delete that calls `admin_set_church_hidden` then `loadAdminPanel()`. New i18n keys `admin.hide` / `admin.show` / `admin.hiddenTag` (EN + ES). Build stamp `2026-09-10-v266`.

**Events side — `migrations/019`.** `search_events` (homepage "Upcoming events" + the Events page) had no repo copy and couldn't be pulled (no Supabase CLI project, no linked config, no connection string; the anon key can't introspect `pg_get_functiondef`). The user pasted its live definition from the dashboard; `019` is that verbatim + one line in the `bounded` CTE's `WHERE`: `and coalesce(c.is_hidden, false) = false` (`coalesce` because the `churches` join is a LEFT JOIN — an orphan event with no church row still passes). Return shape unchanged → `create or replace`, grants preserved. `search_events` runs SECURITY INVOKER, so it reads `is_hidden` under `018`'s `grant select (is_hidden)`. `019` is now the repo's backup of the current `search_events` — the pre-`019` version is just this minus that one line.

---

## Directory: numbered pagination + denomination-tinted placeholders

**Pagination.** The directory was a "Load more" append (24 at a time, everything accumulating in the DOM, no URL state). Now real numbered pages:

- `renderDirectory(n)` renders page `n` (1-based), **grid replaced** each time. `renderDirectory()` with no numeric arg = "a filter changed, snap to page 1" (all the existing filter-change call sites keep working unchanged). Page size stays `DIRECTORY_PAGE_SIZE = 24`.
- URL: `#directory/N` (bare `#directory` = page 1). `directoryPageFromHash()` reads it. `showRouteFromHash` gained a `directory` branch (`renderDirectory(directoryPageFromHash())`) so a bookmark / Back-Forward lands on the right page; `loadRealChurches` seeds the first render from the hash too. **Both are guarded on `window.supabase` being ready** — `showRouteFromHash` runs once from the pre-module plain script before the client exists, and `renderDirectory` also bails early if `!window.supabase`.
- Pager UI: `‹ Prev  1 … 4 5 [6] 7 8 … 11  Next ›` built by `buildDirectoryPager(page, totalPages)`, delegated click on `#directory-pager [data-dir-page]`. Pager clicks `pushState` (Back/Forward step through pages); `renderDirectory`'s own URL sync uses `replaceState` and only fires while the directory route is showing.
- **Out-of-range clamp is two-stage** because `total_count` rides on each returned row (`count(*) over()`), so a page past the end returns **zero rows and no total**. On `rows.length === 0 && targetPage > 1` it re-queries page 1 (`baseParams` + `p_offset: 0`) to get a real `total_count`: > 0 ⇒ `renderDirectory(lastPage)`; 0 ⇒ genuine empty state. A second guard (`targetPage > totalPages` when the count *was* returned) covers the in-range-but-too-high case.
- The Events page's own "Load more" is untouched — separate follow-up.

**Denomination-tinted placeholders.** Logoless churches all got the same grey building icon — a wall of identical tiles. `churchCard()` now adds `.thumb--denom` with an inline `--thumb-hue` from `denomHue(c.tag)`: a hand-picked hue per known denomination (Baptist 210, Catholic 275, …), and a stable string hash for anything else (free-form CSV values, blanks → 220). CSS gives a muted wash + matching icon stroke, with `html[data-theme="dark"]` overrides (the app resolves `prefers-color-scheme` to the `data-theme` attribute at load, so no media query needed). Real logos (`c.logoUrl`) never get the class. Applies to the directory grid and the homepage "Churches near you" (both go through `churchCard`). Build stamp `2026-09-10-v269`.

---

## Directory: Card / List view toggle

The directory has a **Cards / List** segmented toggle in `.dir-results-head` (next to the "N churches found" count). List view drops the thumbnail entirely — a logoless church costs zero extra height — and renders one compact `.church-row` (`churchRow()`): name + denomination tag + status tag on line 1, distance / next-service / next-event meta on line 2, a `>` chevron, and a denomination-hued left accent (`--thumb-hue` from the same `denomHue()`). Same `<a href="#church" data-route="church" data-church-name>` as `churchCard`'s anchor, so the existing click handler drives it.

- **View state:** `directoryView()` / `setDirectoryView()` back onto `localStorage['fd-directory-view']` (`'list'` | `'cards'`, default cards), both wrapped in try/catch (private-mode throws on access). Per visitor, not synced anywhere.
- **`paintDirectoryGrid()`** is the single place the grid is filled from `window.directoryLastRenderedRows`, in whichever view is active — it sets `#directory-grid`'s `className` (`grid` vs `church-list`) and inline `display` (`grid` vs `flex`), then `mapJoin`s the rows through `churchCard` or `churchRow`. Called by: `renderDirectory` (fresh page), `refreshDirectoryCardsText` (language switch), and the toggle handler. **Switching view does no network call and doesn't touch pagination** — it just repaints the cached rows.
- The toggle handler (`[data-dir-view]` click, near the pager handler) writes the pref, calls `syncDirViewButtons()` (`.is-active` + `aria-pressed`), and repaints. `syncDirViewButtons()` also runs once at load so a returning list-view visitor sees the right button lit before the first render.
- New i18n: `directory.viewCards` / `directory.viewList` / `directory.viewToggleLabel` (EN + ES). The homepage "Churches near you" strip is cards-only — untouched. Build stamp `2026-09-10-v270`.

---

## Homepage: dual-audience "For churches" section + register-church gate

The homepage was 100% churchgoer-facing — hero + "Churches near you" + "Upcoming events", nothing addressed to a church admin deciding whether to sign up. The only owner-path signpost was the Pricing nav item → a page titled "Become a Partner Church".

**What was added ([index.html](index.html), build v271):**

- **Hero secondary link** (`.hero-for-churches`, right under `.search-bar`): "Are you a church? **List your church — free**" → `#register-church` with `data-add-church="true"` (so it flows through the same invite-gate + plan-check click handler as every other "Add a church" link).
- **`.for-churches` band** — full-width tinted (`var(--paper)`) section after the events grid, still inside `#page-home` but outside `.wrap` so it spans edge to edge. Eyebrow / heading / lead / 3 points / CTA / private-testing note. All `data-i18n`; the 3 points use a `<strong data-i18n>` + `<span data-i18n>` pair per point (two separate keys, since `applyLang` sets `textContent`). Keys: `home.forChurchesQ/Link`, `home.fc.eyebrow/heading/lead/count/p1t/p1b/p2t/p2b/p3t/p3b/cta/note` (EN + ES).
- **Live church count** — `home.fc.count` (`'{n} churches listed and growing'`) shown in `#home-fc-count` inside the band. **Off by default:** `var FD_SHOW_CHURCH_COUNT = false` (module scope, near `FD_INVITE_CODES`), plus `FD_CHURCH_COUNT_MIN = 50` so it self-suppresses under a thin directory even when flipped on. `renderForChurchesCount()` (called from `loadRealChurches`) returns early unless the flag is on; when on it does one `search_churches` probe (`p_limit:1`) and reads `data[0].total_count` (rides on `count(*) over()`). `paintForChurchesCount()` / `window.refreshForChurchesCountText` reformat the cached number on language switch with no network call (same pattern as `refreshDirectoryCountText`). **Flip `FD_SHOW_CHURCH_COUNT` to `true` once the metro import is called done.**

**`#register-church` invite gate for uninvited visitors.** Before this, `#register-church/new` and `[data-add-church]` clicks were gated (bounce + `openInviteGate()`), but **bare `#register-church`** — which the Pricing "Get started free" button reaches via inline `onclick="go('register-church')"` — was not: an uninvited, signed-out visitor saw the full registration form and only hit the invite modal on submit (3 dead-ends before the "Request access" link). `go()` is the one chokepoint every entry passes through (the `[data-route]` handler and `showRouteFromHash` both end in `go()`), so the gate went there, right after the existing dashboard redirects:

```js
if(route.split('/')[0] === 'register-church' && !window.isSignedIn && typeof window.fdInviteUnlocked === 'function' && !window.fdInviteUnlocked()){
  if(typeof window.openInviteGate === 'function') window.openInviteGate();
  route = 'home';
}
```

`!window.isSignedIn` (not `=== false`) so an unresolved auth state is treated as signed-out; a real church owner editing their profile is `isSignedIn === true` and unaffected, and any tester who entered the code on this browser has `fdInviteUnlocked()` true (and couldn't be signed in here otherwise, since `#signup`/login is gated the same way). The pre-existing `checkExistingChurch` `routeKey === 'new'` gate and the `data-add-church` click gate are left in place as redundant coverage. Build stamp `2026-09-10-v271`.

---

## "Christian / General" denomination — translation + first-class filter

11 of the ~19 live directory churches carry the exact denomination string `Christian / General` (from the metro import). Two gaps:

1. **Not translated.** `translateDenomination()` ([index.html](index.html)) only maps a fixed `denomI18nKeyMap`; an unmapped value falls through raw, so ES cards showed `Christian / General` instead of `Cristiana / General`. Fix: added `'Christian / General': 'denom.christianGeneral'` to the map + `denom.christianGeneral` to both dicts (`'Christian / General'` EN, `'Cristiana / General'` ES). This alone fixes the directory cards, church-profile eyebrow, and profile details tag, since all three already route through `translateDenomination()`.

2. **Not filterable.** The denomination filter is a **static** set of 9 checkboxes (`rebuildDenomFilterChecklist()` only updates the dropdown's count label, it does NOT rebuild the list). `Christian / General` churches were reachable only via the **"Other"** checkbox, which the filter logic treats as a wildcard — checked ⇒ `p_denominations = null` (no narrowing). So unchecking "Other" and picking any specific denomination dropped all 11 with no way to isolate them. Fix: added a `value="Christian / General"` checkbox to **both** the directory filter (`.denom-filter`) and the Events filter (`.events-denom-filter`), a `<select>` option to the register-church form, `'Christian / General'` to the `knownDenoms` array in `checkExistingChurch` (so editing such a church selects the option instead of falling to "Other" + free-text), and to the `coreDenomsAll` / `coreDenomsForEvents` arrays used by the dropdown's own denom-search box. `search_churches`'s `p_denominations` and the Events page's `.in('denomination', …)` both match exact strings, so `['Christian / General']` filters correctly with no backend change.

**Still a known quirk (unchanged):** "Other" remains a wildcard ("show everything"), not a true residual bucket ("denominations not in this list"), and the 6 churches with a NULL denomination are still displayed as "Non-denominational" by `mapSearchRow` (`row.denomination || 'Non-denominational'`). Both left as-is. Build stamp `2026-09-10-v272`.

---

## Nav cleanup + "Church dashboard" → "Manage my church"

**Public nav is now `Churches | Events | For churches | Pricing | Sign in`** ([index.html](index.html)):

- **"For churches"** (`#nav-for-churches-link`, `nav.forChurches`) is **not a route** — `href="#home"`, no `data-route` (so it never gets a misleading `.active` state and the generic `[data-route]` handler skips it). Its own listener (near the hamburger wiring) does `go('home')` then scrolls `.for-churches` into view. The mobile menu-close is handled by the existing delegated `#nav-links` click listener.
  - **The scroll needs three passes** (v274 fix). The homepage's "Churches near you" / "Upcoming events" grids render **asynchronously** and push the band down ~480px *after* the click handler runs, so a single immediate `scrollIntoView` lands about one screen short. The handler now fires `scrollIntoView({behavior:'smooth',block:'start'})` at 80ms (the animated pass for real, focused tabs) then `scrollIntoView({block:'start'})` instant corrections at 550ms and 1100ms to snap to the settled position. Verified in real Chrome: final `scrollY` puts the band flush at the top.
  - `behavior:'smooth'` `scrollIntoView` is a no-op in a **backgrounded/hidden tab** — Chrome suppresses smooth-scroll animation when `document.visibilityState === 'hidden'` (both the Browser pane and Claude-in-Chrome run tabs hidden). Not a real-user issue (their tab is focused); it just means the smooth animation itself can't be observed through either automation tool — only the final landing position can.
- **"Log in" + gold "Sign up" CTA → one plain "Sign in" link.** `#nav-signup-btn` and the `.nav-cta` CSS (both blocks) were deleted; `#nav-login-link` kept its id (still toggled by `updateAuthUI`) but now carries `data-i18n="nav.signin"` = "Sign in" / "Iniciar sesión". Signup discovery lives on the homepage hero link + "For churches" band, both invite-gated.
- **`#nav-admin-link`** got `data-i18n="nav.admin"` (`'Admin'` / `'Administración'`) — it was hardcoded English before. Gate unchanged (`window.isPlatformAdmin`).

**Dashboard link — moved, renamed, re-gated:**

- **Moved** from the top bar into `#nav-user-dropdown` (first item, above "Account profile").
- **Renamed** `nav.dashboard` "Church dashboard" → **"Manage my church"** / **"Administrar mi iglesia"**. New key `nav.dashboardPlural` "Manage my churches" / "Administrar mis iglesias" — swapped in when `window._dashMultiOwner` is true, in three places that compose: `loadDashboardHeader` (right after it sets `_dashMultiOwner`), `updateAuthUI` (the dashLink line), and `applyTranslations` (so a language switch keeps the plural). Each flips the element's `data-i18n` attribute AND sets `textContent`, so the next `applyTranslations` pass stays consistent.
- **Re-gated** on `window.hasChurchAccess` (owner **or** staff — the same signal `go('dashboard')` uses) instead of `accountType === 'church'`. **This was a real bug:** a staff member whose `account_type` wasn't `'church'` had no nav link to a dashboard they can legitimately open. Still hidden for platform admins (they use the Admin panel's own "Manage my church →" link).

**Ripple renames (dict + every static HTML fallback copy — the dict is the runtime source of truth, HTML text only flashes pre-`applyTranslations`):**

| Key | Old | New (EN / ES) |
|---|---|---|
| `admin.myChurchDashboard` | "My church dashboard →" | "Manage my church →" / "Administrar mi iglesia →" |
| `ce.backToDashboard` | "← Back to dashboard" | "← Back to my church" / "← Volver a mi iglesia" |
| `pricing.free.f2`, `ptable.dashboard` | "Dashboard access" | "Church management tools" / "Herramientas de gestión de la iglesia" — *note: both keys are currently unreferenced by the live pricing render (legacy), renamed for when/if they're re-wired* |
| `help.a3/a4/a6/a8` | "your church dashboard", "your dashboard's X section" | "the tools for your church", "your church's X section" (ES: "las herramientas de tu iglesia", "de tu iglesia") |

`help.*` and a few others store `’`/`—` as literal `\u2019`/`\u2014` in the EN dict and `\u00XX`-escape accented chars in the ES dict, while the static HTML `<p>` fallbacks use literal UTF-8 — so each string needed editing in whichever encoding that copy uses. Build stamp `2026-09-10-v273`.

---

## Comparison page reframed + re-linked (`#compare` is live again)

`#page-compare` was dormant (removed from `validRoutes`, no inbound link). It's now reframed and back in navigation:

- **Claim** (`compare.subhead`) — was "A church management system is table stakes. What none of the others offer is a public directory that helps people actually find you" (absolute, falsifiable). Now: "Church management is table stakes — every tool in this space does events, check-in, giving, and groups. FaithDock adds a public directory designed to help people in your area discover your church and what's happening there."
- **Headline** `compare.headline`: "FaithDock vs. Breeze vs. Planning Center" → "How FaithDock is different".
- **Table** — was a 4-column feature-parity checklist vs. two named competitors (with a stale "$72/mo" and five rows all three products do). Now **2 comparison columns** (FaithDock vs. `compare.traditionalChms` "Traditional church management software") and **6 discovery-focused rows**: public church discovery, public event discovery, reach beyond your congregation, community discovery, one honest parity row (everyday church management ✓/✓), and a generic pricing row. Competitor cells are nuanced ("Share-by-link only", "Limited", "Built for members you already have") not bare "—", so it reads fair rather than strawman.
- **Footnote** — no longer references named competitors or a year; describes what "traditional ChMS" means generically.
- Old row keys (`compare.startingPrice`, `compare.breezePrice`, `compare.pcPrice`, `compare.publicDirectory`, `compare.congregationGrowth`, `compare.eventRegistration`, `compare.dayOfCheckin`, `compare.yesSeparateModule`, `compare.volunteersTracked`, `compare.givingTaxStatements`, `compare.yesExtraFees`, `compare.memberMobileApp`, `compare.pricingModel`, `compare.simpleTiers`, `compare.flatRate`, `compare.perModule`) **deleted** from both dicts; replaced by `compare.traditionalChms` / `rowPublicChurch` / `tradBuiltForMembers` / `rowPublicEvent` / `tradShareLinkOnly` / `rowBeyondCongregation` / `rowCommunityDiscovery` / `rowEverydayMgmt` / `rowPricing` / `fdFreeListingTiers` / `tradFlatOrModule`. `compare.limited` kept (reused). `compare.eyebrow` / `feature` / `readyToTry` / `seePlans` unchanged.

**Re-wiring (the "nothing left half-wired" check):**
- `'compare'` added to `validRoutes`; the "'app', 'give', 'conference' and 'compare' are deliberately NOT in this list" comment updated to drop compare.
- The **dead `pricing.compareLink` key** found in the earlier audit is now live: rendered as an `<a href="#compare" data-route="compare">` under the Pricing page subtitle (replacing the "link removed per request" comment there), and **reworded** EN "See how FaithDock compares →" / ES "Mira cómo se compara FaithDock →" (was "…to Breeze & Planning Center →", which would contradict the now-competitor-free page).
- No JS route-guard, redirect, or populate hook special-cased `#compare` — it's fully static HTML, so `go('compare')` is all it needs. The page's own "See plans" button (`onclick="go('pricing')"`) still works.

Build stamp `2026-09-10-v275`.

---

## Pricing tiers: "what this tier is for" taglines

Each of the 5 pricing cards now carries a one-line progression tagline (`<p class="price-tagline" data-i18n="pricing.<tier>.tagline">`) between `.price-amount` and the feature `<ul>` — **get found → run your events → run your community → run your whole church → run a network**. New keys `pricing.{free,starter,medium,large,multiChurch}.tagline` (EN + ES). No JS, no matrix change, no price/feature/gating change. (`medium` = Standard, `large` = Premium, matching the existing dict convention.)

**Keeping the 5 feature lists aligned** took more than the proposed `min-height`:
- Taglines wrap to 3–5 lines depending on copy length, language (ES runs ~15% longer), and column width (5-col ≈ 222px, 3-col ≈ 294px). A plain `min-height` only pads *up*; it can't stop a long ES tagline from pushing its own list down.
- Fix: `.price-tagline` is `display:-webkit-box; -webkit-line-clamp:4; overflow:hidden` **and** `min-height:calc(4 * 1.45em)` — so every tagline occupies **exactly 4 lines**, padded up if short, clamped down if long (clamp is a safety net; the copy is written to fit 4 lines at 222px, and the two longest ES lines were trimmed so nothing actually clamps). Under `@media (max-width:860px)` (cards stack single-column) both are released — no point reserving 4 lines of blank space per stacked card.
- Second, separate cause found while verifying: the **Multi-Church card's word price** ("Custom" / **"Personalizado"**) wrapped to 2 lines at 38px in a 222px column, dropping that one card's list ~24px in Spanish. Fixed with `.price-amount[data-i18n="pricing.multiChurch.price"]{font-size:23px;min-height:61px;display:flex;align-items:flex-end;}` — smaller text, one line, in a box the same height as a 38px numeric price. Pre-existing; only visible once the taglines made cross-card alignment matter.

Verified: feature-list start positions within **1px** across all 5 cards at 5-col (EN and ES), aligned within rows at the 3-col breakpoint, no tagline clamped in any tested width, no horizontal overflow on mobile. Build `2026-09-10-v276`.

---

## Create-event form: primary fields + collapsed "Advanced options"

`#page-create-event` was one long flat form. It's now a short primary screen plus a `<details id="ce-advanced">` disclosure — **layout only, every field kept its id, value, validation, and show/hide behavior**.

**Primary (direct children of `.auth-card`, in this order):** Title → Starts/Ends → Venue name → Location (+ "use church address") → Description (RTE toolbar + editable + char count + AI Writing Assistant + its locked-state box + the RTE `<style>`) → Event graphic. Matches the spec's "Title, Date, Time, Location, Description, Graphic, Publish" (Publish = the existing Save-draft / Publish buttons, still after the error/success rows).

**Advanced (`<details>`):** Rooms · Event contacts · Registration questions · Categories · Tags · Who is this for (audience) · Who can see this (visibility) · the whole Require-registration box (max participants, ticket price, fee mode, suggested donation, discount codes, volunteers + their questions, guests) · Repeats.

**How it was reordered:** Description was between Title and Date; Graphic was between Questions and Categories. Rather than one 260-line rewrite, four surgical moves: (1) lift Date/Time/Venue/Location out of their spot after Description, (2) re-drop them right after Title, (3) pull Graphic out from between Questions and Categories, (4) re-drop it after Description and open `<details>` before Rooms; then close `</details>` before `#ce-error`. Inner blocks kept their original 6-space indent (HTML doesn't care; keeps the diff minimal). Every field is queried by `getElementById`/class in JS — no positional selectors, no `nextElementSibling` walks — so the reorder + wrap is inert to the logic.

**Disclosure state:**
- Default: collapsed. `<details>` has no `open` attribute, and `resetCreateEventForm()` sets `ceAdv.open = false` (the dashboard "Create event" button's path).
- Editing: `editEvent()` sets `ceAdvEdit.open = !!( ev.registration_required || ev.price_cents || ev.suggested_donation_cents || ev.fee_mode==='absorb' || ev.allow_volunteers || ev.allow_guests || ceQuestions.length || ceVolunteerQuestions.length || (Array.isArray(ev.audience) && ev.audience.length) || selectedRoomIds.length || (ev.repeats && ev.repeats!=='none') )` right before `go('create-event/'+id)`. So an existing event opens with Advanced expanded iff it already uses one of those fields; otherwise collapsed. (`ev.repeats` is inert on edit — the repeats section is `display:none` when editing since occurrences are already generated — but it's in the check for completeness.)
- Safety net: the one advanced-field validation that surfaces through `showCeError` (`ce.priceMustBePositive`) now also sets `ceAdv.open = true` so the erroring field is never hidden. Contacts / categories / tags / visibility are in Advanced but are **not** auto-expand triggers (per the spec's explicit list).
- New i18n: `ce.advancedOptions` / `ce.advancedOptionsSub` (EN + ES).

**Testing note:** `<details>` collapse, CSS `transform` transitions, and `content-visibility` are all throttled/frozen in a backgrounded tab — which is how both the Browser pane and Claude-in-Chrome drive pages this session. Verified via each element's own `getBoundingClientRect().height` (the `<details>` goes ~40px collapsed ↔ full height open) and by killing the chevron `transition` to read its settled `rotate(180deg)`; a *descendant's* rect height stays non-zero even when the `<details>` clips it, so it's not a reliable collapse check. Structure, toggle (summary click + `.open`), `resetCreateEventForm` collapse, the 11 editEvent triggers (against mocks), and the in-`<details>` sub-toggles (registration options, repeat-until, volunteer options + heading swap) all pass. Build `2026-09-10-v277`.

---

## Homepage "List your church — free" CTAs: don't send signed-in visitors to Pricing

Both CTAs -- the hero inline link (`home.forChurchesLink`) and the For-churches band button (`home.fc.cta`) -- were wired **identically** (`data-route="register-church" data-add-church="true"`), handled only by the one delegated `[data-route]` click listener. There was never a Pricing-vs-event-creation split between them (verified by instrumenting `go()` and simulating every auth state -- both produced the same call every time). Any "lands on event creation" sighting was the `#rc-next-step` "Create your first event →" link on the register-church page, or Pricing's own free-plan button (`onclick="go('register-church')"`) chaining onward.

**The real bug (shared):** the `data-add-church` branch sends a *signed-in* visitor to `go('pricing')` -- via the "first church ever, pick a plan first" redirect (`limits.churches_owned === 0`) or the at-cap redirect (`churches_owned >= max_churches`). Correct for the in-app "Add a church" buttons (Profile / My Churches / dashboard `+`); wrong for a homepage CTA that literally says "free."

**Fix:** the two homepage CTAs now use `data-list-church="true"` (not `data-add-church`), with a dedicated branch at the top of the `[data-route]` handler that fully handles the click and returns:
- not invite-unlocked → invite gate (re-fires the click on unlock) -- unchanged
- signed in **and owns ≥1 church** (`get_my_plan_and_usage().churches_owned > 0`) → `go('dashboard')`
- otherwise (signed in with no church, or signed out + invite-unlocked) → `resetRegisterChurchFormToBlank()` + `go('register-church/new')` -- the real blank registration form, defaulting to the Free listing; a signed-out visitor is still prompted to sign in when they submit it

The fall-through `route === 'register-church' && !data-add-church` edit-profile check also excludes `data-list-church` (defensive; the branch returns first). No i18n or visual change. Verified all four states, both CTAs identical in each, plus the not-unlocked invite-gate path and a real signed-out end-to-end (lands on `#register-church/new`, blank, `#rc-next-step` hidden). Build `2026-09-10-v279`.

---

## CSV import batch tracking + admin bulk hide/delete

Added ahead of the San Antonio metro import so a bad run can be reviewed and rolled back as one unit instead of church-by-church.

**Schema (`supabase/migrations/020_import_batch_tracking.sql`, not yet run against the live DB — same manual-migration workflow as always):**
- `churches.import_batch_id text`, `churches.import_source_filename text` (both null outside imports) + a partial index on `import_batch_id`.
- `admin_import_churches` gets 2 new params (`p_batch_id`, `p_source_filename`) — a different signature from the existing 1-arg version, so this is `DROP FUNCTION admin_import_churches(jsonb)` + `CREATE` (same lesson as `search_churches` in migration 017 — `CREATE OR REPLACE` with an added param list creates a second overload instead of replacing the old one).
- New RPCs, all `security definer` + `is_platform_admin()`-gated: `admin_list_import_batches()` (grouped listing: batch id, filename, earliest `created_at` as the batch date, row count, unclaimed count), `admin_hide_import_batch(p_batch_id)`, `admin_delete_import_batch(p_batch_id)`.
- **Both bulk actions are scoped to `owner_id is null`** — same guard `admin_delete_unclaimed_church` already uses one row at a time. A church someone's genuinely claimed since the import doesn't get hidden or deleted out from under them; `admin_delete_import_batch` returns `(deleted_count, skipped_claimed_count)` so the UI can say so rather than silently deleting fewer rows than the batch's total.

**Client (`index.html`):** one batch id is generated **once per "Add churches" click** — `new Date().toISOString() + '_' + filename` — and threaded through every 200-row chunk of that run, so a large multi-chunk CSV still counts as a single batch. New admin-panel section "Import batches" (right after "All churches"): one row per batch with date/filename/counts and Hide all / Delete all buttons, hidden entirely (replaced by an "All claimed" note) when a batch's unclaimed count is 0. Delete confirms via plain `confirm()` showing the exact unclaimed count — same pattern as `admin.deleteUnclaimedConfirm`. A status line under the list shows the last hide/delete result and **deliberately isn't cleared by the list's own reload** (`loadAdminImportBatchesList()` doesn't touch it) — the hide/delete handlers set it, then call `loadAdminPanel()`, which re-renders the list without wiping the message, same as the import modal's own status line persisting until it's reopened.

**Testing note:** verified the whole click-through path (render both an in-progress and an all-claimed batch, Hide all, Delete-all-declined, Delete-all-accepted, both status message variants) against a stubbed `supabase.rpc`. Verified batch-id generation and the import RPC payload with a real file input + FileReader + a CSV with no `address` column (skips geocoding, which hangs in this sandboxed browser since `google.maps.Geocoder` isn't fully available there — a pre-existing dependency of the import flow, not something this change touches). No console errors. Build `2026-09-10-v280`.

---

## Directory/homepage cards: no tag for the baseline unclaimed state

`churchStatusTag()` (used by `churchCard()` on the directory grid and the homepage "Churches near you" strip) no longer renders a "Directory listing" tag for a plain unclaimed church — that's the baseline for most of the directory, so a tag announcing it on every card was noise. The 3 elevated states are unchanged: claimed → "Managed by this church", claimed + verified giving → "Verified church", claimed + paid plan → "FaithDock Partner".

**Not touched:** the church profile page's own unclaimed banner (`#church-unclaimed-banner`, "This is a community directory listing — the church hasn't set it up yet. Claim this church") — that's set independently in `populateChurchPage()`, not through `churchStatusTag()`, and stays exactly as-is since it's actionable in context rather than a redundant per-card label.

`church.statusDirectoryListing` (EN "Directory listing" / ES "Listado del directorio") is now an unused i18n key — left in place, not deleted. Build `2026-09-10-v281`.

---

## #register-church now gates unauthenticated visitors up front

**Before:** an invite-unlocked but signed-out visitor who reached `#register-church` (bare or `/new` — the homepage "List your church" CTAs, the Pricing "Get started free" button, a direct/bookmarked URL) saw the full registration form. Nothing stopped them until they hit **Publish**, where the submit handler's own check (`showRcError('You need to sign up or log in first.')`) finally blocked it. The invite gate itself (`go()`'s existing `!fdInviteUnlocked()` check) only fires when the browser hasn't entered the code at all — it doesn't require an account.

**Now:** `go()` gates `#register-church`/`#register-church/new` on `window.isSignedIn === false` (checked *after* the invite-gate condition, so an un-invited visitor still hits that first) and redirects straight to `#signup`, saving `'register-church/new'` via the existing `savePostLoginRoute`/`consumePostLoginRoute` mechanism (same one `dashboard` already uses). `updateAuthUI` gets the matching async redirect for the case `go()`'s synchronous check can't catch — landing directly on `#register-church` before auth has resolved, then resolving to signed-out (mirrors the existing dashboard redirect there line-for-line). Both use `=== false`, not bare falsy, so a still-unresolved auth state doesn't bounce a signed-in user — same deliberate leniency the dashboard check documents.

**Landing on a genuinely blank form after sign-in:** `go()` only ever toggles page visibility, it never populates a page — so `routeAfterLogin()` (the single funnel every sign-in path already routes through) now special-cases `landingRoute === 'register-church/new'` the same way it already special-cases `'profile'`: calls `checkExistingChurch(user.id, 'new')`, the exact function the "Add a church" flow already uses to reset the form. That also repeats the plan-cap check, so an account that signs in already owning a church at its plan's limit correctly lands on Pricing instead of a form it can't use, rather than silently showing stale/wrong state.

**Verified** (via `go()`/`checkExistingChurch` directly, `updateAuthUI`/`routeAfterLogin` aren't exposed on `window` so verified by exact structural match to the proven dashboard pattern instead):
- signed-out (resolved false), invite-unlocked, bare `#register-church` and `#register-church/new` → both redirect to `#signup`, post-login route saved as `register-church/new`
- unresolved auth (`undefined`) → form still shows (matches dashboard's documented leniency)
- not invite-unlocked → invite gate takes precedence, bounces home, does *not* also redirect to signup
- signed-in → form shows normally, no redirect
- dirtied the form fields, then ran the exact post-login call (`checkExistingChurch(userId, 'new')`) → all fields reset to blank, heading/button back to "Register your church" / "Create church" (not edit mode)
- same call with a mocked at-cap plan → correctly lands on `#pricing` instead

No console errors. Build `2026-09-10-v282`.

---

## Comparison table: mobile layout (was unusably cramped)

The `#compare` page's 3-column table (`min-width:600px`, `overflow-x:auto`) just looked cut off on a phone — no obvious "scroll for more" affordance, and the long feature sentences made the horizontal-scroll pattern a bad fit regardless. Below 700px it's now a stacked-card layout, CSS-only (no HTML or JS changes):

- The header row collapses to a small 2-column legend ("FaithDock" / "Traditional church management software") above the cards — its "Feature" label is dropped since every card already leads with its own feature text. Reading the real, already-translated `<th>` text for this (rather than hardcoding new labels) is what keeps ES correct with zero new i18n keys.
- Each data row becomes its own bordered/rounded card: the feature sentence spans the full width on top, then the FaithDock and Traditional-ChMS values sit side by side underneath, split by a vertical divider.

**Bug caught during verification, fixed before shipping:** the first pass targeted the feature cell with `.compare-table tr:not(:first-child) .compare-feature-col{grid-column:1/-1;...}` — but that class only exists on the header `<th>`; a data row's feature `<td>` is a plain, class-less cell. The rule silently matched nothing, so the checkmark landed next to the feature text on the same grid row instead of below it, and the next row's value cell wrapped alone with nothing beside it. Fixed by targeting `tr:not(:first-child) td:first-child` (positional, not class-based) instead — confirmed via `getComputedStyle` that `grid-column` was actually `1 / -1` on the right element, then re-screenshotted every row (including the ✓/✓ parity row and the two-text-value pricing row) in both themes and in Spanish. Desktop (`>700px`) computed styles confirmed completely unaffected (`display:table`, `min-width:600px`, unchanged). Build `2026-09-10-v283`.

---

## Fixed 4 async-state flashes: Pricing buttons, nav "Sign in", and a duplicate church-ownership fetch per page load

All 4 traced back to the same pattern: an element painted a signed-out/default value synchronously, then got silently reassigned once an `await`'d Supabase call resolved, with nothing suppressing paint in between — a visible "wrong then right" flicker for a returning signed-in user.

**1. Pricing Free-plan button — disabled, not just relabeled, while ambiguous.** `populatePricingPage()`'s `paintDefaults()` still wires Free's plain `onclick` (`go('register-church')`) up front, but `hideUntilKnown()` now also sets `freeBtn.disabled = true` — a disabled button never dispatches a `click` to whichever `onclick` happens to be attached, so the plain handler genuinely can't fire for a signed-in owner mid-lookup, without needing to null/re-wire `onclick` at all (a re-wire approach was considered and dropped — too easy to leave `onclick` permanently null if `applyChurchState()` returns early on the no-church case). The real downgrade handler (`performPlanDowngrade`) is only wired once `applyChurchState()` runs post-resolution.

**2. Nav bar — `#nav-login-link` now starts `display:none;` in the HTML itself** (matching `#nav-user-menu`'s existing default), instead of defaulting to visible "Sign in" until `updateAuthUI()` decides otherwise. No JS change needed — `updateAuthUI()` already unconditionally sets `loginLink.style.display` once resolved, in both directions.

**3. Pricing `<h1>` + the three plan buttons (Starter/Standard/Premium) — same hide-until-known treatment**, but via `visibility:hidden` inside `hideUntilKnown()`/`revealNowKnown()`, not `display:none`: unlike the nav-bar link (a single inline element), hiding an `<h1>` and a row of buttons with `display:none` would visibly collapse/reflow the page on reveal. Only reached when there's real ambiguity to hide (see next point) — Starter/Standard/Premium's own `onclick` handlers already self-check `getMyChurch()` at click time, so unlike Free they only had a labeling risk here, never a misfire risk.

**4. Deduped `loadDashboardHeader()` and `updateAuthUI()` onto one shared fetch.** Both independently queried church ownership on every single page load. `getMyChurch()`'s existing 1.5s same-tick cache (`window._myChurchCache`) now also tracks `settled`/`value`, exposing a synchronous `peekMyChurch()` — "do we already know, with zero async cost." `updateAuthUI()`'s church-access check now calls the same bare `getMyChurch()` (no explicit user id) that `loadDashboardHeader()` calls, instead of running its own separate `churches`/`church_staff` queries — bare-vs-bare matters here, since an explicit-id call and a bare call resolve to different cache keys and wouldn't actually share anything. `populatePricingPage()` calls `window.peekMyChurch()` first and, on a hit, paints the final state in one shot with no hide/reveal at all — the second-page-in-a-row case (e.g. dashboard → pricing within the 1.5s window).

**Verified live** (stubbed `supabase.auth.getUser`/`supabase.from` with artificial latency, since the real dev Supabase backend has no test account handy): `peekMyChurch()` hit/miss/expired cases exercised directly against a hand-built cache entry; `populatePricingPage()` synchronously shows `freeBtn.disabled === true` and `visibility:hidden` on title/Starter/Standard/Premium immediately after the call, before the stubbed fetch resolves, then reveals with the correct end state for a mocked Premium owner (title → "Manage your plan", Free → "Downgrade to Free" and enabled, Premium → disabled "Your current plan", its Cancel-subscription link shown); concurrent `loadDashboardHeader()` + a second bare `getMyChurch()` call produced exactly 1 network call, and a `populatePricingPage()` peek-hit right after painted instantly with no additional fetch. `updateAuthUI()` itself isn't exposed on `window` (same as `routeAfterLogin` earlier this session) so its dedup was confirmed by source inspection — it now makes the identical bare `getMyChurch()` call already proven to share a cache entry — rather than direct invocation. Signed-out nav bar reconfirmed correct on a fresh, unstubbed reload (`#nav-login-link` visible, `#nav-user-menu` hidden). No new console errors (pre-existing Cloudflare Turnstile errors on localhost are unrelated — Turnstile doesn't recognize the dev origin, not something this change touches).

**Left alone, per explicit instruction:** the Admin nav link and the dashboard sidebar's "Loading..." state — both already confirmed safe in the prior audit. Build `2026-09-11-v284`.

---

## Directory cards: right-click "open in new tab" / middle-click landed on the directory, not the church

`churchCard()` and `churchRow()` (the directory grid/list, also reused on the homepage's "Churches near you" strip) built their `<a>` tag with a static `href="#church"` — no church identifier in the URL at all. The actual click always worked, because the shared `[data-route]` click delegate calls `ev.preventDefault()` unconditionally and reads the church from a separate `data-church-name` attribute instead of the href. But right-click → "Open link in new tab" and middle-click never fire that delegate (`contextmenu`/`auxclick`, not `click`) — the browser just follows the bare href, landing a new tab on `#church` with no key. `showRouteFromHash`'s own fallback for exactly that case (`resolved.base === 'church' && !resolved.key`) sends it to `#directory` — which is why it looked like it opened "another Churches near you tab" instead of the church.

**Fix:** both now build `href="#church/' + encodeURIComponent(c.name) + '"'` — the same real deep-link format already used elsewhere in the app (admin panel church links, the event page's "Hosted by" link). `resolveRouteFromHash`/`showRouteFromHash` already handled `#church/<name>` correctly on a fresh load; the directory card/row were the only two places still building a keyless href. No JS logic changed — the click delegate still calls `preventDefault()` and still reads `data-church-name`, so normal left-click behaves identically to before.

Verified in a local preview: left-click still SPA-navigates correctly (confirmed via `location.hash` after the click); a **fresh page load** on the resulting URL (the actual right-click/middle-click case, since neither fires the click delegate) now correctly resolves and populates that specific church instead of falling through to the sample-church template.

**Caught after reporting this fixed:** the change sat uncommitted in the working tree for a while before actually being pushed — the user re-tested on the live site in the meantime and (correctly) still saw the old bug, since nothing had shipped yet. Lesson: "verified in local preview" and "shipped" are different claims; don't let the gap between them go unstated. Build `2026-09-11-v285`.

---

## Added "Studies" event category, removed "Empty-nesters"

Event **categories** (`category_tags`, a free-form `text[]` column — no DB-side enum/CHECK constraint) show up in three separate places that all have to be kept in sync by hand: the create/edit-event form's checkbox list (`.ce-category`), that same form's icon-button quick-picker (`.event-category-btn` / `#event-category-row`), and the events page's own sidebar filter, which rebuilds itself from a hardcoded array in `rebuildCategoryFilterChecklist()` rather than deriving categories from whatever's actually in use ("a stable, official set," per its own comment) — plus the `categoryI18nKeyMap` translation table and both EN/ES i18n dictionaries. Added `Studies` (`category.studies` / "Estudios") to all of them, with a new open-book icon for the quick-picker. No migration needed — the column has no server-side whitelist to update.

**"Empty-nesters" turned out to be an audience value, not a category** — the user's own term for it, but it actually lives in the separate `.ce-audience` checkbox group on the create-event form (Preschool/Children/Teens/Adults/Seniors/Parents/Empty-nesters), which has no events-listing-page filter counterpart at all (audience is create-form-only, never surfaced as a public filter the way categories are). Removed the checkbox and both i18n dictionary entries; grepped the whole file afterward for `empty.?nesters?` case-insensitively and got zero hits, confirming no dangling reference anywhere (also checked `pure-logic.js` — nothing there either). Already confirmed zero live events used the tag before this ran, so no data remapping was needed. Build `2026-09-11-v286`.

---

## Nav "Pricing" hidden for anyone already on a paid plan

Before touching anything: confirmed the dashboard's Plans tab is genuinely 1 click away, not buried — it's a permanent entry in `#dash-nav-church`, the sidebar shown on every single-church dashboard load, and multi-church owners on the account-level Overview get the same tab via a parallel `#dash-nav-overview` nav (`#dash-ov-plans`). No UI change needed there.

`#nav-pricing-link` now starts `display:none;` in the HTML (same hide-until-known default as `#nav-login-link`), and `updateAuthUI()` decides it same as everything else there: signed-out reveals it immediately (nothing to wait on); signed-in reuses the same `getMyChurch()` call already made for `hasChurchAccess` — no second fetch — and hides it only when that call returns a church whose `planType` isn't `'free'` (`starter`/`standard`/`premium`/`multi_church`, whether the signed-in user is the owner or staff, since both roles get a `planType` off the same row). No church yet, or a free-tier church, both still see Pricing — that's the conversion path the feature is explicitly meant to preserve.

`updateAuthUI()` isn't exposed on `window` (same as `routeAfterLogin`/its own dedup logic earlier this session), so the decision logic was verified standalone against every `myChurch` shape `getMyChurch()` actually returns (no church, free with/without an explicit `planType` field, each paid tier, and staff-of-a-paid-church) rather than by direct invocation — all 8 cases resolved correctly. Signed-out reveal reconfirmed live. No new console errors. Build `2026-09-11-v287`.

---

## Addresses: ALL CAPS from the IRS source, title-cased at display time

Same root cause as the earlier church-name fix: bulk CSV imports (San Antonio, and any future metro/statewide run) carry the IRS EO Business Master File's raw ALL CAPS in `address`, but `name` was only ever fixed in the import CSV itself, before insert — `address` never got the same treatment and every place it's shown (church profile's About and Location tabs, 5 separate admin list/detail views) rendered it exactly as stored.

**Chose display-time normalization over mutating stored data**, unlike the name fix. Reasoning: the name fix was a one-time cleanup of a CSV about to be imported; fixing address the same way would mean re-running it for every future import (and there's no telling how many more metro pulls are coming) *plus* a one-time `UPDATE` across every already-imported row, with the usual risk of a bulk production write. A display-time function, added next to the existing `translateDenomination`/`translateCategoryTag` helpers (same "normalize a raw DB string at render time" pattern already used for those two fields), fixes every row — imported yesterday or written next year — with no data migration and no risk to already-correct addresses (a real church's self-entered address, likely from Google Places Autocomplete and already properly cased, passes through unchanged — confirmed idempotent).

**`titleCaseAddress()`** ([index.html:6076](index.html:6076)) reuses the exact connector-word list and the same protect-first/last-word rule from the name fix (`of/the/and/in/for/a/an/to` — that logic lived only in a one-off Node script from earlier this session, never in this file, so there was nothing to literally call; this ports the same design as real reusable code). Extended with: two-letter US state/territory codes forced uppercase, directionals (`N/S/E/W/NE/NW/SE/SW`) forced uppercase — deliberately not disambiguated from state codes sharing the same letters (`NE` as Nebraska vs. northeast) since both want the identical output — `PO` forced uppercase, a `Mc`-prefix surname rule (`MCQUEENEY` → `McQueeney`) deliberately *not* extended to `Mac` (`Macon`, `Mace` are real words/names a blanket rule would mangle), and apostrophe/hyphen-aware capitalization (`O'CONNOR` → `O'Connor`) so internal punctuation still gets its second capital. ZIP codes and punctuation are matched around, never touched.

Applied at all 7 real display sites: the profile page's About-tab address line and Location-tab address ([index.html:5931](index.html:5931), [index.html:5975](index.html:5975)), and 5 admin views (unresolved-addresses list, all-churches list, a pending/registrants list, and the admin church detail page). Deliberately left untouched: the register-church/create-event form address inputs (should show the true stored value while editing, not a transformed one), the Google Maps embed query and "Open in Google Maps" link (case doesn't affect either), and the import dedupe-key building (already normalizes via `.toLowerCase()`, so casing before that never changes the result). The public directory grid/list cards don't display address text at all currently, so there was nothing to fix there despite the request calling them out by name.

**Verified live**, real production data: `Mercy Church San Antonio` → `8311 S Zarzamora St, San Antonio, TX 78224-1757` (directional preserved); `Mt Horeb International Prayer Camp Ministries Inc` → `PO Box 10938, San Antonio, TX 78210-0938`. Additional cases run directly against the function: `1750 MCQUEENEY RD...` → `1750 McQueeney Rd...`; a fabricated `123 O'CONNOR RD...` → `123 O'Connor Rd...`; a hyphenated suite number (`STE 111-564`) left untouched; an already-correctly-cased address passed through unchanged.

**Found and flagged, not fixed (out of scope here)**: loading a `#church/<name>` URL as a fresh page load (not in-app navigation) throws an uncaught `"Cannot read properties of undefined (reading 'from')"` from `showRouteFromHash` — a pre-existing race unrelated to this change (confirmed nowhere near this diff; the page still recovers and renders correctly despite it). Spawned as a separate task rather than fixed here. Build `2026-09-11-v288`.

---

## Logoless-church placeholder: a real church icon instead of the plain arch

`buildingIcon` (the SVG shown on a directory card's `.thumb--denom` when a church has no uploaded logo) was previously just a rounded arch shape (`M6 20V11 A6 6 0 0 1 18 11 V20`) — not obviously church-related at all. Replaced with a plain gable roof + steeple + small cross over a simple rectangular body with a door, deliberately kept to bare outline strokes (no fill, no architectural detail) so it reads as "a church" in the abstract rather than depicting one specific building style.

**Tinting carried over for free, by construction, not by re-wiring anything**: `.thumb--denom svg{stroke:hsl(var(--thumb-hue,...))}` in the stylesheet already colors *any* SVG dropped into that slot — the only requirement is that the icon's own inner elements don't set their own `stroke` attribute (which would out-rank the CSS rule for that element specifically). The new icon's single `<path>` has no such attribute, same as the icon it replaced, so every existing denomination hue — the 9 named ones (Baptist, Catholic, Episcopal, Lutheran, Methodist, Non-denominational, Pentecostal, Presbyterian, Other) and the hash-derived fallback used for everything else (Christian/General, Church of God, Orthodox, Jewish, Anglican, ...) — tints it automatically.

**Verified visually, not just reasoned through**: rendered the actual `.thumb.thumb--denom` + `buildingIcon` markup at real card-thumbnail size (34px) across 11 different `--thumb-hue` values spanning the full set of named denominations plus two hash-derived hues, in both light and dark theme. Legible and clearly church-shaped (peaked roof, steeple, cross, door) at every hue tested, in both themes — screenshots shown in the conversation, not just described. Confirmed the "only logoless churches" boundary directly against `churchCard()`'s actual output: a church with a `logoUrl` produces no `thumb--denom` class and no building-icon markup at all (only the background-image), while a logoless church gets exactly the new icon and the tint class — the two code paths are mutually exclusive by construction, and this change only ever touched the `buildingIcon` string itself. No console errors. Build `2026-09-11-v289`.

---

## Church icon, round 2: solid fill instead of outline, bigger, real cross

Follow-up to the outline version above — at actual 34px card size the cross (a 3-unit stroke "+" at the very top) rendered as a barely-visible smudge rather than a recognizable cross, and the whole icon felt small and thin next to the tinted background.

**Switched from stroke-outline to solid-fill.** This meant switching what CSS property does the tinting: `.thumb--denom svg` went from `stroke:hsl(var(--thumb-hue,...))` to `fill:hsl(var(--thumb-hue,...))`, since `stroke` has nothing to color on a filled shape with no strokes at all. Same mechanism as before either way — none of the icon's own elements set their own `fill`, so they inherit the SVG's computed fill, which the CSS rule drives. `.thumb--denom` is scoped to nowhere else in the stylesheet (checked), so changing what property it targets had no other blast radius.

**The door is a true cutout, not a solid rectangle drawn on top.** The body is one `<path fill-rule="evenodd">` containing the outer wall rectangle and the smaller door rectangle as two overlapping subpaths — `evenodd` makes the overlap transparent, showing whatever's actually behind the icon (the tinted `.thumb--denom` background) regardless of which theme or hue that happens to be. A door drawn as a second solid shape in the background's own color would have needed to know that color and would break the instant either changed.

**Sized up**: `.thumb--denom svg` now renders at 46px, up from the shared 34px every other `.thumb svg` still uses (bumped independently since a solid shape needs more room to read clearly than a thin outline did, without changing the icon size used anywhere logos actually load).

**Verified the same way as before, not just reasoned through**: re-rendered the real markup at actual size across the same 11 denomination hues, both themes — cross, roof, and door cutout all clearly legible everywhere this time, screenshots shown in the conversation. Re-confirmed the logo/no-logo boundary directly against `churchCard()`'s output (a logo'd church's HTML contains neither `thumb--denom` nor the door's `fill-rule="evenodd"` path; a logoless church's contains both). No console errors. Build `2026-09-11-v290`.

---

## Church icon, round 3: friendlier rounded style (chevron roof, floating cross, arched door)

Round 2's flat solid silhouette worked but "looked weird" against a reference the user liked much better: a softer, rounded style with a chevron-shaped roof (thick rounded strokes with the ends peeking out past the walls, not a flush triangle), a cross floating clearly above the roof with a visible gap, and a rounded arched doorway rather than a plain rectangle. Rebuilt to match that style rather than iterate on the flat-silhouette shape further.

**Now genuinely mixed fill + stroke**, not just fill: the roof and the cross are drawn as thick strokes with `stroke-linecap="round"` / `stroke-linejoin="round"` (the rounded peak and the rounded nubs where the roofline ends are exactly what round line caps/joins are for), while the body is still a filled shape with the door punched out via `fill-rule="evenodd"`, same cutout technique as round 2. This meant the CSS tint rule had to grow from `fill` only to `fill` *and* `stroke` — `.thumb--denom svg` now sets both to the same hue-derived color, so a stroked part and a filled part end up the same visible tint without needing two different variables.

**Two SVG-fill-model gotchas, both handled explicitly rather than discovered live**: an open stroked path (the roof's `M...L...L...`, never closed with `Z`) still gets implicitly closed *for fill purposes* by the SVG spec — without `fill="none"` on that path, it would render as a solid filled triangle sitting behind its own stroke outline, which wasn't the intent. Symmetrically, the body's filled path needed `stroke="none"` so it doesn't pick up an unwanted default 1px stroke outline once the SVG element itself has a `stroke` color set via CSS.

**This is the one place in the whole file that uses `stroke-linecap`/`stroke-linejoin`** — checked, no other icon anywhere sets either, so this is a deliberate, scoped exception for this one icon's friendlier look, not a change to the app's general icon style.

**Verified the same way as both earlier rounds**: real markup, real 46px size, all 11 denomination hues, both themes — screenshots shown in the conversation. Logo/no-logo boundary reconfirmed directly against `churchCard()`'s output. No console errors. Build `2026-09-11-v291`.

---

## Fixed: uncaught error on a fresh `#church/<name>` (or `#event/<id>`) deep link

Flagged as a separate task a few fixes back, now root-caused and fixed. Loading a URL like `#church/Mercy%20Church%20San%20Antonio` as a genuinely fresh page load (not in-app SPA navigation) threw an uncaught promise rejection: `Cannot read properties of undefined (reading 'from')`.

**Root cause, confirmed by reading the actual script structure, not guessed:** `showRouteFromHash(true)` is called unconditionally near the bottom of the earlier, plain (non-module) `<script>` block. `window.supabase` isn't assigned until `const supabase = createClient(...); window.supabase = supabase;` inside the *later*, deferred `<script type="module">` block (it has to be a module, since only module scripts support the top-level `import` it uses to pull in `@supabase/supabase-js`). Module scripts always execute after classic scripts of the same document — so on every single fresh load, `showRouteFromHash(true)`'s first call is guaranteed to run before `window.supabase` exists, not just occasionally. It only ever produced a *visible* crash for routes that immediately touch `window.supabase` synchronously during that first pass — `#church/<name>` and `#event/<id>` — because `findOrFetchChurchByName()`/`findOrFetchEventById()` call `window.supabase.from(...)` with no readiness check. Other routes (home, directory, etc.) don't touch it during this same first pass, so they never crashed.

**The recovery the user's own testing already noticed** (page still renders correctly despite the error) turned out to be a *second*, already-existing, already-documented call to `showRouteFromHash(true)` from inside the module script itself, once it finishes (`loadRealChurches()`, plus a couple of sibling call sites) — added for the exact same reason in an earlier, unrelated fix (its own comment there already explains the identical race for the Profile page). That's why the content always ended up correct: the crash aborted the *first* pass entirely (before it could call `go()` or do anything user-visible), and the guaranteed second pass did the real work once `window.supabase` actually existed.

**Fix — matches the codebase's own existing convention for this exact situation** (`if (!window.supabase) return; // not ready yet on the earliest calls`, already used in a few other places) rather than introducing a new readiness-promise abstraction: `findOrFetchChurchByName()`/`findOrFetchEventById()` now check `window.supabase` before touching it and return `null` instead of throwing. The trickier part was the caller: `showRouteFromHash`'s existing logic was `if (matched) populate(); else go(fallbackRoute)` — simply returning `null` on "not ready" would have hit that `else` and *actively redirected to the directory/events listing* on the first pass before the second pass corrected it back, a new visible flash that doesn't happen today (today the exception aborts the function before `go()` is ever reached). Changed the `else` to `else if (window.supabase)` in both the church and event branches, so "not ready yet" now does nothing on the first pass (matching today's actual de facto behavior, just without the crash), while "confirmed not found once supabase is ready" still redirects exactly as before.

**Checked for the same latent bug elsewhere before calling this done**: the `group`/`admin-church`/`create-event` branches of the same function all call functions defined *inside* the module script itself (`populateGroupPage`, `populateAdminChurchPage`, `editEvent`) and are already guarded with `typeof window.X === 'function'` checks — safe by construction, no fix needed there.

**Verified live**, not just reasoned through: the exact reported URL now loads with zero console errors and still correctly populates "Mercy Church San Antonio" (confirming the recovery pass still works); a bare `#church` (no key) still redirects to `#directory` immediately, unaffected; a deliberately nonexistent church name still correctly redirects to `#directory` once Supabase finishes loading, confirming the legitimate not-found path wasn't broken by the `else if` change; a plain homepage load is unaffected. Build `2026-09-11-v292`.

---

## Church icon, round 4: back to sharp fill, cross fused directly onto the roof

Round 3's rounded/stroked style, per a fresh reference the user liked much better, needed to go back to a sharp flat-icon silhouette — but this time with the cross sitting flush on the roof peak (no gap, no separate floating steeple), a wider/flatter roof, and a rounded-arch door.

**Reverted to pure fill, no strokes at all** — round 3's `.thumb--denom svg` CSS had grown a `stroke` alongside `fill` specifically to tint the rounded chevron roof and floating cross, both of which are gone now. Removed `stroke` from that rule entirely rather than leaving it as dead weight, since an unused `stroke` color with the SVG's default `stroke-width:1` would silently reappear as an unwanted 1px outline the moment any element in a future revision forgot to opt out.

**The cross, roof, and body are still three separate layered shapes, not one traced path** — same technique as round 2, just re-tuned: two `<rect>`s for the cross (sized and positioned so its base overlaps the roof's apex by a full unit, guaranteeing no visible seam between "cross" and "roof" even though they're independent elements), a wider/flatter roof triangle, and the body + rounded-arch door cutout via `fill-rule="evenodd"` (identical mechanism to round 2's door, just re-proportioned — narrower, taller, matching the new reference more closely).

**Verified the same way as every prior round**: real markup, real 46px size, all 11 denomination hues, both themes — screenshots shown in the conversation. Logo/no-logo boundary reconfirmed directly against `churchCard()`'s output. No console errors. Build `2026-09-11-v293`.

---

## Church icon, round 5: taller cross, bigger overall

Two small follow-up tweaks to round 4's design, per a closer look at the reference: the cross needed to read taller, and the whole icon needed to sit a bit larger in the card.

**Size**: `.thumb--denom svg` went from 46px to 54px -- CSS-only, nothing about the icon's own coordinates changed for this part.

**Taller cross without touching the roof or body**: the cross's vertical bar had nowhere left to grow within the existing `viewBox="0 0 24 24"` -- it already started almost at the top edge (y=0.5). Rather than shrinking the roof/body to free up room (which would have changed proportions nobody asked to change), pulled the viewBox's top edge up instead: `viewBox="0 -3 24 27"`. The cross extends into that new headroom (vertical bar now spans y=-2.5 to y=6, up from y=0.5 to y=6 -- same bottom/roof-junction point, so the "fused to the roof" connection from round 4 is completely undisturbed), while the roof and body paths are byte-for-byte what they were in round 4. The viewBox's aspect ratio technically shifts from 1:1 to 24:27, but rendered into a square box that's an imperceptible ~2px letterbox on a 54px icon, not a visible distortion -- confirmed by looking at it, not just by the math.

**Verified the same way as every prior round**: real markup, real 54px size, all 11 denomination hues, both themes -- screenshots shown in the conversation, no clipping from the wider viewBox in either theme. Logo/no-logo boundary reconfirmed directly against `churchCard()`'s output. No console errors. Build `2026-09-11-v294`.

---

## Four directory/homepage UI fixes: dropdown clipping, dropdown position, hero button contrast

**1. Denomination dropdown was too short.** `max-height:320px` clipped the list to a handful of items before scrolling. Bumped to `max-height:min(440px, calc(100vh - 140px))` on both the directory and events dropdowns — taller on a normal screen, but capped against the actual viewport height so it can't overflow off-screen on a short one.

**2. & 3. Dropdown used `position:fixed` with viewport coordinates computed once, at open time.** This is the real bug behind two symptoms reported together: it "stays static on the page even when scrolling — covering search results" and it "isn't centered on [re]opening because the static dropdown remains where it was opened." Both are the same root cause: `getBoundingClientRect()` (viewport-relative) was captured once when the dropdown opened and baked into `position:fixed` coordinates, which by definition don't move with the page. Scroll afterward, and the panel stays glued to that same spot on *screen*, drifting away from its own trigger button and sitting on top of whatever content had since scrolled into that spot.

Fixed by giving `.filter-group` (the button+panel's immediate wrapper, on both the directory and events pages) `position:relative`, switching both dropdown panels to `position:absolute`, and computing their `top`/`left`/`width` from `offsetTop`/`offsetLeft`/`offsetWidth` (relative to that same wrapper) instead of `getBoundingClientRect()`. This puts the panel in the same document flow as its button, so it scrolls together with it like any other in-page element — including while `.filter-panel` is mid-scroll under its own `position:sticky` on desktop. Verified live, not just reasoned through: opened the dropdown, scrolled the page 800px down, and confirmed via `getBoundingClientRect()` that the panel was still exactly 5.6px below and pixel-aligned with its button at that scroll position — the same check repeated on the events page's identical dropdown.

**4. "Browse churches" (hero button) was invisible against its own background in light mode, worst on mobile.** `.search-bar button` used `background:var(--brand)` — the exact same navy as `.hero`'s own background, which doesn't change between themes. A `html[data-theme="dark"] .search-bar button{background:var(--gold);...}` override already existed and fixed it for dark mode, but nothing equivalent existed for light mode, where the button was left the same color as the hero behind it. On desktop this was partly masked by `.search-bar`'s own light card background creating a visible boundary around the button either way; on mobile, that card background disappears (`.search-bar{background:transparent}` in the mobile media query) and the button sits directly against the hero with nothing to set it apart. Moved the gold/brand styling into the base `.search-bar button` rule (removing the now-redundant dark-mode-only override) so both themes get the same, already-proven-correct contrast — verified live on a mobile viewport in light mode. Build `2026-09-11-v295`.

---

## Church names: strip a trailing corporate suffix at display time

Same root cause and same fix philosophy as the address ALL-CAPS fix: the IRS EO Business Master File source (and plenty of real church names generally) end in a literal corporate suffix — "Overflow Worship Center Inc" — that reads oddly on a public-facing directory. Fixed the same way, for the same reason: a display-time function, not a data mutation, so it covers every row (imported yesterday or written next year) with no migration and no bulk `UPDATE` risk, and reuses the exact word-boundary-matching principle from both the earlier name fix (connector words) and the address fix (state codes, directionals) rather than a plain substring check — the lesson from "ministry"/"Administry" and "Churchill"/"church" earlier this session.

**`displayChurchName()`**, next to `titleCaseAddress`/`translateDenomination`: `/,?\s*\b(?:incorporated|corporation|inc|corp|l\.l\.c\.|llc|ltd|limited)\.?\s*$/i`, anchored to the very end of the string. `\b` is what keeps this from ever matching mid-name — there's no real church name where "Inc"/"Ltd"/etc. show up as a coincidental tail of a longer word the way "Zinc" ends in "inc", but the anchor-plus-boundary combination is what guarantees it regardless. An optional leading comma/whitespace catches "Grace Church, Inc."; a second cleanup pass mops up anything left over; a name that was somehow *only* a suffix falls back to the original rather than rendering blank.

**Applied at every place a church name renders as visible text** — more call sites than the address fix, since name is used far more pervasively: both directory card layouts (`churchCard`/`churchRow`), the profile page (heading, the repeated name line, the no-description fallback text, the Google Maps marker tooltip), the church switcher dropdown, the My Churches tile, the multi-church Overview's staff cards, the create-event and team-invite church pickers, and four separate admin views (the pending-verification list, two "all churches" list variants, and the admin church detail page). Two call sites store the *already-stripped* name once, at the point it's captured, rather than re-stripping at the point of use — `window.currentPageChurchName` (feeds only a modal title) and a claim banner's `data-claim-church-name` attribute (feeds only the claim modal's display) — traced both to their single actual consumer first to confirm neither is used for any lookup before doing that.

**Deliberately left untouched**: every `href="#church/<name>"` and `data-church-name` attribute (routing has to match the real stored name to find the record), the `churches`/`events` array lookups and dedupe-key building (`c.name === name`, `c.name.toLowerCase() + '|' + ...`), the raw-row-to-display-object mapping (`name: row.name`), the register-church edit form's name input (shows the true stored value while editing, same principle as the address form fields), and the admin CSV-import candidate/dedupe logic. None of those care about display formatting, and all of them need to agree with whatever's actually in the database.

**Verified**: the exact regex tested standalone against all 10 suffix variants (`Inc`, `Inc.`, `Incorporated`, `Corp`, `Corp.`, `Corporation`, `LLC`, `L.L.C.`, `Ltd`, `Ltd.`, `Limited`) plus a comma-preceded case, a name with no suffix at all, and two false-positive guards ("Zinc Fellowship Church," "Vincent Memorial Chapel") — all 21 cases correct. Re-confirmed live in the browser via `window.displayChurchName()`. Built a fake church object through the real `churchCard()` and confirmed the visible `<h3>` is stripped while `href`/`data-church-name` on the very same card stay fully raw. Then found a real match in the live San Antonio data (295 churches in the batch end in one of these suffixes) and loaded its actual profile page end-to-end: "Mt Horeb International Prayer Camp Ministries Inc" renders as "Mt Horeb International Prayer Camp Ministries," routed to correctly via its full raw name in the URL. No console errors. Build `2026-09-11-v296`.

---

## Search bar icon buttons: matched to the site's actual primary-CTA color

`#dir-location-search-btn` and `#events-location-search-btn` (the magnifying-glass icon button attached to each page's location search input) used `background:var(--brand);color:#fff` -- navy with a white icon. The site's actual primary-CTA style, `.btn-gold`, is `background:var(--gold);color:var(--brand)` -- confirmed by checking, not assumed. Against a mostly-navy dark-mode page, the navy button read as an in-between shade: not quite blending into the bar, not quite reading as a deliberate action button either. Switched both to the same gold/brand pairing already proven correct (it's also what the hero "Browse churches" button now uses, from the previous round of fixes). Verified live on both the directory and events pages in dark mode. Build `2026-09-11-v297`.

---

## Admin church detail: added an edit form for name/denomination/address/phone/website

Checked first, per the actual ask: the admin church detail page (`populateAdminChurchPage`) only ever rendered these fields as read-only `<p>` tags -- no edit capability existed at all. This is the *only* way an **unclaimed** church's info can ever be corrected -- there's no owner to fix it from the normal dashboard -- so it needed to exist independent of the claim flow, though it works identically for a claimed church too.

**New migration**, `021_admin_update_church_details.sql` (not yet run -- needs the usual manual step in the Supabase SQL Editor): `admin_update_church_details()`, `security definer` + `is_platform_admin()`-gated, since the normal `churches` UPDATE RLS is owner-only. Re-geocodes only when the caller says the address actually changed (`p_update_coords`), so an unrelated name/phone/website fix never touches already-good coordinates; a failed or empty geocode result explicitly clears `lat`/`lng` to null rather than leaving them silently pointing at the old address.

**"Any admin correction is final" -- why no lock/flag column was needed to guarantee that.** Traced exactly what `displayChurchName()`/`titleCaseAddress()` actually do before deciding: both are narrowly scoped (a trailing-corporate-suffix strip; state-code/directional/PO-Box casing) and are no-ops on input that's already well-formed -- neither does any *general* re-casing of a name or address. "RISE Church" doesn't end in a corporate suffix, so `displayChurchName()` returns it completely unchanged; there's nothing for a "manually corrected, don't re-process" flag to actually protect against today. Documented this reasoning directly in the code as a call-out for later: if either function is ever generalized into broader re-casing, an admin-authored value would need revisiting then, not preemptively now.

**Found and fixed a real gap while testing, not shipped-then-discovered**: `geocodeAddressGoogle()` has no timeout of its own -- it only resolves when Google's own callback fires. Live testing surfaced a `RefererNotAllowedMapError` in this local dev environment (`localhost` isn't an authorized referrer for the Maps key; production isn't affected) that caused the callback to simply never fire -- and the Save button stayed disabled indefinitely, with no way to recover short of reloading the page. Wrapped the geocode call in an 8-second `Promise.race`; a timeout is now treated exactly like "no result" (text fields still save, coordinates come back null, the existing "couldn't find that address" warning shows) rather than hanging forever. This protects against any real-world cause of a hung callback, not just the local-dev referrer issue that happened to surface it.

**Verified end-to-end against a stateful stub** (real Supabase calls aren't available until the migration is run) that mirrors exactly what the migration's own `UPDATE` does: opened the form, confirmed it pre-fills with the true raw stored values (not the display-transformed ones); changed the name from "Rise Church" to "RISE Church" and saved -- confirmed the RPC received exactly `{p_name: "RISE Church", ..., p_update_coords: false}` (no geocode call fired, correctly, since the address wasn't touched), and confirmed the page re-rendered showing "RISE Church" with the acronym's capitalization intact after the full save-and-refresh cycle; separately changed only the address and confirmed a geocode attempt fired, timed out safely (per the fix above), saved the new address text, cleared coordinates, and showed the expected warning; confirmed submitting a blank name is rejected client-side with the form left open and nothing sent to the RPC. No console errors beyond the referrer-restriction one described above (local-dev only, unrelated to the code itself).

**Still needed before this is real**: run `021_admin_update_church_details.sql` in the Supabase SQL Editor. Once that's done, the "Rise Church" → "RISE Church" correction can be made for real through the new form as the first live test case. Build `2026-09-11-v297`.

---

## Unclaimed church profiles: turned the claim CTA into an actual conversion moment

The claim flow itself (`#church-claim-modal`, `church_claim_requests` insert, admin's approve/reject via `review_church_claim`) already existed and worked -- this wasn't rebuilt. The problem was visibility: `#church-unclaimed-banner` rendered as a single line of small (13.5px), muted light-gray text (`#C7CCD8`, no background, no border) sitting *after* the eyebrow, name, badges, the distance/service-time `.sub` line, and the managed-line placeholder -- the least visually weighted thing in the whole header, on a directory carrying 858+ mostly-unclaimed listings. Easy to scroll straight past.

**Fix**: moved the same `#church-unclaimed-banner` element (same id, same `#church-claim-btn`, same `data-claim-church-id`/`data-claim-church-name` attributes the existing JS already reads -- nothing about the claim mechanism itself changed) up to directly under the name/badges, before the `.sub` line, and restyled it as a bordered gold-accent card with a bold headline ("Is this your church? Claim your free FaithDock profile.") and a `.btn-gold` button instead of `.btn-outline` -- the same gold/brand pairing used for every other primary CTA on the site.

**Events-tab empty state now pivots, but only when there's actually no owner to blame.** A brand-new `#church-no-events-unclaimed` card (gold-bordered, matching treatment) sits alongside the existing plain `#church-no-events` message inside `#church-tab-events`. `loadChurchEvents()` now branches on `!!c.ownerId` (the same signal `populateChurchPage()` already uses for the managed-line/badges) when the event list comes back empty: claimed + no events still shows the plain "No upcoming events posted yet."; unclaimed + no events shows "This church hasn't added events yet. Are you a leader here? Claim this profile to start posting." alongside its own claim button. A claimed church with a genuinely quiet calendar was never the problem this was solving, so it was left alone on purpose.

**Two claim buttons, one flow.** Adding a second claim trigger (the Events-tab pivot's button) meant the old direct `document.getElementById('church-claim-btn').addEventListener(...)` binding could no longer target both buttons by id. Refactored to a delegated `document.addEventListener('click', ...)` matching `closest('#church-claim-btn, #church-events-claim-btn')` -- both buttons funnel into the exact same handler, which reads the church id/name off `#church-unclaimed-banner`'s data attributes regardless of which button was actually clicked (that data lives on the banner, not on either button, so this was already button-agnostic). No change to `openClaimModal()`, the submit handler, or anything on the admin side.

**Verified live against the real backend** (real Supabase, 858 real churches, not a stub): loaded RISE Church's real profile (confirmed still unclaimed) and saw the new prominent CTA card render correctly in both English and Spanish. Switched to its Events tab and confirmed the pivot card renders with the correct copy and its own claim button. Clicking either the header CTA or the Events-tab button while signed out correctly triggers the existing "sign in to claim a church" gate -- confirmed the exact same behavior from both buttons, proving the delegation refactor didn't break the trigger. Stubbed a signed-in user (`supabase.auth.getUser`) just long enough to confirm the modal opens pre-filled with the correct church name and email from either button -- then deliberately closed the modal **without submitting** and restored the real `getUser`, since this is a live production database and a fake claim request would have landed in the real admin queue. Separately confirmed the claimed-vs-unclaimed branch in `loadChurchEvents()` directly: a crafted claimed-church object with zero events correctly showed the plain empty state with the pivot card hidden (`display:none` on `#church-no-events-unclaimed`, `block` on `#church-no-events`). The admin-side approve/reject code (`get_pending_church_claims`, `review_church_claim`) was not touched by this change at all, so it needs no separate re-verification.

**Also noticed in passing, not part of this fix**: "RISE Church" (the migration-021 test case from the previous entry) is already rendering with its correct capitalization in production -- the migration must have been run and the correction made for real since that work landed. Build `2026-09-11-v298`.

---

## Church profile "Grace Fellowship" flash: the static template itself carried fake sample content

Reported symptom: the About tab briefly showed placeholder text mentioning "Grace Church" before correcting to "[real name] hasn't added a description yet." Same async-flash family as the earlier nav/pricing audit (`## Fixed 4 async-state flashes`, build `v284`), just in a spot that one didn't cover.

**What "Grace Church" actually was**: `#page-church`'s static HTML (the whole church-profile template) is a hand-authored design mockup, pre-filled with realistic sample content for a fictional "Grace Fellowship Church" -- `#church-name`, `#church-eyebrow` ("Non-denominational · Austin, TX"), `#church-dist` ("0.8 mi away"), `#church-next` ("Next service Sun 9:00 AM"), `#church-home-count` ("142 Church Home members"), `#church-description` (a full fake paragraph), `#church-description-2` (a second fake paragraph), `#church-service-times` ("Sundays, 9:00 & 11:00 AM"), and `#church-address` ("1420 Pleasant Valley Rd, Austin, TX") all had real-looking hardcoded text sitting in the raw markup, same as a Figma-style mockup would. `populateChurchPage(c)` overwrites every one of these unconditionally on every real call -- so the only way the sample text is ever actually seen is a window where the page section is visible *before* that function has run even once.

**Root cause of that window, traced through the actual routing code**: `go(route)` (the function that adds `.active` to `#page-church`, the only thing that makes it visible -- `section.page{display:none}` / `.active{display:block}`) is called unconditionally at the end of `showRouteFromHash()`, regardless of whether the church was actually found and populated. On a genuine fresh page load / refresh / bookmark of `#church/<name>` (not in-app SPA navigation, which already populates before calling `go()` -- confirmed by reading that code path too, no bug there), `showRouteFromHash`'s *first* pass runs before the deferred module script has created `window.supabase` at all. `findOrFetchChurchByName()` correctly returns `null` in that case (a related earlier fix, build `v292`, changed a crash there into this safe null instead) -- but nothing stopped `go()` a few lines later from still revealing `#page-church` with whatever's sitting in the static template, since `populateChurchPage()` was simply never called on that pass. A second, already-existing call to `showRouteFromHash(true)` fires once the module script finishes and Supabase is real, correctly re-populating everything -- which is the "corrects to hasn't added a description yet" half of the reported symptom. The `v292` fix solved the crash but left this exact flash in place as a side effect, since it was never in scope there.

**Fix, matching the "don't paint a default until the real record is in hand" instruction literally**: rather than adding new hide/reveal JS state (the `hideUntilKnown()`/`visibility:hidden` approach used for Pricing's ambiguous-ownership case), just removed the fake sample text from the static template for every field `populateChurchPage()` always overwrites unconditionally -- name, eyebrow, dist, next, home-count, description all now start as empty elements. `#church-description-2` and `#church-service-times` additionally got `style="display:none"` added to their static markup (they didn't have it before, unlike every one of their true siblings -- `church-phone-row`, `church-website-row`, `church-managed-line`, etc. all already start hidden) since both are genuinely conditional (`if (c.description2) {...} else { display:none }` / same pattern for service times) and the plain "start hidden like every other conditional field already does" fix is simpler than adding new JS logic. `#church-address` keeps its icon markup but the fake street address text is gone -- its `innerHTML` gets fully rebuilt by `populateChurchPage()` on every call regardless, unconditionally, so nothing else needed to change there.

**Grepped `#page-church` specifically for every other candidate** (phone, website, social links, badges, managed-line, unclaimed-banner, map-unavailable, location-address, the denomination tag, the sidebar's duplicate name heading): all of them already either start empty with no fallback text (`#church-details-name`, `#church-location-address`) or already default `display:none` correctly (`#church-phone-row`, `#church-website-row`, `#church-social-row`, `#church-managed-line`, `#church-unclaimed-banner`, `#church-partner-badge`, `#church-verified-badge`, `#church-details-denom-tag`, `#church-map-unavailable`) -- no flash risk in any of them, nothing else to fix on this page.

**Found but explicitly out of scope here (flagged separately, not fixed)**: the Event Detail page (`#page-event`) has the exact same design pattern and the exact same class of bug -- `#event-title` ("Fall Community Picnic"), the "Hosted by" church link, `#event-description`/`#event-description-2`, `#event-when`, `#event-location` are all hardcoded sample text in the static template, unconditionally overwritten by `populateEventPage()`, and reachable via the identical fresh-load race in the `resolved.base === 'event'` branch of the same `showRouteFromHash()` function. The user's ask was specifically the church-profile page; this is the same fix applied to a different page, not something this task covered.

**Verified**: cold-inspected the actual template DOM (never having visited any church route this page load, so this is exactly what a fresh `#church/<name>` load paints on its first pass) -- all 9 fields confirmed empty text, `#church-description-2`/`#church-service-times` confirmed `display:none`. Then did a real fresh navigation (not an in-app click) to RISE Church's real `#church/RISE%20Church` URL against the live backend -- name, claim CTA, and the correct "RISE Church hasn't added a description yet." fallback all rendered correctly, confirming the unconditional-overwrite population path still works exactly as before. Confirmed `#church-service-times`' hidden-by-default change doesn't block its reveal path by reading `populateChurchPage()`: the truthy branch sets `style.display = 'flex'` itself unconditionally, so it overrides any static default either way regardless of which one is set -- this was verified by direct code inspection since no real church in the current dataset happens to have service times filled in to click through live. Only pre-existing, unrelated console errors present (Cloudflare Turnstile on localhost, already documented). Build `2026-09-12-v299`.

---

## "Sign out of all other devices," an AI-assistant teaser, and tightened free-tier pricing copy

Three independent, unrelated changes shipped together (a fourth, the Verified-badge tooltip, was held back -- see the note at the very end of this entry).

**"Sign out of all other devices"** (`#profile-signout-others-btn`, Account settings, right after Change Password): checked Supabase Auth's own capability before building anything -- `supabase.auth.signOut({ scope: 'others' })` (supported since supabase-js 2.31; this project pulls `@supabase/supabase-js@2` off esm.sh, so it's covered) revokes every refresh token for the account except the one behind the current session, entirely server-side. No custom session-tracking table, no new schema -- this is a genuinely thin wrapper, mirroring the exact same disable-button / status-message pattern already used by the adjacent "Update password" handler (`var(--clay)` for an error, `var(--sage)` for success). Confirmed live that this exact call shape (`{scope:'others'}`) is accepted by the installed supabase-js version and returns a clean `{error: null}` rather than throwing, even with no active session -- couldn't go further than that without a real second-device session to actually revoke (same "no test account handy" limit noted elsewhere in this file).

**AI Writing Assistant marketing line**: added a small, muted-gray, un-gated caption -- "Create better event announcements in seconds with the Writing Assistant below." -- directly above the existing `#ai-writing-assistant`/`#ai-writing-assistant-locked` blocks on the create-event form (right after the description field's character counter). Deliberately plain text with no border/background, unlike the locked-plan upsell box already sitting right below it, so it reads as a hint, not a second competing CTA. Shows for every plan tier unconditionally (both the unlocked toggle and the locked upsell message are already mutually exclusive and gated by JS; this caption isn't gated by either, so it always sits directly above whichever one is showing).

**Free-tier pricing copy tightened**, on both the Pricing page (`pricing.free.tagline`) and the homepage's "For churches" section lead paragraph (`home.fc.lead`) -- the two actual free-tier-pitch spots found by grep; no others existed. **Found and fixed a real layout bug in the process**: the Pricing page's tagline (`.price-tagline`) is deliberately clamped to exactly 4 lines (`-webkit-line-clamp:4`, with a CSS comment reading "the copy is written to fit" -- no `text-overflow:ellipsis`, so an overflow is a silent hard cut, not a visible "..."). The user's suggested full wording ("Get listed on FaithDock for free — no credit card, no subscription. Upgrade when you want event management, registration, groups, giving, and other tools.") is ~157 characters and actually overflowed to 6 lines at the card's real rendered width, cutting off mid-sentence -- caught by live-testing the actual change rather than assuming prose that reads fine in the abstract fits a hard-clamped card. Tightened to two shorter sentences preserving every requested idea (free, no card, no subscription, what upgrading unlocks) -- confirmed via direct DOM measurement (`scrollHeight` vs `clientHeight`) at three widths spanning the risky range (861px, 1280px, 1440px -- the `.price-tagline` clamp only applies above the 860px tablet breakpoint, so this is the whole width range where the bug could ever show), then reconfirmed visually in both languages after a real reload. The Spanish translation needed its own separate trim (Spanish ran longer than the equivalent English at nearly every draft length tried) -- not a blind translation of the final English copy. The homepage's `home.fc.lead` has no such clamp (`max-width:620px`, wraps freely) so the fuller original wording was kept there.

**Held back, not implemented**: a hover tooltip on the "Verified" badge. The user's suggested wording ("FaithDock has confirmed this profile is managed by an authorized representative of the church") describes something different from what `verification_status` actually gates in this codebase -- confirmed by reading `loadGivingStatus()`'s own comment ("none of the actual Stripe connection flow is reachable until a church is verified") and `churchStatusTag()`'s own comment ("claimed + verified giving account -> Verified church"): this status is specifically about a connected Stripe/giving account, not a general check that the account holder is an authorized church representative. The existing tooltip on `#church-verified-badge` (added earlier this session) was deliberately worded to avoid exactly this overclaim ("...doesn't imply anything else about the church"). Shipping the requested wording as-is would reverse that earlier, deliberate scoping decision -- asked the user how they want to resolve this before touching it rather than guessing.

---

## Verified-badge tooltip: covering the directory card, not just the profile page

Follow-up to the held-back item above. The user confirmed the existing tooltip wording is correctly scoped (giving verification only, not a general legitimacy claim) and re-scoped the ask to an audit: is it actually showing everywhere the badge appears? It wasn't -- `#church-verified-badge` (the profile page) already had it via `data-i18n-title`, but the "Verified church" tag built by `churchStatusTag()` ([index.html:5836](index.html:5836)) -- shared by the directory grid, list view, and the homepage "Churches near you" strip, since `churchCard()`/`churchRow()` both call it -- had no `title` at all. One shared function, so one fix covers all three surfaces.

**Used a plain `title="..."` with `window.t()` resolved inline, not `data-i18n-title`, and this wasn't just a style preference.** `churchStatusTag()` builds its return value as a concatenated string fresh on every card render (search results, pagination, homepage strip) -- not static DOM. `applyTranslations()` (the function that actually reads `data-i18n-title` and turns it into a real `title` attribute) only runs twice total: once at initial page load, before any directory search has even happened, and once on a language-toggle click -- and that language-toggle handler has its own explicit comment stating Directory/Events search results are *deliberately excluded* from its re-render sweep (re-fetching would reset in-progress pagination, a worse tradeoff than leaving stale-language card text in place). A `data-i18n-title` attribute on this markup would therefore never get resolved into an actual `title` by anything, ever -- confirmed by reading both call sites of `applyTranslations()`, not assumed. Inline `window.t()` matches how the tag's own visible label text is already built one line below it, and correctly reflects whatever language is active at the actual moment a card renders.

**Verified**: called `churchStatusTag()` directly against a crafted claimed+free+verified-giving object and confirmed the returned HTML carries the exact existing tooltip wording in the `title` attribute, in both English and Spanish (language-switched live, re-called, re-confirmed) -- word-for-word identical to the profile page's existing tooltip, since both now read the same `church.verifiedBadgeTooltip` key. Called it again for a paid+verified church (partner badge), a claimed-but-unverified church (managed line), and an unclaimed church (empty string) -- all three came back byte-for-byte unchanged, confirming the fix is scoped to only the verified branch. Also called `churchCard()` directly with a verified test church and confirmed the `title` attribute lands correctly inside the actual card markup that would render on a real page, not just in the isolated tag string. Build `2026-09-12-v301`.

---

## Removed the Partner tag from cards, and the Verified badge everywhere -- plus a real stale-cache bug found while testing

Immediate follow-up to the tooltip work above, from live feedback on an actual screenshot. Three asks: drop the Partner tag from directory cards (keep the profile-page star), remove the Verified badge (tag + tooltip, cards and profile page both) entirely, and diagnose a real bug hit while testing the removal.

**Live-database check before removing anything**: exactly one church currently has `verification_status = 'verified'` -- "Catholic Church of San Antonio" (`4b2cb761-3d49-4d47-ac7f-81c98308daee`), claimed, `plan_type: standard`. Worth noting: this same id is one of five churches migration 018 explicitly hides as a test/internal church (`update churches set is_hidden = true where id in (...)`) -- it's showing up in live search regardless, meaning that hide either never got applied to this row or was reversed afterward; unrelated to this task, not touched.

**Partner tag removed from `churchStatusTag()`** (the shared function behind the directory grid, list view, and homepage strip), leaving only the claimed/unclaimed distinction there (Managed by this church, or nothing). `#church-partner-badge` on the profile page -- the star version -- is untouched, still driven by the same `isPaid` check in `populateChurchPage()`.

**Verified badge removed completely**: the `churchStatusTag()` branch (tag + the `title` tooltip added earlier this session), `#church-verified-badge` and its surrounding toggle logic (`isVerified`, the whole element) in `populateChurchPage()`, the now-fully-unused `church.verifiedBadge`/`church.verifiedBadgeTooltip` i18n keys (both languages) -- grepped after for any remaining reference, zero hits. Deliberately left alone: the `verification_status` column itself, `review_church_verification` and every other RPC that reads or writes it, `loadGivingStatus()`'s Stripe-connection gate, and the admin-only `#admin-church-verified-badge`/`admin.verified` label on the admin church-detail page (a different element, a different i18n key, internal-only -- not the public badge this ask was about). This is a display removal, not a data or logic change, by construction: nothing touched here writes to or reads `verification_status` for any decision-making purpose, only for whether to paint a tag.

**The bug, diagnosed (not fixed -- this was scoped as diagnosis)**: reported as "toggled a test church's verification off in the admin panel, the badge kept showing verified." Two real, separate things found reading the actual code, not guessed:

1. **A genuine, confirmed stale-cache bug**, and the more likely actual cause. `findOrFetchChurchByName()` ([index.html:6799](index.html:6799)) checks the in-memory `churches` array first and returns a cached match immediately if the name's already there -- with no expiration, ever, for the lifetime of the tab. Once a church has been loaded once this session (search result, homepage strip, an earlier profile-page visit), every later visit to that same church's profile page reuses the exact same cached object, `verification_status` included, regardless of what an admin changes in the database afterward. Only a hard reload (which resets the in-file `churches` array back to its initial state) forces a fresh fetch. **Proven live, not just reasoned through**: loaded the real church's profile page, confirmed it landed in `window.churches`, then manually overwrote that one cached object's `verificationStatus` to an obviously-fake sentinel value and called `findOrFetchChurchByName()` for the same name again -- it returned the exact same object reference with the fake value still on it, never re-querying Supabase. This same caching bug would just as easily leave *any* other admin-edited field (address, phone, description) stale on an already-visited profile page too, not only verification -- worth keeping in mind if a similar "I changed it but the page still shows the old value" report comes in again.

2. **A real, separate defect found by contrast with its own sibling code**: the approve/reject/unverify click handler (`review_church_verification`, [index.html:19333](index.html:19333)) never checks the RPC's `error` result at all -- `await supabase.rpc(...)` with nothing destructured, no `if (error)`, no message shown -- then unconditionally calls `loadAdminPanel()` regardless of whether the write actually succeeded. The near-identical `admin_set_church_hidden` handler two blocks below it does check `error` and `alert()`s it. Confirmed the RPC function itself does exist server-side and does correctly permission-gate (`supabase.rpc('review_church_verification', {...})` from an unauthenticated session returned a clean `P0001` "Only platform admins can review verification requests" -- a real error *from inside the function body*, not a missing-function error) -- so this specific defect wasn't provably the cause of what was seen this time, but it means any future failure (an expired session, a permission edge case) would be completely silent and indistinguishable from "the toggle did nothing," same as the symptom reported. Not fixed here (diagnosis was the ask), but worth fixing given it sits right next to a correct example of the same pattern.

**The functionally important part, confirmed separately from the display bug**: `loadGivingStatus()` ([index.html:15783](index.html:15783)) -- the actual gate on Stripe connection access -- does not go through `findOrFetchChurchByName()` or the `churches` array at all. It runs its own direct, uncached `supabase.from('churches').select('stripe_account_id, stripe_onboarding_complete, verification_status').eq('id', myChurch.id)` on every single call (confirmed by reading every call site: dashboard load, giving tab open, right after a verification request is submitted -- no wrapping cache anywhere in that chain). So regardless of the stale-badge bug above, the real gate re-evaluates fresh every time and will correctly block Stripe access the moment `verification_status` actually changes in the database -- the badge bug is cosmetic/display-only, the enforcement was never affected by it.

**Verified**: real search for the affected church post-removal shows only "Católica" and "Gestionada por esta iglesia" on its card (no Partner, no Verified) despite being paid and verified; its profile page shows "★ Socia de FaithDock" (Partner, untouched, star intact) with no Verified badge anywhere. No new console errors (only the pre-existing, unrelated localhost Turnstile errors). Build `2026-09-12-v302`.

---

## Follow-up: fixed both bugs from the diagnostic above

**1. `findOrFetchChurchByName()` now expires its cache after 45s** instead of caching a church forever for the life of the tab. A small `churchCacheFetchedAt` map (keyed by name, alongside a `CHURCH_CACHE_TTL_MS = 45000`) tracks when each real church was actually last fetched; a cache hit older than that re-queries Supabase before returning. Demo/sample churches (`real` falsy, from the mock array at the top of the file) are explicitly exempted from the TTL -- they have no backing DB row to ever go stale against, so they still return instantly, same as before.

**The tricky part was refreshing without creating duplicates.** The lookup (`churches.filter(c => c.name === name)[0]`) always takes the *first* array match -- so on a TTL-expired refetch, pushing a second object for the same name would leave the stale original permanently winning forever, silently undoing the whole fix. Refreshing now copies every field from the freshly-fetched row onto the *existing* cached object in place (`for (var k in mapped) found[k] = mapped[k]`) instead of pushing a new one, so there's still exactly one entry per church name after any number of refetches.

**One behavior preserved on purpose, not by accident**: the pre-existing "Supabase not ready yet" early-return (`showRouteFromHash`'s very first pass, before the deferred module script has created `window.supabase`) used to return the cached object unconditionally before ever reaching that check. Now that a TTL exists, an *expired* entry with `!window.supabase` needed a decision -- falls back to the stale cached copy rather than `null`, since a stale-but-present church is still a better outcome than the profile page bouncing to "not found" during that brief startup race. A genuinely empty query result (Supabase confirms zero rows -- a real rename/delete) still returns `null` as before, not a stale fallback -- silently claiming a deleted church still exists would be worse than the existing not-found handling.

**Verified live with real elapsed time, not simulated**: patched `window.fetch` to count real network calls matching this church's row lookup specifically (the browser's own buffered network-request log had already been flooded past capacity by earlier testing this session, so it wasn't reliable for this). Cold first call: 1 real fetch, cached. Second call at +27s (within the 45s window): 0 new fetches, served from cache, confirming it doesn't just re-fetch on every call. Third call at +89s (well past the window): a real network hit, confirmed, returning the same current data. Checked `window.churches` afterward for duplicate entries under that name -- exactly 1, confirming the in-place refresh worked and didn't leave a stale duplicate behind.

**2. The admin approve/reject/unverify handler now checks its RPC's `error`**, matching `admin_set_church_hidden` right below it exactly: disables whichever button was clicked before the call, and on a real error, `alert()`s the message and re-enables the button instead of silently calling `loadAdminPanel()` regardless.

**Verified against a real failure, not a mocked happy path**: not being signed in as a platform admin, a synthetic button with `data-unverify-church-id` set to the real test church's id was clicked via the same delegated listener this handler actually uses (`window.alert`/`window.confirm` temporarily stubbed to capture calls instead of blocking on a native dialog) -- the RPC genuinely failed server-side with `"Only platform admins can review verification requests."`, and the fix correctly surfaced that exact message via `alert()` and re-enabled the button afterward. This is the same real permission check confirmed in the previous diagnostic entry, not a stubbed response -- a real failure path, not a happy-path test.

Build `2026-09-12-v303`.

---

## Corporate-suffix stripping: a real gap when the suffix isn't the last word, plus a missing admin call site

**The gap, root-caused against real live data, not guessed.** Queried every church whose name contains "incorporated"/"corp"/"llc"/"ltd"/"limited" (21 real rows). 20 of them already stripped correctly with the existing `CORPORATE_SUFFIX_RE` -- the regex itself wasn't broken for the ordinary case. The failure was structural: the old pattern was anchored with `\.?\s*$`, requiring the suffix token to be the literal last word. "Second Baptist Church Incorporated of San Antonio Texas" and "Episcopal Church Corporation in West Texas" both have real text trailing the suffix itself -- an IRS-import artifact where a locality got bolted on after the legal-entity suffix -- so the anchor never matched at all and the whole name, "Incorporated"/"Corporation" included, rendered untouched. Confirmed live on the actual profile page for the Second Baptist case (not just at the function level) before and after the fix.

**Also found "Iglesia Vida Nueva Stone Oak Incorporation"** -- "Incorporation" (the noun), not "Incorporated" -- a variant the suffix list never included at all, unrelated to the anchoring bug.

**Fix**: `CORPORATE_SUFFIX_RE` now truncates everything from the first matched suffix token onward, instead of requiring the token to be the very last word. `\b` still guards the leading edge exactly as before (a suffix token has to be a genuine whole word, not a substring of a longer one) -- once a real one is found, though, whatever comes after it is boilerplate by definition, regardless of what it says. Added `incorporation` to the alternation for the noun-form gap. Restructured `l.l.c.` as its own alternative outside the shared trailing `\b`, since its literal periods already self-delimit it and requiring `\b` right after it broke on a name ending in exactly "L.L.C." (`\b` needs a word character on one side; the last character consumed there is a period) -- caught by testing that exact case before shipping, not assumed safe.

**Verified against 46 cases before touching the live code**: all 16 of the session's original regression cases (Inc/Inc./Incorporated/Corp/Corp./Corporation/LLC/L.L.C./Ltd/Ltd./Limited/comma-form/no-suffix/Zinc/Vincent/Mt-Horeb), all 21 real live rows containing any suffix keyword (Corp, Corporation, LLC, Ltd, Limited, Incorporated, Incorporation), 6 guard names that legitimately contain "of"/"in" with no suffix keyword present (must stay untouched), and 3 additional false-positive guards specifically for the new no-longer-end-anchored design ("Grace Church Increase Ministries", "Church of the Incarnation", "Income Tax Help Ministry" -- `\b` correctly keeps "inc" from matching inside "Increase"/"Income"). All 46 passed. Re-confirmed live in the browser against the actual full audit of every "incorporated/incorporation/corporation/corp/llc/ltd/limited" row in the database (21 total) -- every one now resolves to a clean name.

**One residual case found and deliberately left alone**: "Life Change Church of San Antonio Tx a Domestic Nonprofit Corp" still displays with "a Domestic Nonprofit" attached after stripping "Corp" -- structurally different from every other gap here, since the legal-entity qualifier phrase *precedes* the suffix token instead of following it. Fixing that would mean matching an open-ended "a [Domestic/Foreign] [Nonprofit] " phrase *before* the suffix, a fundamentally different (and much fuzzier) pattern than "truncate everything after a real suffix token" -- out of scope for this pass, flagged rather than papered over with a narrow one-off pattern for a single row.

**Separately found and fixed**: the admin "pending verifications" list (`loadAdminPanel()`) rendered `r.name` raw, unlike every other admin church-name display in the file -- the one call site that skipped `displayChurchName()` entirely. No live pending request currently exists to reproduce visually, but this is a real, confirmed inconsistency regardless (the exact same class of bug the corporate-suffix work above was about, just a missed call site rather than a regex gap).

---

## Denomination translations: audited every live value against `translateDenomination()`

A report that "Pentecostal" (as typed, "Pentecostas") wasn't resolving prompted a full audit -- every unique `denomination` value actually in the live `churches` table (1,286 rows, paginated past Supabase's 1,000-row default cap to make sure nothing was missed), not just the 9 options the register-church dropdown offers, since bulk CSV imports and an owner's own free-text "Other" entry both write values outside that fixed list.

**17 unique values exist live; 8 had no entry in `denomI18nKeyMap` at all**: Church of God (18), Church of Christ (16), Apostolic (12), Orthodox (9), Protestant / Evangelical (7), Nazarene (3), Anglican (3), Jewish (2). None of these are Spanish-language values -- despite the report specifically calling out Spanish terms (Bautista, Católica, Metodista, etc.) as suspects, **zero raw Spanish denomination values exist anywhere in the live table today** (confirmed by listing every one of the 17 unique values directly). The real gap is the reverse of what was suspected: real, live, currently-used *English* values with no Spanish translation at all, silently falling back to raw English text whenever the site is viewed in Spanish. Added Adventist too, even with no live row currently using it, since a future import or a free-text "Other" entry would hit the identical gap.

**"Pentecostal" itself was checked specifically and is not actually broken.** `denom.pentecostal` maps to the literal word "Pentecostal" in both the English and Spanish dictionaries -- confirmed this is correct, not an oversight: "pentecostal" is genuinely the same word in Spanish (an invariable, borrowed ecclesiastical adjective, same as how "Episcopal" is also identical in both languages already). There was nothing to fix in the mapping itself; the actual, real gap this report was pointing at turned out to be the 8 missing denominations above, not Pentecostal.

**Deliberately left alone**: the directory sidebar's denomination filter checkbox list (`renderDirectory()`'s `coreDenomsAll`) is a separate, intentionally curated 9-item list (the original 9 that already had translations) controlling which denominations are offered as *filterable* checkboxes -- a different, pre-existing design decision from what `translateDenomination()` displays on an already-rendered card or profile page. Not touched, since the ask was about the translation map, not the filter UI's curation.

**Verified live against the real database**: called `translateDenomination()` directly for all 16 non-null live values in both languages after the fix -- all 8 previously-broken ones now resolve to real Spanish text (Church of God → Iglesia de Dios, Orthodox → Ortodoxa, Jewish → Judía, etc.), the other 8 correctly stay the same (Pentecostal/Episcopal, genuinely identical in both languages) or already worked, and English mode still shows every value as pure identity-mapped English with no regressions. Build `2026-09-12-v304`.

---

## Website liveness check: a real HTTP check per stored URL, and why 25 of the first 76 "dead" results were wrong

Ran from Node directly against the Supabase REST API (`website_liveness_check.clear_dead_websites.sql`, repo root, not committed -- same one-off-script convention as the other `san_antonio_metro_churches.*.sql` files already sitting there, not a numbered `supabase/migrations/` entry), specifically to avoid CORS: a browser `fetch()` against an arbitrary third-party origin either gets blocked outright or, in `no-cors` mode, can't expose the real HTTP status at all, so this could never have been done reliably client-side. 503 churches have a non-empty `website` value.

**First pass** (HEAD, falling back to GET on 4xx/error, 12s timeout, 20-way concurrency): 76 flagged dead. Breaking that down by failure reason immediately raised a real concern -- 29 of the 76 were `http_403`, and several of those domains belonged to unmistakably real, currently-operating organizations (`sbtexas.com` — Southern Baptists of Texas Convention; `ariel.org` — Ariel Ministries; `bua.edu` — Baptist University of the Americas). A 403 from an automated request is a classic bot/WAF signature, not proof of a dead site, and no plain HTTP client can fully rule that out -- a Cloudflare "Just a moment" JS challenge, for instance, cannot be solved without actually executing JavaScript.

**Second pass, specifically to separate genuine deaths from bot-blocking**: rechecked all 76 with fuller browser-like headers (`Accept-Language`, `Sec-Fetch-*`, `Upgrade-Insecure-Requests` — a bare User-Agent string alone clearly wasn't enough), a real GET instead of HEAD, a fallback check against the bare origin/root (in case only a specific stored subpath was gone), a 15s timeout, and one delayed retry for transient blips. Result: **25 of the 76 recovered** -- confirmed false positives from pass one, including all three organizations named above. Facebook page URLs (13) were excluded from verification entirely rather than rechecked at all: Facebook blocks essentially all automated requests regardless of whether the page genuinely exists, so an HTTP check can never distinguish "gone" from "Facebook doesn't like scripts" for these.

**Of the 38 that were still dead after the second pass**, a further 7 were still `http_403` -- including Our Lady of Guadalupe Parish and, again, Southern Baptists of Texas Convention (a different subpath than pass one happened to catch this time). Given the demonstrated real false-positive rate in this exact category on this exact data, these 7 were deliberately **not** included in the clearing script despite technically being 4xx responses -- a persistent 403 still isn't distinguishable from bot protection on a live site by any HTTP-only method, and the risk of wiping a real church's real website is worse than leaving a small number of uncertain rows untouched. Reported separately in the SQL file's own header comment as "recommend a manual check, not auto-cleared," rather than silently either including or dropping them.

**4 more excluded as test/internal data, not real website corrections**: "Test 2", "Test 2 church", "Test 4" (empty `website` values, `ERR_INVALID_URL`) and the "Catholic Church of San Antonio" row used for admin-edit-form testing earlier this session, whose `website` is a literal `test.com` placeholder -- not a real church's broken link.

**27 real churches' `website` field is genuinely, confidently dead** by DNS failure (14), connection refused/reset (3), a real timeout (1), an expired or otherwise broken TLS certificate (3 -- flagged distinctly in the SQL comments since this is a different failure class than a clean HTTP status, though functionally just as broken for a real visitor's browser), or a confirmed 404/500/503 (5) that survived the same careful retry the 403s got. The SQL script clears `website` to `NULL` for exactly these 27, by id, with a comment on each line naming its specific failure reason -- not yet run against production, per this project's manual-only-migration workflow; needs to be run by hand in the Supabase SQL Editor.

---

## Three follow-up corrections from the audit above, plus a reusable acronym-casing tool

**1. Hid the 6 zero-signal "Ministries" churches** (`san_antonio_metro_churches.hide_zero_signal_ministries.sql`) -- confirmed this wasn't a new finding: `san_antonio_metro_churches.find_wrongly_visible.sql`, already sitting in this repo from earlier work, had already anticipated "around 6 rows" like this after an earlier hide-pass apparently missed them. Checked why that earlier pass missed them before writing the new one: 5 of the 6 have an exact name+address match against the review list (so a text-mismatch, the old file's own working theory, only explains one of the six -- "Servants of/Of Servants Ministries"), and all 6 share the identical `created_at` timestamp as the rest of the batch, ruling out "these were inserted later, after the hide-pass already ran." The actual original miss is still unexplained; this file only fixes the current state rather than re-diagnosing that.

**2. Corrected one truncated name** (`san_antonio_metro_churches.fix_truncated_name.sql`): "Greater Evangelist Temple Church Of" → "Greater Evangelist Temple Church of God in Christ", confirmed via multiple independent public directories before writing the UPDATE. The other two names the same audit flagged were deliberately left alone -- "Christian Fellowship Church Of" (no confident source found) and the "...Orthodox Order of St Benedict in A" one ("in America" is a plausible completion but unconfirmed, not worth guessing into a stored value).

**3. Built a reusable acronym-casing tool** (`scripts/acronym-exceptions.js`) rather than a one-off fix, since the underlying problem is structural: there's no single shared name-title-caser anywhere in this repo to patch (the one that originally title-cased the San Antonio import's names was a one-off script, never committed -- confirmed by checking every CSV in the repo, `backups/`, and full git history in the previous audit). `ACRONYM_EXCEPTIONS` is a flat, appendable array (`SATX`, `RGV`, `UPCI`, `UMC`, `EFCA`, `SBC`, `COGIC`, `AME`, `ELCA`, `PCA`, `AG` to start) and `applyAcronymCasing(name)` does a whole-word (`\bSATX\b`, never substring) case-insensitive replace back to canonical form -- same word-boundary discipline as `filter-churches.js`'s keyword matching, for the identical reason (a 2-3 letter acronym is exactly the kind of token that could otherwise collide with a real word fragment).

**Tested every one of the 11 candidate acronyms against the live data before finalizing the list**, not just reasoned through: 9 real hits across 7 of the 11 acronyms (`Waypoint Church Satx`, `Christ Community Church Satx`, `Redeemed Ministries Satx`, `The Church Upci Inc`, `River Church Rgv Inc`, `Windsong Christian Center Umc`, `Mission Community Church- Efca`, `Sherman Chapel Ame Church`, `Christ Church Pca of San Antonio`) -- zero false positives on inspection, and zero live hits for `SBC`/`COGIC`/`ELCA`/`AG` today (kept in the list anyway, per the ask, for whatever future import surfaces them). Specifically checked the riskiest short one, `AG`, against real word collisions (`Agape`, `Amen`) via the self-test -- `\b` correctly keeps it from firing inside either, the same "Administry"-class bug this project already has a name for.

The script's CLI mode (`node scripts/acronym-exceptions.js`) fetches every live church name (read-only, the same publishable/anon key already embedded in `index.html`) and generates `san_antonio_metro_churches.fix_acronym_casing.sql` for whatever it finds -- it never writes to the database itself, matching this project's manual-migration workflow. Run against the live data today: found exactly the 9 rows above, byte-for-byte matching the manual spot-check done before the script existed. `--selftest` covers all 9 real cases plus the false-positive guards, offline, no network access -- `node scripts/acronym-exceptions.js --selftest` passes.

All three `.sql` files are one-off corrections (same untracked-in-git convention as this repo's other `san_antonio_metro_churches.*.sql` files) and were sent directly to the user rather than committed -- none has been run against production yet.

---

## Search boxes still triggering mobile autofill after two "fixes" -- the actual root cause was no `<form>` anywhere

Two prior builds (v305: reordered search bars; v306: `type="search"` + `autocomplete="off"` on every search input) had already shipped and were confirmed live in production (`build 2026-09-13-v306` visible on faithdock.com) before this report came in -- so this wasn't a deploy problem, the underlying cause was still there.

**Confirmed the actual mechanism directly, not just theorized**: grepped the entire file for `<form` and found exactly one -- the standalone waitlist email-capture form, completely unrelated to auth. Every single auth flow (signup, login, forgot/reset password, profile email change, profile password change) was bare `<input>` elements with zero `<form>` wrapper, sitting in a page where every route's markup lives in the DOM simultaneously (this is an SPA that only toggles `display`, never removes sections). With no `<form>` boundary anywhere near a password field, Chrome's mobile autofill heuristic has nothing to scope "this is a login form" to, so it falls back to treating the *entire document* as one implicit form -- meaning a password field could get paired with a search box on a completely different, unrelated part of the page. `type="search"`/`autocomplete="off"` on the search fields themselves (the previous fix) can reduce this but can't fully prevent it, since the pairing heuristic is driven by the password field's lack of a form boundary, not by anything the search field itself declares.

**Fix: 6 new `<form>` elements**, one per flow, not one shared form -- signup, login, and forgot-password are visually stacked in the same `.auth-card` (toggled by `display`, never simultaneously visible) but get separate forms so a password manager pairs each email/password pair with the right flow instead of guessing across all three. Same reasoning for the profile page's email-change and password-change sections, which sit inside one large shared settings panel alongside unrelated fields (photo, display name, phone, age range) that were deliberately left *outside* any form -- narrowly scoped to just the two flows that actually have a password field.

**The renaming trap, caught before it shipped a real regression**: initially renamed `#signup-fields`/`#login-fields` to `#signup-form`/`#login-form` for clarity (more honest now that they're real forms) but forgot `#forgot-password-fields` needed the same treatment, then caught the inconsistency, decided to keep the new names, and grepped for every remaining reference to the old ids (`authTab()`, `showForgotPasswordMode()` -- 4 call sites total) before considering it done. Zero dangling references confirmed by a final grep.

**Submission stayed 100% JS-driven, on purpose -- no existing validation/async logic was touched.** Two different patterns, depending on whether the flow's submit button lives inside or outside its new form:
- **Forgot-password, reset-password, profile-email, profile-password** each already had their own dedicated button sitting naturally inside the fields being wrapped. For these, the existing `button.addEventListener('click', async function(){...})` was converted to `form.addEventListener('submit', async function(ev){ ev.preventDefault(); ...same body, untouched...})` -- the button got an explicit `type="submit"` (matching the waitlist-form's own existing convention, the one real precedent already in this file), so clicking it naturally fires the form's submit event, and Enter-in-any-field now does too, both through the exact same code path. No duplicated logic, nothing to keep in sync.
- **Signup and login** share one submit button (`#auth-submit-btn`) whose click handler branches on which tab is active -- refactoring that into two copies (one per form) would create exactly the sync-drift risk the pattern above avoids. Instead the button deliberately stays outside both forms, untouched, and each form's submit listener does only `ev.preventDefault(); document.getElementById('auth-submit-btn').click();` -- a one-way bridge from "Enter was pressed" to "do exactly what a real click would do," with no risk of double-firing since the shared button was never itself inside a form to begin with.

**Verified what could be verified without a real device or a trusted keystroke, both honestly flagged as still needed:**
- Confirmed all 7 forms (6 new + the pre-existing waitlist one) are real `<form>` elements, structurally.
- Confirmed the submit-to-click bridge works exactly as designed: spied on `#auth-submit-btn.click` and dispatched a real `submit` Event on both `#signup-form` and `#login-form` -- the shared button's click fired exactly once per dispatch, correctly, for both.
- Dispatched `submit` on all 4 refactored forms (forgot-password, reset-password, profile-email, profile-password) with empty fields -- each correctly ran its existing early-return validation (`"Enter your email first."`, `"Password must be at least 10 characters."`, etc.) with **zero page navigation** in every case (`location.href` unchanged before/after) and zero new console errors.
- Confirmed signup/login tab-switching and the forgot-password toggle still render and behave correctly live in the browser (screenshots), unaffected by the `<div>`→`<form>` change.
- **Could not get this specific browser-automation tool to simulate a genuine trusted Enter keystroke** to visually confirm end-to-end through the UI layer -- a probe showed the tool's synthesized key event arrives with an empty `e.key` (not `"Enter"`), which is a known limitation of some CDP-level key dispatch, not a code issue. Dispatching a real `submit` Event directly (proven above) exercises the identical code path a genuine trusted Enter keystroke would trigger in any real browser via the standard, decades-old "Enter in a text/email/password field implicitly submits its enclosing form" behavior -- but this is reasoning from web-platform spec behavior, not a direct observation, and is explicitly flagged as such rather than claimed as verified.
- **The actual reported symptom (a real Android phone's password manager popping an autofill prompt on a search box) could not be tested at all** -- no physical device available in this environment. This was explicitly required before calling the fix done; still outstanding, needs the user (or a real device) to confirm on the deployed build.

Build `2026-09-13-v307`. Not yet confirmed fixed on a real device -- code-level root cause is fixed and verified as far as this environment allows, but the original bug report's own actual test (a real Android phone) hasn't been re-run yet.

---

## Multi-value "Tradition" taxonomy: a church's denomination is now a set, not a single string

`churches.denomination` was always a single exact-match string, which can't represent a church whose polity spans categories -- the canonical case: a Christian Methodist Episcopal (CME) or African Methodist Episcopal (AME/AME Zion) church is genuinely Methodist AND Episcopal AND Protestant at once, but its `denomination` column (when it has one at all) usually just says "Methodist," so filtering by "Episcopal" in the old single-string filter would never surface it.

**New `denomination_tags text[]` column, computed, not hand-entered.** `compute_denomination_tags(denomination, name)` (migration 023) derives the full tag set from two independent signals -- compound name phrases (`\mAfrican Methodist Episcopal\M`, `\mChristian Methodist Episcopal\M`, `\mCOGIC\M`, etc., all whole-word `~*` matches, same discipline as every keyword check elsewhere in this repo) checked first since a church's own name is often the highest-confidence signal even when `denomination` is blank or generic, then the existing `denomination` column itself as a second pass. A `BEFORE INSERT OR UPDATE` trigger keeps every future row in sync automatically; a one-time backfill UPDATE re-tagged all 1,286 existing rows. `churches.denomination` itself is completely unchanged -- still the free-text value that's actually displayed and translated.

**Real deploy-order hazard, caught before it caused an outage, not after.** The new `search_churches` signature adds a 9th parameter (`p_tradition_tags`) — but Postgres identifies a function by name *and* full parameter list, so `CREATE OR REPLACE` on a different signature doesn't replace the old 8-parameter version, it creates a second overload alongside it, and PostgREST refuses to call an ambiguous "which one did you mean" function. The migration's own explicit `DROP FUNCTION` (old signature) before the `CREATE OR REPLACE` (new one) is what avoids this — confirmed by the migration's own author having hit "function search_churches() is not unique" against a real local Postgres before ever sending this file over. Separately confirmed live in this environment: deploying the new `index.html` (which calls the 9-parameter RPC) against a database still running the old migration produces `Could not find the function public.search_churches(...) in the schema cache` -- Directory and Events search fail gracefully with an error message rather than crashing, but the core browse feature is fully down until the migration actually runs. Held the commit specifically until the user confirmed the migration had been run, rather than pushing code and migration together and hoping the ordering worked out.

**Verified live against the real database and the real RPC, not just reasoned through, once the migration was confirmed run:**
- Raw table spot-check (`denomination_tags && array['Episcopal']`, via the Supabase REST API's `ov.` overlap operator) returned 24 rows including "Butler African Methodist Episcopal Church" (`denomination: Methodist`), "Christian Methodist Episcopal Church" (`denomination: Methodist`), "Redeeming Grace African Methodist Episcopal Cion Church" (AME Zion), and "Sherman Chapel AME Church" (`denomination: null` -- tagged purely from its name, confirming the name-phrase pass works even with no denomination column value at all).
- Called the live `search_churches` RPC directly with `p_tradition_tags: ['Episcopal']` -- 200 OK, 23 rows (one fewer than the raw table query, correctly excluding a known hidden test row -- confirms `is_hidden` filtering survived the rewrite).
- Confirmed the same result live in the actual browser UI: unchecked everything in the Tradition dropdown except Episcopal on the real Directory page -- "23 churches found," with Butler AME and Christian Methodist Episcopal Church both appearing despite their card badges reading "METHODIST," not "Episcopal." Exactly the behavior this migration exists to produce.
- Confirmed both the Directory and Events Tradition dropdowns render the documented FAMILY (Protestant/Catholic/Orthodox/Jewish/Non-denominational) then MOVEMENT (Baptist through Christian/General) grouping, all checked by default, via direct DOM inspection on both pages before the migration ran (pure client-side rendering, unaffected by the RPC signature mismatch).

Build `2026-09-13-v308`.

---

## Removed "Jewish" from the Tradition/Family filter

Follow-up to the taxonomy above: dropped "Jewish" from both the Directory and Events Tradition dropdowns (the Family group is now Protestant/Catholic/Orthodox/Non-denominational) and from the shared `ALL_TRADITION_TAGS` array that drives both pages' filtering. Also updated the two now-stale code comments describing the Family group's contents (CSS section and the `ALL_TRADITION_TAGS` declaration) so they don't keep listing a tag that's no longer there.

Deliberately left untouched: `translateDenomination()`'s `denomI18nKeyMap` (still maps `'Jewish'` → `denom.jewish` for the single-value `churches.denomination` column) and both EN/ES `denom.jewish` dictionary entries -- that's a separate display/translation mechanism for the free-text `denomination` string a church can still have on file, not the multi-value Tradition filter this change scopes to.

**Backend migration 024** (`supabase/migrations/024_remove_jewish_tradition_tag.sql`) redefines `compute_denomination_tags()` (from migration 023) with the two Jewish-detection branches removed -- the `\mSynagogue\M`/`\mJewish\M` name-phrase check and the `denomination = 'jewish'` column check -- then re-runs the same backfill `UPDATE` so any row currently carrying a stale `'Jewish'` tag gets recomputed under the new rules. Verified this migration's function body matches migration 023's original branch-for-branch (diffed line by line) before writing it, so nothing else shifted. Unlike migration 023, this one doesn't touch `search_churches`'s signature at all, so there's no deploy-order hazard -- the index.html change and this migration can land in either order without breaking search.

Verified live in the local preview: `window.ALL_TRADITION_TAGS` no longer includes `'Jewish'`, and both Directory's and Events' Tradition dropdowns show FAMILY as Protestant → Catholic → Orthodox → Non-denominational with no gap or console error. Migration 024 is still pending the user running it in the Supabase SQL Editor -- until then, `denomination_tags` on any previously-tagged row may still contain a stale `'Jewish'` entry that the (now Jewish-less) UI simply can't select against, which is harmless but not fully cleaned up.

Build `2026-09-13-v309`.

---

## Register/Edit church form's Denomination dropdown updated to match the Tradition taxonomy

The `#rc-denomination` select (shared by both "Register your church" and "Edit your church" -- same form, same ids, just a different heading/button label depending on `window.rcIsEditing`) still had its original flat 9-option list from before migration 023 -- missing Orthodox, Anglican, Adventist, Church of God, Church of Christ, Apostolic, and Nazarene entirely, and using "Non-denominational" instead of "Protestant" as the closest Family-level option. A church owner picking their actual tradition had no way to select 7 of the 17 values the Tradition filter now recognizes.

**Restructured into `<optgroup>`s matching the filter panel exactly** -- Family (Protestant/Catholic/Orthodox/Non-denominational) then Movement (Baptist through Christian/General), same order, same values, same existing `denom.*` i18n keys (all 17 already had EN/ES translations from the filter checkboxes, so this needed zero new dictionary entries). "Other" stays a bare option after both groups, unchanged.

**`<optgroup>` doesn't support `data-i18n` for its heading** -- unlike every other translated element in this file, an optgroup only renders its `label` *attribute*, not textContent, so setting `.textContent` in `applyTranslations()` (what plain `data-i18n` does) would silently do nothing. Added a small `data-i18n-label` handler right alongside the existing `data-i18n-placeholder`/`data-i18n-title` attribute-translators (same pattern, different attribute) rather than leaving the group headings English-only in Spanish mode -- confirmed live via `applyTranslations('es')` that both optgroups relabel to "Familia"/"Movimiento".

**Found and fixed a second, related bug while doing this**: `checkExistingChurch()`'s populate-the-edit-form logic had its own separate, even-narrower hardcoded `knownDenoms` list (missing Catholic entirely, on top of everything the dropdown itself was missing) used to decide whether an existing church's `denomination` value gets its real option selected or gets shunted into "Other" with a duplicate free-text copy. Editing a church already tagged "Orthodox" or "Church of God" -- both now valid, selectable dropdown options -- would still have incorrectly shown "Other" with the value copied into the free-text field below it, because `knownDenoms` didn't know about them. Replaced the stale local array with `ALL_TRADITION_TAGS` (the same shared constant the filter panels already reference) instead of just editing the duplicate list a third time, so this can't drift out of sync with the dropdown again. Verified via direct simulation in the browser console: `Orthodox` and `Church of God` now correctly select their real option with the free-text field hidden, while a genuinely unrecognized value still correctly falls back to "Other".

The admin-only church-edit panel (`#admin-church-edit-denomination`, a free-text input, not a dropdown) was deliberately left untouched -- out of scope, and admins editing there can already type anything.

Build `2026-09-13-v310`.

---

## "Ministries" feature (Option B): church-owned ministries, attachable to events, mirroring Rooms

New `church_ministries`/`event_ministries` tables (`supabase/migrations/025_church_ministries.sql`) let a church list the programs it runs as part of itself -- a food pantry, a youth group, a recovery meeting -- and attach one or more to an event. Deliberately NOT a new top-level directory entity: an independent parachurch nonprofit still doesn't get its own FaithDock listing; a ministry only exists because a real, already-verified church added it to its own profile, same trust model as rooms/funds/groups.

**Migration renumbered 024 → 025.** The instructions this was built from specified `024_church_ministries.sql`, but `024` was already taken in this repo by [`024_remove_jewish_tradition_tag.sql`](supabase/migrations/024_remove_jewish_tradition_tag.sql) (a same-session change unrelated to this feature). Created it as `025_church_ministries.sql` instead rather than overwriting or duplicating an existing migration number -- content is otherwise applied exactly as specified.

**Deliberately the opposite of Rooms on public visibility.** Rooms are purely operational (only the create/edit form and an internal printable schedule ever read `church_rooms`/`event_rooms`) and have no public-read RLS policy. Ministries exist specifically to be publicly discoverable, so both new tables get an explicit `select` policy for `anon, authenticated` (active ministries only; `event_ministries` has no active/inactive concept of its own, so that one's public-read is unconditional) -- new policies, not copied from anywhere, since rooms had nothing to copy.

**Schema captured in a migration file for the first time ever, for either feature.** `church_rooms`/`event_rooms` themselves were created directly in the Supabase dashboard at some point and never had a migration file — confirmed by grepping every one of the 24 existing migration files for `church_rooms`/`event_rooms` before writing this one: zero hits. So `church_ministries`/`event_ministries` are mirrored off the live schema's own shape (inferred from how the app's existing room code queries/inserts against it), not off a migration file that doesn't exist.

**Full UI surface, same shape as Rooms end-to-end**, all wired through `PUBLIC_CHURCH_COLUMNS`-independent direct `.from('church_ministries'/'event_ministries')` calls (no column added to `churches` itself, so no `PUBLIC_CHURCH_COLUMNS` change was needed this time, unlike migration 023's `denomination_tags`):
- **Settings → Ministries** (new `#settings-ministries-section`, right after Facility rooms): add with name + description, soft-delete (`is_active = false`) via a remove button, same pattern as `loadRoomsPanel()`/room removal.
- **Create/Edit event → Advanced → "Ministries hosting"**: checklist + one primary radio, same delete-then-reinsert-on-save shape as `saveEventRooms()`, refreshed on church-picker change, language toggle, and the plain `#create-event` route-landing gap that rooms already had a fix for (applied the identical fix for ministries alongside it).
- **Public church profile → new "Ministries" tab**, positioned between Groups and Location (confirmed via `switchChurchTab()` — it's fully generic off `data-church-tab`/`church-tab-<name>` id matching, no hardcoded tab list to update).
- **Public event page → new "Hosted by: <ministry names>" row**, hidden entirely when an event has none attached, primary ministry sorted first when there's more than one.

**Naming collision worth flagging, not fixed without asking**: the new `events.hostedByMinistry` string is `'Hosted by'` (EN), which is the exact same English text as the pre-existing `events.hostedByLabel` (`'Hosted by [Church Name]'`, already shown near the top of every event page, right under the title). They're different keys with no functional collision, but a visitor reading top-to-bottom now sees "Hosted by Grace Fellowship Church" near the title and, further down in the info-rows section, "Hosted by: Food Pantry" -- built exactly as specified rather than unilaterally changing the given copy, but worth a second look.

**Verification performed in this environment**: all 4 non-module `<script>` blocks pass `node --check` with zero syntax errors. Confirmed live via direct DOM/JS inspection in the local preview (no physical DB access from here, so nothing that queries `church_ministries`/`event_ministries` could be exercised end-to-end yet): the Ministries tab renders in the correct position (`['about','events','groups','ministries','location']`), every new element id and `window.*` export exists, and `applyTranslations('es')` correctly relabels the Settings heading, event-form label, and dropdown placeholder text. **Could not verify the actual DB-backed behavior** (adding/removing a ministry, attaching one to an event, the public tab/row rendering real data, or the RLS policies actually blocking a non-owner) -- migration 025 hasn't been run yet. Until it runs, none of this breaks anything already live: `loadMinistriesPanel()` and `loadPublicChurchMinistries()` show an inline error only within their own section, `loadEventMinistryChecklist()` falls back to its "no ministries set up yet" empty state, and `loadEventMinistriesDisplay()` just leaves the "Hosted by" row hidden -- all isolated failure modes, unlike migration 023's RPC-signature hazard, so there was no reason to hold this commit for confirmation the way that one was held.

Build `2026-09-14-v1`.

---

## Tradition filter restructured into a nested Denomination → Movement checkbox tree

Follow-up to the Tradition taxonomy: the flat Family/Movement subgroup-label layout is gone, replaced with real nesting -- each denomination (Protestant, Catholic, Orthodox, Non-denominational) is its own bold parent checkbox, with its movements (and its own per-denomination "Other") indented underneath it as children. Christian / General stays standalone at the end, since it isn't a specific movement within one denomination. The section header is renamed "Tradition" → "Filter", "Family" → "Denomination", and the search placeholder just says "Search" now.

**The instructions this was built from assumed Jewish was still in the taxonomy** (their exact-match FIND blocks included a `value="Jewish"` parent). It isn't -- removed earlier this session (see "Removed 'Jewish' from the Tradition/Family filter" above) -- so every FIND failed to match verbatim. Applied the same restructuring intent against the actual 4-denomination state instead of the assumed 5: Protestant/Catholic/Orthodox/Non-denominational parents only, "four" instead of "five" in the two inline comments about the per-denomination "Other" bypass.

**Found and fixed a real cross-surface side effect before it shipped**: `filters.family` is a shared i18n key -- besides this filter panel, it's also the Register/Edit church dropdown's Family `<optgroup>` label (added earlier today). Renaming the shared key's text to "Denomination" would have made that dropdown read "Denomination" (field label) → open it → "Denomination" (optgroup heading) → Protestant/Catholic/etc., which is redundant and wasn't asked for. Gave that optgroup its own dedicated key (`rc.denomOptgroupFamily`, still "Family"/"Familia") instead of quietly letting the rename bleed into an unrelated form -- confirmed via `applyTranslations('es')` that the optgroup still says "Familia" while the filter header correctly says "Filtro".

**Cascade is one-directional only, exactly as asked**: checking/unchecking a denomination checkbox toggles every movement (`.denom-child[data-denom-parent="X"]`) nested under it; an individual movement checkbox never reaches back up to its parent. Verified live in the browser: unchecking Protestant unchecked all 13 children (12 movements + its own Other) and re-checking re-checked all 13; unchecking just Baptist left Protestant checked. Same behavior confirmed independently on the Events page's own parallel implementation (`events-denom-parent`/`events-denom-child`). "Select all"/"Uncheck all" still correctly toggle all 21 checkboxes on each page, unaffected by the nesting since they already operated on the flat `.denom-filter` class regardless of visual grouping.

**The "Other" bypass note from the instructions is accurate and now documented inline**: "Other" was never a real per-church tag -- it's a UI-only wildcard meaning "don't narrow by tradition, show everything." It's now four checkboxes (one nested under each denomination) instead of one, but checking any single one of them still triggers the exact same `denominations = null` bypass as before. No functional change, no backend/migration needed -- confirmed by reading `renderDirectory()`'s and Events' own filter-resolution code, both already keyed off `.indexOf('Other') !== -1` against the flat list of checked values, which doesn't care how many "Other" checkboxes exist or where they're nested.

Verified all of Part 9's checklist live in the browser (structure, cascade both directions, Select all/Uncheck all, Spanish translations) via direct DOM/JS inspection. All 4 non-module `<script>` blocks pass `node --check`.

Build `2026-09-14-v2`.

---

## Final Denomination Taxonomy v2: 4 grouped traditions + 2 standalone, replaces the interim Family/Movement scheme

Follow-up to the nested Denomination → Movement restructure above, replacing its interim group names entirely: the final taxonomy is 4 grouped traditions (Catholic, Nontrinitarian / Other Christian, Orthodox, Protestant -- each with its own short list of specific denominations, 15 total) plus 2 standalone childless categories (Christian / General, Nondenominational), all 6 alphabetized together with a single "Other" pinned last. Specific denominations render inside a closed-by-default `<details>/<summary>` ("See specific denominations") rather than always-visible indented rows, since the list is now longer and includes some less-common bodies (Jehovah's Witnesses, Latter-day Saints) that don't need to be visible by default.

**This also fixes a real mistagging bug**: "Beth Simcha Messianic Synagogue" and similar Messianic congregations were previously matched by the old taxonomy's bare `\mSynagogue\M`/`\mJewish\M` check and tagged plain Jewish -- before that tag was removed from the taxonomy entirely, they'd have fallen to "Other" instead, which was arguably still wrong (Messianic Judaism is a specific enough thing to name). Migration 026 checks `\mmessianic\M` FIRST, before any other pattern, and tags matches `{Protestant, Messianic Judaism}` -- a flat Protestant child, not its own top-level group (an earlier draft had it as its own group with a single "Messianic Congregations" child; both got collapsed into the single leaf per the final design). There's deliberately no generic "Jewish" bucket anywhere in this taxonomy -- a plain "Temple Beth Shalom" with no Messianic language stays untagged, falling to "Other" by design, same as "Church of God" or "Church of Christ" (neither maps cleanly to one group, so both are deliberately left unmapped rather than forced somewhere misleading).

**Two real mismatches caught before applying anything, per this prompt's own explicit "stop and tell me rather than guess" instruction**:
1. The new migration file was specified as `025_denomination_taxonomy_v2.sql`, but `025` was already claimed earlier the same day by [`025_church_ministries.sql`](supabase/migrations/025_church_ministries.sql) (an unrelated feature, committed from this same local session) -- the prompt's author was working from their own scratch copy of the repo, which doesn't reflect commits made directly here. Renumbered to `026_denomination_taxonomy_v2.sql`; confirmed with the user before proceeding, who confirmed local git state is authoritative.
2. The i18n Find blocks for `filters.tradition`/`filters.searchTradition` didn't match verbatim -- both EN and ES lines had an extra `'rc.denomOptgroupFamily': 'Family'`/`'Familia'` key appended, added earlier the same day specifically to keep the Register/Edit church form's dropdown optgroup label independent from `filters.family` (so a filter-label rename wouldn't leak into that unrelated form -- see the entry above this one). Confirmed with the user and merged by appending the new keys after the preserved one, losing nothing.

**`compute_denomination_tags()` rewritten with a single unified `hay` string (`lower(denomination || ' ' || name)`)** instead of the old two-stage "name patterns, then a separate `denomination`-column `elsif` chain" shape from migrations 023-025 -- simpler, and a name-based and column-based signal for the same tag no longer need two separate branches. A second `d` variable (`lower(trim(denomination))`) still exists for the Stage-2 exact-match compatibility fallback, which only fires for the literal legacy dropdown strings (`'baptist'`, `'catholic'`, etc.) that somehow didn't hit any Stage-1 pattern. Match order deliberately front-loads the narrowest/most specific patterns (Messianic Judaism, LDS, Jehovah's Witnesses, Oneness Pentecostal, Methodist-before-Anglican for AME churches, Eastern-Catholic-before-bare-Catholic, Oriental-Orthodox-before-bare-Orthodox) so a broader later pattern can't steal a match a narrower one should have gotten -- same discipline as every prior version of this function, carried forward rather than re-derived.

**Verified structurally and via `node --check`, not against a live database** (no Postgres access from this environment, consistent with the rest of this project): all 4 non-module `<script>` blocks pass syntax check. Confirmed live in the browser: both Directory and Events panels render the correct alphabetized 6-entry top level (Catholic, Christian / General, Nondenominational, Nontrinitarian / Other Christian, Orthodox, Protestant) with `<details>` closed by default and expanding correctly on click; Protestant's cascade unchecks/rechecks all 9 children including Messianic Judaism; unchecking a single child (tested with Messianic Judaism) leaves its parent checked; Select all/Uncheck all toggle all 23 checkboxes per page (4 parents + 16 children + 2 standalone + Other); Spanish translations resolve correctly, including the Eastern/Oriental Orthodox disambiguation ("Ortodoxa Oriental" vs. "Ortodoxa Oriental Antigua") and the untouched Register/Edit-church optgroup label. **The migration itself was not run or verified against real data from this environment** -- the user's own message states it was tested against a local Postgres copy with a battery of real test cases (32-church table: 25 fully tagged, 4 standalone-tagged, 3 correctly untagged, 0 mistagged) before being sent here; still needs to be run in the Supabase SQL Editor to take effect on the live database. No deploy-order hazard either way -- this migration doesn't touch `search_churches`'s signature, only `compute_denomination_tags()`'s body and a backfill `UPDATE`, so the code and migration can land in either order.

Build `2026-09-14-v3`.

---

## Real bug: the Tradition filter never actually narrowed results, found via live testing

The user reported it directly: unchecking Lutheran, then unchecking the whole Protestant group, changed nothing about which churches showed up. Reproduced and root-caused live in the browser rather than guessing from the code.

**Root cause**: `renderDirectory()`'s filter-resolution branch (and Events' own parallel copy) had `else if (checkedDenoms.indexOf('Other') !== -1) { denominations = null; }` -- since the "Other" checkbox defaults to checked and nothing in the UI nudges anyone to also uncheck it while narrowing by denomination, that condition was true in essentially every real use of the filter, forcing `denominations = null` ("no filter, show everything") regardless of what the user had actually unchecked. This wasn't introduced by today's taxonomy work -- it's the original `denomSearch`-restructure logic from migration 023, carried forward and re-commented three separate times today (the nested-tree restructure, then the final taxonomy v2) without anyone actually re-deriving whether the underlying branch condition was still correct. It wasn't, and apparently never was: as long as "Other" stayed checked -- its default, untouched state -- the Tradition filter has never actually narrowed a single search.

**Fix**: the bypass-to-"show everything" condition now checks whether *literally nothing* has been unchecked (`checkedDenoms.length === totalDenomChecks`, comparing against the real DOM count rather than special-casing "Other"), not merely whether "Other" happens to still be checked. Once anything is unchecked, real narrowing applies: the checked values (minus "Other" itself, which was never a real tag) are sent to `p_tradition_tags` for churches / used in the client-side `.overlaps()` query for events. "Uncheck all" is handled as its own explicit branch (Directory) -- an empty array, not `null`, since those mean opposite things to the backend (empty array matches nothing; `null` means don't filter at all).

**Known, deliberately out-of-scope residual gap, found during verification**: a church can carry both a parent tag and a child tag at once (e.g. a Lutheran church's `denomination_tags` is `['Protestant', 'Lutheran']`). Unchecking only the "Lutheran" child while leaving the "Protestant" parent checked will *not* exclude that church, since it still matches on "Protestant" via the array-overlap query -- there's no way to express "Protestant, but not Lutheran specifically" with a pure OR/overlap match, only true exclusion logic would do that, which the RPC doesn't support today. Confirmed this is a separate, secondary behavior from the reported bug (which was about unchecking things having *zero* effect at all) -- verified live that unchecking the whole Protestant group (parent + all its cascaded children, exactly reproducing the user's own screenshots) now correctly excludes every Lutheran/Baptist/Methodist/Presbyterian/Pentecostal/Anglican/Adventist-tagged church, which is the behavior that was actually reported broken.

**Verified live against the real production database** (this repo has no local Postgres, so this ran directly against the deployed Supabase instance via the anon key): confirmed "Concordia Lutheran Church" carries `denomination_tags: ["Protestant","Lutheran"]` right now, explaining the residual gap above. Reproduced the exact reported scenario (uncheck Lutheran, then uncheck the whole Protestant parent) in the local preview against that same live database -- before the fix, no combination of unchecked boxes changed the result set; after, unchecking the Protestant group correctly removed every church in that cluster from the results, and "Uncheck all" correctly showed "0 churches found". All 4 non-module `<script>` blocks pass `node --check`.

Build `2026-09-14-v4`.

---

## Consolidated duplicate "Filter searches" / "Filter" labels on the mobile filter panel

Reported with a mobile screenshot: expanding the "Filter searches" collapse toggle revealed a second, redundant "Filter" heading directly underneath it for the Tradition/Denomination section -- two labels for effectively the same thing, stacked. Desktop never had this problem visually (the `.filter-panel-toggle` is mobile-only, `display:none` on desktop), but it also never said "Filter searches" anywhere -- desktop's only label for that section was the bare "Filter" heading.

**Fix**: repointed that heading's `data-i18n` from `filters.tradition` (a now-dead key, deleted from both EN/ES dicts) to the existing `filters.filterSearches` key, so its text is "Filter searches" on both platforms -- one wording, not two near-duplicates that could drift out of sync. Gave it a `.filter-tradition-heading` class and hid it specifically on mobile (`@media (max-width:860px)`, the same breakpoint that reveals `.filter-panel-toggle`), so mobile shows only the toggle's "Filter searches" once expanded, while desktop -- which has no toggle at all -- still gets a label via the heading. The "Distance" section's own heading (a sibling `.filter-group h4`) was deliberately left alone; only the Tradition/Denomination one was ever duplicating the toggle's text.

Verified live in both viewport sizes: desktop shows the toggle hidden and the heading visible reading "Filter searches"; mobile (375×812, expanded) shows the toggle visible reading "Filter searches" and the heading hidden -- confirmed on both Directory and Events pages, and confirmed the Spanish translation ("Filtrar búsqueda") resolves correctly for both. `filters.family`/`filters.movement` were noticed to be similarly orphaned (unused since the taxonomy v2 restructure replaced the old subgroup-label divs) but were left untouched -- out of scope for what was actually asked here.

Build `2026-09-14-v5`.

---

## Renamed the Tradition filter's disclosure label to "Advanced"

"See specific denominations" → "Advanced" for the `<details>/<summary>` toggle that expands each group's specific denominations (Catholic, Nontrinitarian / Other Christian, Orthodox, Protestant). Single shared `filters.specificBodies` i18n key drives all 8 instances (4 groups × Directory + Events), so one dict edit per language covered everything -- also updated the HTML fallback text in all 8 `<summary>` tags to match, per this file's usual convention of keeping the pre-translation fallback in sync with the EN dict value. ES: "Avanzado". Verified live in both languages on the Directory page.

Build `2026-09-14-v6`.

---

## Indented the "Advanced" disclosure under its parent denomination

Reported via screenshot: "Advanced" sat flush with the left edge, same as its parent checkbox (Catholic, Nontrinitarian / Other Christian, etc.), instead of reading as nested under it. Added `margin-left:20px` to `.filter-tradition-details` -- the same indent already used for `.filter-check-child` -- so it now visually tucks under its group, matching the indent the group's own specific-denomination checkboxes use once expanded. Verified live: "Advanced" now sits indented under Catholic and Nontrinitarian / Other Christian in the dropdown.

Build `2026-09-14-v7`.

---

## Dark-mode hero search bar contrast, and dropped "/ Other Christian" from the filter label

**Two small requests handled together.**

**1. Hero/waitlist search bar blending into its background in dark mode.** `.search-bar` (used by both the home hero and the waitlist page's email form, both living inside `.hero` sections) fills with `var(--card)`, which in dark mode is `#182338` -- close enough to the hero's own `var(--brand)` (`#16233F`) that the search box read as barely distinguishable from the page behind it, unlike the always-legible `.nav-search` right above it (`rgba(255,255,255,0.08)` fill, `rgba(255,255,255,0.14)` border -- a fixed translucent-white treatment, not tied to the `--card` variable). Added a dark-mode-only override reusing those exact nav-search values for `.search-bar`, plus a parallel override for `.search-bar input` at the `max-width:600px` breakpoint, since the mobile layout moves the fill from the shared container onto each individual input. Fixed both instances (home hero, waitlist) since they share the same class and the same underlying cause -- not scoped to just the reported page.

**2. "Nontrinitarian / Other Christian" → "Nontrinitarian" in the Tradition filter.** Display-only change -- the `denom.trad.nontrinitarianOther` i18n value (and its two HTML fallback `<span>`s) dropped the "/ Other Christian" half, but the underlying `value`/`data-denom-parent` attribute on the checkbox (still the full `"Nontrinitarian / Other Christian"` string) and migration 026's own tag value were deliberately left untouched -- changing those would mean a new migration + re-tagging every church, for what was asked as a label edit. The group still alphabetizes correctly in the same position (Catholic, Christian / General, Nondenominational, Nontrinitarian, Orthodox, Protestant) since "Nontrinitarian" alone still sorts between "Nondenominational" and "Orthodox".

Verified live in the browser: dark-mode hero search bar's computed `background-color`/`border` now match `.nav-search`'s exactly; the Nontrinitarian label reads correctly in both EN and ES.

Build `2026-09-14-v8`.

---

## Real bug: a multi-church owner's URL silently rewrote to #dashboard/churches while sitting on any other page

Reported with three screenshots: refreshing on `#home` while signed in changed the URL bar to `#dashboard/churches` but the page kept showing the hero content; a further refresh actually landed on the dashboard's multi-church "Overview" grid. Root-caused by reading the actual functions involved, not guessed from the symptom.

**Root cause**: `loadDashboardHeader()` -- called unconditionally as a bare top-level statement on every page load, and again from the general auth-state-refresh batch (session restore included) -- has logic meant for exactly one case: "bare `#dashboard`, multi-church owner -> default to the Overview grid instead of a single church's Events tab." That logic was gated only on `!curDashKey` (`resolveRouteFromHash(location.hash).key` being falsy), never on whether the current route's *base* was actually `dashboard`. `resolveRouteFromHash()` returns a falsy `.key` for `#home`, `#directory`, and literally every route without a `/<key>` suffix -- so a multi-church owner landing on almost any page got silently redirected into calling `goDash('churches', true)`, which does `history.replaceState`-based URL rewriting to `#dashboard/churches` but has zero awareness of, or effect on, which top-level `.page` element is actually visible. That's exactly the observed mismatch: URL says dashboard, rendered content doesn't change until a fresh page load resolves the now-wrong hash for real.

**Fix**: added a `curRoute.base === 'dashboard'` check alongside the existing `!curDashKey` one, so the Overview-default redirect only fires when genuinely already on the dashboard route with no sub-key -- never from `#home`, `#directory`, or anywhere else. Single point of fix inside `loadDashboardHeader()` itself protects every call site (the bare top-level call, the auth-refresh batch, and the post-church-creation call) rather than requiring each caller to remember to gate it.

**Verified the guard logic in isolation**, not the full end-to-end flow -- this repo has no way to simulate a real multi-church-owner login from this environment. Ran the exact same condition against `resolveRouteFromHash()`'s real output for 5 cases: `#home` (multi-owner) and `#directory` (multi-owner) both now correctly skip the redirect (the reported bug, confirmed fixed); bare `#dashboard` as a multi-owner still correctly redirects (the legitimate, intended case); bare `#dashboard` as a single-church owner still correctly does nothing; `#dashboard/settings` (multi-owner, already on a specific sub-page) correctly stays put. All 4 non-module `<script>` blocks pass `node --check`. The actual live user-facing fix (does refreshing `#home` as a real multi-church owner stay on `#home` now) still needs confirmation from someone who can reproduce the original report against the deployed site.

Build `2026-09-14-v9`.

---

## Added a clear ("x") button to the Directory/Events keyword search fields

Requested with a generic mockup showing a text field plus a "Clear" affordance. The underlying reason this was missing: `type="search"` inputs' native webkit clear-button was explicitly disabled site-wide earlier this session (`input[type="search"]::-webkit-search-cancel-button{-webkit-appearance:none;}`, part of the mobile-autofill fix) -- a side effect nobody replaced with an alternative, so these fields quietly lost their only quick-clear affordance.

Scoped to exactly the two fields named (`#dir-keyword-input`, `#events-keyword-input`) -- deliberately NOT the home hero's own keyword field, even though it shares the same `.search-field-wrap` class, since that wasn't part of the request. Used a dedicated `.search-clear-wrap` class on the wrapping div rather than a blanket rule on `.search-field-wrap` itself, for exactly that reason. Button only shows once the field has text (JS-toggled on `input`), matching the reference mockup and standard search-clear UX (Google, native OS search fields) rather than always occupying visual space.

**One real edge case caught and handled, not left as a gap**: `goToDirectoryFromHero()` can land on the Directory page with `#dir-keyword-input` already pre-filled (typing a keyword in the hero search and hitting Search carries it through) -- that's a programmatic `.value` assignment, which doesn't fire the `input` event the clear button's visibility toggle listens for. Exposed the wiring function's internal visibility-sync as `window.syncDirKeywordClearBtn` and call it explicitly right after that assignment, so the clear button correctly shows up immediately in that flow too, not just when someone types directly into the field. Verified live: typing a keyword in the hero and navigating to the directory shows the clear button already visible on arrival.

Verified live on both pages: hidden by default, appears on typing, clicking clears the field, hides the button again, refocuses the input, and re-triggers the existing debounced render (so results actually refresh, not just the field). Spanish translation ("Limpiar búsqueda") confirmed correct. All 4 non-module `<script>` blocks pass `node --check`.

Build `2026-09-14-v10`.

---

## Extended the clear button to the Directory/Events location fields -- more involved than the keyword one

Follow-up to the keyword clear button above. The location field is structurally different (icon + input + an attached gold search button, all sharing one flex row with `border-right:none` on the input so it visually merges with the button) and, critically, its state isn't page-local the way the keyword fields are: `window.dirUserLat`/`Lng` plus `#dir-location-input`, `#events-location-input`, and the two home page "near you" headings are all one shared concept, kept in sync by the existing `setDirLocation()` whenever a location is set (autocomplete selection, geolocation, or the search button).

**Markup**: couldn't reuse the keyword field's flat `.search-field-wrap` + absolutely-positioned button approach directly, since that wrap is a flex row shared with the attached search button -- positioning the clear button `right:8px` relative to the whole row would land it on top of that button, not at the input's own edge. Wrapped just the `<input>` in a new inner `.search-clear-wrap` div (`flex:1;min-width:0`) so the clear button positions relative to the input alone. Gave `.search-clear-wrap` its own `position:relative` (previously it only had one via combination with `.search-field-wrap` on the keyword fields) so it works standalone here too.

**Behavior**: wrote `clearDirLocation()`, the mirror image of `setDirLocation()` -- resets `dirUserLat`/`Lng` to null, clears both location inputs and both status spans, resets both home headings back to their generic default text, and re-runs the same 4 renders `setDirLocation()` does. Clicking either page's clear button resets all of it, not just the field that was clicked, since leaving the other page's field (or the headings) showing a location that's no longer actually being filtered on would be a real, visible inconsistency. Deliberately leaves `hero-location-input` alone -- it's only ever conditionally synced (filled when blank, never overwritten), and clearing it could wipe out text someone's independently typing there; out of scope for what was asked.

**Real bug caught by testing, not assumed away**: first wiring attempt referenced `clearDirLocation()` by its bare name from the same place the keyword buttons are wired -- assumed (wrongly) that a same-file function declaration is hoisted and reachable from anywhere else in that file. It isn't: this file has several separate top-level scopes, not one flat script, and the bare reference threw `ReferenceError: clearDirLocation is not defined` at click time, caught via the browser console during live testing, not by reasoning about the code. Fixed by exposing `window.clearDirLocation` and calling it through `window.*`, the same cross-scope bridge every other function in this file already uses. Also had to add explicit clear-button visibility resyncs inside `setDirLocation()` itself (mirroring the existing `goToDirectoryFromHero()` fix from the keyword feature) -- it writes both fields' `.value` programmatically too, which never fires the `input` event the buttons' own visibility listeners depend on.

Verified live end-to-end after the fix: typing in one field shows only that field's own button; clicking either page's clear button empties both location fields, hides both buttons, resets `dirUserLat`/`Lng` to null, and resets both home headings -- confirmed symmetric from both the Directory and the Events side. Confirmed the hero field is untouched by an unrelated clear. Spanish translation confirmed. Visually confirmed the button sits cleanly inside the field with no overlap against the attached search button. All 4 non-module `<script>` blocks pass `node --check`.

Build `2026-09-14-v11`.

---

## New feature: real delivery/open/bounce tracking for outbound church messages

Before this, every mass announcement and individual directory-person message was fire-and-forget: `{success, sentCount}` from `smooth-action`'s `mass_email` branch and nothing else -- no way to know if an email actually arrived, bounced, or was ever opened. This adds real tracking, surfaced as a "Sent messages" history panel on Dashboard → Messages, using Resend's own webhook callbacks rather than guessing.

**Shape**: two new tables (`message_batches` -- one row per compose+send click; `message_log` -- one row per recipient within a batch, correlated to Resend via `resend_email_id`), a new `apply_resend_webhook_event()` SQL function that advances a log row's status forward-only (`sent → delivered → opened → clicked`, immune to Resend re-delivering an event out of order), a new `resend-webhook` edge function that receives and verifies Resend's Svix-signed callbacks and calls that function, and edits to `smooth-action.ts`'s existing `mass_email` branch to create the batch/log rows in the first place.

**Migration renumbered 027 → 028.** Same collision as the denomination-pattern-gaps migration earlier today: `027` was already taken by `027_denomination_pattern_gaps.sql`, committed in this same local session, which the prompt's own disconnected scratch clone couldn't see. Confirmed via `ls supabase/migrations/` before creating the file, per the prompt's own instruction to check first.

**Could not fetch the live `smooth-action.ts` source before editing, despite the standing rule to.** This environment has no access to the Supabase Edge Functions dashboard at all -- no credentials, no browser session, no management API reachable from here. Confirmed the repo's own tracked backup (dated "confirmed deployed 2026-09-09") matches the prompt's own expected "Find" block for the `mass_email` section character-for-character, and edited that local copy on the assumption it's still accurate -- but this is genuinely unverified against whatever's actually live today (2026-09-15). Rewrote the file's header comment to say so explicitly (NOT bumping the "confirmed deployed" date, since nothing has actually been confirmed deployed by this session) and to tell the user to diff before pasting into the dashboard, rather than silently presenting an edited backup as if it were a confirmed-safe change.

**Deployment is entirely manual, same as every edge function in this repo.** Committing these files to git does nothing on its own -- `resend-webhook` needs to be created fresh in the Supabase dashboard (with Verify JWT explicitly turned OFF, since Resend calls it with no Supabase auth at all), `smooth-action.ts`'s full updated source needs to be pasted into its existing dashboard entry and redeployed, a webhook needs to be registered in the Resend dashboard pointed at the new function's URL, and `RESEND_WEBHOOK_SECRET` needs to be set as a Supabase Edge Function secret using the signing secret Resend generates when that webhook is created. None of the tracking data will appear until all of that is done by hand -- sends themselves are unaffected either way (churchId is optional in the payload; omitting it, or the tracking inserts failing, never blocks or fails the actual email).

**Verified what this environment allows, nothing more claimed**: all `index.html` Find blocks matched exactly, no drift. All 4 non-module `<script>` blocks pass `node --check`, as do both edited/new `.ts` edge function files. Live in the browser: the new "Sent messages" panel renders with the correct heading and translated Spanish strings; `window.loadMessageHistory()` runs without throwing and correctly no-ops when signed out; the new `.msg-history-item` CSS (border-bottom, `:last-child` suppression, cursor, spacing) confirmed correct by injecting synthetic `<details>` markup and checking computed styles. **Could not test the actual send → webhook → status-update flow** -- that requires a real signed-in church-owner session, a real Resend account, and the Step 0 manual setup, none of which are reachable from here. The migration's own status-ladder logic (out-of-order event handling) was tested against a local Postgres instance per the prompt's own account, not independently re-verified here.

**Deliberately out of scope, per the prompt**: `welcome_email`, `contact_church`, `group_join_request`, `ownership_handoff`, `member_invite`, `event_contact_notify`, and the default staff-invite branch stay untracked -- none of those are shown anywhere an owner would currently look for delivery stats. Same pattern (`churchId` + `audienceLabel` through to the same two tables) extends cleanly to any of them later if wanted.

Build `2026-09-15-v1`.

---

## Mass-email replies had nowhere to go — and the right destination isn't always the owner

Asked directly: "what happens when someone sends an email back?" Checked the actual code rather than guessing -- `mass_email` (mass announcements + individual directory messages) sends `from: "{churchName} via FaithDock <invites@faithdock.com>"` with no `reply_to` at all, so a reply defaults to that shared FaithDock address -- not the church, not whoever sent it, not anything this app tracks or shows anywhere. `contact_church` (a visitor messaging a church) already sets `reply_to` correctly; `mass_email` never got the same treatment.

**Follow-up question sharpened the fix**: Messages has no staff permission gate at all (confirmed by checking -- `<a data-dash="messages">` has no `canManage*`-style conditional anywhere, unlike Billing/Settings), so whoever actually clicked Send is frequently a staff member the owner invited, not the owner themselves. A naive fix hardcoding `reply_to` to the church owner's email would have silently misrouted every staff-sent message's replies away from the person who actually needs to see them.

**Fix, in `smooth-action.ts`'s `mass_email` branch**: `reply_to` is now set to the actual sender's own email, sourced from the exact same `getUser(jwt)` call already added for the delivery-tracking feature's `senderId`/`created_by` -- that call already returns the full user object, so grabbing `.email` alongside `.id` needed no second lookup, no new round trip. Falls back to no `reply_to` (today's existing behavior, not worse than before) if the auth header is ever missing.

Scoped to `mass_email` only, matching what was actually asked -- `member_invite`, `event_contact_notify`, and the default staff-invite branch have their own different sender-attribution shapes (a plain `inviterName`/`addedByName` string, not structured the same way) and weren't part of this question.

Same deployment caveat as the delivery-tracking feature above: this is a further edit to `smooth-action.ts`'s already-pasted-and-confirmed (per the user, 2026-09-15) tracking version -- diff against the live dashboard source before pasting this on top, then redeploy. `node --check` passes.

---

## Extended the reply_to-the-actual-sender fix to the three branches deliberately left out above

User quoted the previous entry's own closing line back ("worth doing if you want, but a separate pass") and said "do it" -- extended the exact same `reply_to` fix to `member_invite`, `event_contact_notify`, and the default staff-invite branch in `smooth-action.ts`. All three previously sent with no `reply_to` at all, same gap `mass_email` had before the fix above.

**Same pattern, no shared helper**: each branch derives its own `senderEmail` locally via `getUser(jwt)` against its own `Authorization` header, right before building its send payload -- not extracted into a shared function, matching how none of this file's other per-type branches share helpers either. The default (staff-invite) branch isn't wrapped in its own `if (body.type === ...)` block -- it's the trailing fallthrough -- so its copy uses distinct names (`supabaseAdminForInvite`, `inviteSenderEmail`, etc.) out of caution, even though JS block-scoping means the other three branches' identical names (`supabaseAdmin`, `senderEmail`, `authHeader`, `authData`) inside their own `if {}` blocks would never have collided with it anyway.

**Checked staff-reachability per branch instead of assuming**: grepped `index.html` for `canManage*`-style gates near each trigger. `member_invite` (Directory/People's bulk CSV import + per-row "Resend invite") and `event_contact_notify` (fired when a contact is added during event creation/editing, gated only by `canManageEvents`) are both staff-reachable, same reasoning as `mass_email`. The default branch is the opposite: "Add staff by email" is gated `if (isOwner) { ... }` client-side, so `inviterName` there is never actually a staff member's name -- fixed anyway since it's still strictly better than every reply going to the shared `invites@faithdock.com` address, and keeps all four branches consistent.

Same deployment caveat as both entries above, restated a third time in the file's own header comment: this backup was not diffed against the live dashboard source first (no dashboard access from this environment) -- diff before pasting, then redeploy and update the header's "confirmed deployed" date. `node --check` passes.

---

## Added a real church-account roles/permissions system: owner-only billing, a Manager role, two new grantable staff abilities

A standalone prompt, independent of the message-delivery-tracking and denomination-taxonomy work landed earlier the same day. Adds migration `029_staff_abilities_and_manager_role.sql` (renumbered from the prompt's requested `028` -- that number was already taken by `028_message_delivery_tracking.sql`, confirmed via `ls supabase/migrations/` before creating the file) plus a large `index.html` pass (2a-2v in the prompt) wiring it into the Team panel, staff-permissions modal, Overview, and Admin pages.

**What changed, in one line each**: `can_manage_billing` is removed as a column entirely -- billing and church deletion become owner-only with no exceptions, not just defaulted off. Two new grantable abilities, `can_manage_groups` and `can_manage_messages` (the latter also tightens `message_batches`/`message_log`'s RLS from migration 028, replacing the blanket "any staff" check with this specific ability). A new `is_manager` ability, gated to standard/premium/multi_church tiers via a new `plan_tiers.can_assign_manager` column, lets a Manager invite/remove/edit *regular* (non-Manager) staff -- but never touch billing, deletion, another Manager's row, or grant Manager status to anyone. Two new RPCs, `get_church_staff_detail` and `update_staff_abilities`, replace `get_staff_with_permissions`/`update_staff_permissions` for the client's calls -- the old RPCs' SQL was never visible in this repo to safely edit in place, so they're left alone in the database (untracked, unused) rather than dropped blind.

**Migration renumbered 028 -> 029, and its own "migration 027" references corrected to 028.** Same drift-detection pattern as the last few migration prompts today: the prompt's disconnected scratch clone assumed `message_batches`/`message_log` were created in migration 027, but a grep of `supabase/migrations/*.sql` before writing this file showed they actually live in `028_message_delivery_tracking.sql` -- 027 is `027_denomination_pattern_gaps.sql`, unrelated. Corrected both the new migration's own comments and its `DROP POLICY` target names to match what's actually in 028 (`"Owner or staff can view their church's message batches"` / `"...message log"`), verified by grep rather than assumed.

**Why `is_church_manager()` and `can_manage_church_messages()` must be `SECURITY DEFINER`, not plain**: both are called directly inside RLS policies (not just nested inside the two `SECURITY DEFINER` RPCs). As a plain invoker-rights function, each one's own internal `SELECT` against `church_staff` would itself be subject to RLS for whoever's currently being checked -- and there's no policy letting a Manager plain-self-select their own row -- so the check would silently and permanently evaluate `false`. This was caught during the prompt's own local testing against a real non-superuser `authenticated` role (12 scenarios: owner access, Manager access to regular staff, Manager blocked from another Manager's row, Manager blocked from granting Manager, tier-gating, the new owner-only churches DELETE policy) -- not independently re-verified here, taken on the prompt's own account of that testing.

**No migration in this repo ever defined a DELETE policy on `churches`** -- the existing owner "Delete this church" button in Settings has been relying on something not visible in this repo's tracked migrations. This migration adds one explicitly (owner-only, no exceptions) rather than assuming it was already covered. The prompt flagged a real risk worth repeating here: if RLS were ever found disabled on the live `churches` table (`select relrowsecurity from pg_class where relname = 'churches';` should return `t`), every policy on that table -- this new one included -- would be a silent no-op. Worth checking once, independent of this migration.

**Every `index.html` Find block matched exactly on the first try** -- no drift despite three other features having landed in this file earlier the same day (denomination taxonomy, message delivery tracking, the reply_to extension above). Searched for every remaining `can_manage_billing`/`canManageBilling` reference after the edits (per the prompt's own explicit warning that a missed one would error immediately once the column is dropped) -- the only two left are the owner branch's hardcoded `canManageBilling: true` in `getMyChurch()` and the Settings billing-nav-link display check, both correct: staff no longer get `canManageBilling` set on their branch at all, so it's falsy for them without needing a code change there.

**Scope note carried through from the prompt, not resolved here**: `can_manage_groups` is a real, stored, UI-visible ability now, but this pass does not touch any RLS on `groups`/`group_members` -- that schema hasn't been reviewed yet. Wiring real group-CRUD enforcement to the flag is follow-up work. Similarly, Manager assignment on invite only works for someone who already has a FaithDock account -- `church_staff_invites` has no `is_manager` column and its auto-accept-on-signup trigger's source isn't visible in this repo to safely extend, so a not-yet-registered invitee can't be invited straight into Manager; they can be promoted from the team list after signing up.

Verified from this environment: all 4 non-module `<script>` blocks in `index.html` pass `node --check` after every edit, applied in order. Loaded the page in a local static preview -- no console errors on load. The SQL migration itself (columns, helper functions, RLS policies, both RPCs) was **not** re-tested against a live database from here -- taken on the prompt's own account of its local-Postgres testing described above. Same standing manual-migration caveat as every schema change in this repo: run `029_staff_abilities_and_manager_role.sql` by hand in the Supabase SQL Editor, and run the `relrowsecurity` check above either before or right after.

Build `2026-09-15-v2`.

---

## Gave staff its own dashboard page instead of a side-note tucked into Settings

Follow-up to the Manager-role feature above, requested the same day once it was live: invite/manage staff was buried in a 320px sidebar column on the Settings page, easy to miss, and there was no way to see a staff member's actual profile (photo, contact info, event/group sign-ups, giving history) without hunting for them separately in Directory. Added a dedicated "Staff" nav item, positioned between Insights and Billing in the dashboard sidebar, gated to tiers 2-5 (Starter/Standard/Premium/Multi-Church) -- free-tier churches get 0 staff seats (`planLimits.free.staff === 0`), so the page has nothing to offer them and the nav link stays hidden, reusing the `isPaidChurch` flag `loadDashboardHeader()` already computed for the church-status-tag wording.

**Pure relocation, not a rewrite**: `#team-list`, `#team-owner-controls`, and their child inputs/buttons kept their exact element IDs -- just moved from Settings' two-col sidebar into a new `<div class="dash-content" id="dash-staff">` panel. `loadTeamPanel()`, `bindTeamInviteBtn()`, and every click-delegated handler for invite/remove/edit-abilities/Manager-toggle needed zero logic changes, since they all operate on element IDs rather than caring which page currently holds them. Grepped for CSS selectors targeting those IDs first (`#team-list`, `#team-owner-controls`, `#team-count`) to confirm nothing styled them by page-context before moving them -- nothing did.

**Settings keeps a pointer, not a dead end**: the old Team side-note is replaced with a short "Team management has moved" card and a `data-dash="staff"` link -- free for the existing `[data-dash]` click-delegation to handle, no new JS. Hidden for free-tier churches the same way the new nav link is, via the same `isPaidChurch` check.

**"View their profile" reuses the Directory tab's existing person modal instead of building a new one.** Confirmed first that `#directory-person-modal` (and the other Directory modals) are DOM *siblings* of `#dash-directory`, not nested inside it -- `.dash-content{display:none} .dash-content.active{display:block}` means a modal nested inside a non-active tab's panel would never render regardless of its own `.open` class, so this only works because of where it already sits in the markup. Each staff row now carries `data-view-person-id="<user_id>"` on a small eye-icon button, which the Directory tab's own global click handler already listens for on `document` -- it looks the person up out of `directoryPeopleRaw`, which `loadDirectoryPeople()` populates unconditionally at dashboard load regardless of which tab is showing. Had to add `user_id` to the plain-staff-member branch's query too (`select('id, profiles!user_id(full_name)')` -> `select('id, user_id, profiles!user_id(full_name)')`) -- it was never selected before since nothing needed it prior to this.

Verified from this environment: all non-module `<script>` blocks pass `node --check`. Loaded the page in a local static preview and confirmed via `document.getElementById`/`querySelector` that the new nav link, panel, and Settings pointer all exist exactly once each (no duplicate `#team-count` from the move). Could not exercise the actual owner/Manager/staff view-switching or the profile modal end-to-end -- needs a real signed-in session against a live Supabase project with real staff rows.

Build `2026-09-15-v3`.

---

## Multi-part data-quality report: Spanish-language tagging gaps, an Ethiopian Orthodox miss, casing, and a "Ministries" hide widening

Reported live with real examples across 4 church cards. Checked the actual database state for each before writing anything, rather than assuming.

**1 & 2. Spanish "Luterana" and "Bautista" untagged.** Confirmed live: "Iglesia Luterana San Pablo" and all 6 live "Iglesia Bautista ..." rows had `denomination_tags: []` -- `compute_denomination_tags()` only ever recognized the English "Lutheran"/"Baptist" spellings. Migration 027 adds `\mluteran[oa]s?\M` (catches Luterano/Luterana/Luteranos/Luteranas) and `\mbautista\M` alongside the existing English patterns. "Bautista" doesn't inflect by gender in Spanish, so no suffix variants needed there.

**3. "Yeshuas Messianic Fellowship" -- checked, already correct.** `denomination_tags` is already `['Protestant','Messianic Judaism']` -- migration 026 has clearly already been run and is working as designed. No fix needed; flagging this explicitly rather than silently doing nothing, so it's clear this one was verified, not overlooked.

**4. "Debre Sahle St Michael Eritrean Ort Hodox Tewahdo Church" untagged.** Confirmed live: `denomination_tags: []`, `denomination: null`. Neither existing Oriental Orthodox signal matched -- "Tewahedo" (the pattern) vs. "Tewahdo" (this row's actual spelling, missing the middle "e", a genuinely common transliteration variant) is a straight miss, and "Orthodox" itself is split across two words in this row's own name ("Ort Hodox," almost certainly an OCR/import artifact not worth a one-off name correction). Migration 027 adds `\mtewahdo\M` as an explicit alternate spelling, plus `\mdebre\M` on its own -- Ge'ez/Amharic for "mountain/monastery," prefixing the large majority of Ethiopian/Eritrean Orthodox church names regardless of how the rest of the name is spelled or OCR'd, so it's a robust signal independent of either spelling issue.

**5 & 6. "Of"/"At" mid-name casing and the "Sa" -> "SA" abbreviation.** Both are exactly what the still-uncommitted `scripts/church-name-hygiene.js` (from earlier this session) and `scripts/acronym-exceptions.js` already exist to fix -- the user's own live examples ("Gospel Of Truth Church Of The Living God International," "Life Community Church Sa") directly validate and supersede the earlier pending-confirmation state for that work, so committing both scripts now rather than continuing to hold them. Added `'SA'` to `ACRONYM_EXCEPTIONS` (with a false-positive guard selftest -- confirmed `\bSA\b` doesn't fire inside "Casa"). Re-ran `church-name-hygiene.js` fresh against live data: 1 nonprofit-hide, 25 name fixes (TX and SA casing, locator-suffix strips, Of/At lowercasing all bundled into one file), 1 still-flagged truncated name. Regenerated `church_name_hygiene_fixes.sql` supersedes the earlier, narrower `san_antonio_metro_churches.fix_acronym_casing_tx.sql` -- safe to run either or both (idempotent, matches on the pre-fix name), but the new file alone covers everything.

**7. Widened the "hide Ministries orgs" pattern.** Migration 025 already has this (`\mministr(y|ies)\M`, `is_hidden = true`) but a live scan showed 46+ still-visible "Ministries"/"Ministry"-named orgs -- migration 025 evidently hasn't been run yet, which is the real answer to "hide all organizations that say Ministries." Separately, found one genuine pattern gap while checking: "Issues Of Life Ministrys" (misspelled, no apostrophe) doesn't match `\mministr(y|ies)\M` at all -- `\M` is a right-word-boundary anchor, and there's no boundary between the "y" and the trailing "s" in "Ministrys" (both are word characters), so the exact-token match silently misses it. Migration 027 widens the pattern to `\mministr(y|ies|ys)\M` and re-runs the hide UPDATE -- safe and idempotent regardless of whether 025 has already run, since it's scoped to `is_hidden = false`.

**Still needed from the user**: run `supabase/migrations/027_denomination_pattern_gaps.sql` (tagging gaps + widened Ministries hide) and `church_name_hygiene_fixes.sql` (casing/hygiene) in the Supabase SQL Editor. Migration 025 (the Ministries feature itself, plus its own hide pass) is still separately pending from earlier too.

No index.html changes in this pass -- purely migration + one-off SQL + the two hygiene scripts.

---

## Reported "Tx" casing + a Foursquare church badged "Non-denominational" — two separate data fixes

A church card screenshot ("New Braunfels Central Tx Foursquare Church") surfaced two independent issues at once.

**1. "Tx" casing.** `scripts/acronym-exceptions.js`'s `TX` addition to `ACRONYM_EXCEPTIONS` (added earlier this session, but left uncommitted pending confirmation of an unrelated batch in the same file's history) was exactly the fix for this -- re-ran it live and it correctly caught the reported church plus 4 more. Committed the script on its own this time (`TX` in the exceptions list, 2 selftest cases, the `require.main === module` CLI guard) since it's now proven against a real, reported bug rather than still-unconfirmed -- `scripts/README.md` and `scripts/church-name-hygiene.js` stay held back separately, since that diff is unrelated (documents a different script) and still awaits the user's confirmation they ran `church_name_hygiene_fixes.sql`. Generated SQL as `san_antonio_metro_churches.fix_acronym_casing_tx.sql` (a new file, not overwriting the original 9-fix batch, which was confirmed already applied -- none of its rows appeared in this fresh scan).

**2. Foursquare churches showing a "Non-denominational" badge.** Confirmed live against the database: all 3 Foursquare-named churches have `denomination_tags` already correctly `['Protestant', 'Pentecostal & Charismatic']` (migration 026's `compute_denomination_tags()` already matches "foursquare" in the name) -- so the Tradition *filter* was never wrong. The card *badge*, though, reads the single-value `denomination` column directly, which is `null` for all 3; the UI's own null-fallback (`row.denomination || 'Non-denominational'`, a deliberate default from earlier work so filter checkboxes still match) was what actually painted the misleading badge. Per the user's own confirmation ("foursquare churches are Pentecostal"), wrote `san_antonio_metro_churches.fix_denominations_foursquare.sql` setting `denomination = 'Pentecostal'` for all 3, id-scoped -- same shape as the pre-existing `fix_denominations.sql` (blank denomination, name states the tradition), extended rather than duplicated as its own follow-up file since that original batch was CSV-filename-scoped and these 3 weren't looked up that way.

Both new `.sql` files are one-off, untracked, sent to the user to run by hand -- neither is a schema change, so no migration file needed.

---

## Staff invites now require explicit acceptance; abilities are picked up front, not retroactively; fixed "View profile" on the new Staff page

Four related requests in one message about the Staff page shipped earlier the same day: (1) the "view profile" button did nothing, (2) staff invites should require the recipient to explicitly accept, going through account creation first if they don't have one yet, (3) an owner should pick a new hire's abilities via checklist *before* sending the invite, not edit them in after the fact, and (4) the Staff page should make clear which church's staff list is showing. A fifth, smaller ask: move the email field above "Add to" in the invite form.

**"View profile" fix -- defensive, not root-caused with certainty.** The button correctly carries `data-view-person-id`, and the click handler it shares with the Directory tab correctly looks the person up in `directoryPeopleRaw` -- but that array is only ever populated once, at dashboard load, scoped to whichever church was active *then*. Couldn't confirm from this environment whether `get_directory_people()` (source not visible in this repo) even returns a bare `church_staff` row with no membership/event/group history, so rather than guess at the RPC's internals, made the click handler defensive: if the clicked person isn't already in `directoryPeopleRaw`, it now re-fetches (scoped to the currently active church) before giving up. Fixes the most likely cause (staleness for a multi-church owner, or simply never having visited Directory this session) without touching backend SQL blind.

**Invites now always go through an accept step -- unifying two previously-different paths.** Before this: inviting someone who already had a FaithDock account added them to `church_staff` *instantly*, no acceptance, abilities defaulting to all-false; inviting someone without an account created a pending `church_staff_invites` row that an untracked, unseen database trigger auto-accepted the moment they signed up. Migration `030_staff_invites_require_acceptance.sql` unifies both into one path: `inviteStaffToOneChurch()` now always inserts into `church_staff_invites` (never `church_staff` directly), carrying the full abilities checklist + `is_manager` picked on the invite form. Nothing is ever added to a team until the recipient explicitly clicks Accept.

**Reused this repo's own established pattern instead of inventing one.** Found `church_ownership_handoffs`/`accept_church_ownership_handoff`/`decline_church_ownership_handoff` and the near-identical `church_member_invites` flow already doing exactly this shape of thing -- a `checkPendingX(userId)` function called from the same central post-sign-in block, showing a modal, Accept/Decline calling RPCs. Added `checkPendingStaffInvite(userId)` following that exact structure (new `staff-invite-prompt-modal`, wired in alongside `checkPendingMemberInvite`/`checkPendingOwnershipHandoff`), and two new RPCs (`accept_staff_invite`/`decline_staff_invite`) matching `accept_church_ownership_handoff`'s security-definer shape rather than `church_member_invites`' plain-client-update shape -- correctly, since creating a `church_staff` row is a privileged action the invitee has no RLS rights to do themselves (unlike a member invite, which only ever touches the invitee's *own* membership rows). The accept modal shows the invitee exactly which abilities they're being asked to accept (tag pills, same style as the Overview panel's staff badges) -- transparency, not a surprise revealed only after joining.

**Real, unavoidable risk flagged rather than assumed away**: earlier GOTCHAS entries describe an existing trigger that auto-accepts a pending `church_staff_invites` row the instant someone signs up with a matching email -- its source has never been visible from this environment, so this migration doesn't touch, alter, or assume anything about it. If it's still active, a brand-new signup could get a bare `church_staff` row (default/false abilities) from that trigger *before* ever seeing the new Accept/Decline prompt -- silently ignoring whatever the inviter actually selected. `accept_staff_invite()` is written defensively against exactly this: it `ON CONFLICT (church_id, user_id) DO UPDATE`s rather than a plain insert, so calling it still applies the invite's real abilities even if a bare row already exists from that trigger. Told the user directly to check the Supabase dashboard's Database > Triggers for anything referencing `church_staff_invites` and disable it, so new signups go through the same explicit-accept flow as everyone else.

**Abilities checklist moved to invite time.** The invite form now shows the same five ability checkboxes as the post-hoc edit-permissions modal (distinct `invite-perm-*` ids, since both can theoretically exist in the DOM at once), plus the existing owner-only/tier-gated Manager checkbox -- all picked before the "Send invite" button is even clicked. Shown to a Manager too, not just the owner: a Manager can already grant any of these five retroactively via `update_staff_abilities()` (migration 029), so letting them pick the same ones up front is no new privilege, only the Manager checkbox itself stays owner-only.

**Church-name clarity + form reorder**, both small: the Staff page's `<h2>` now shows the currently-active church's name (`loadTeamPanel()` already resolves `myChurch.name`, nothing new to fetch) -- the only thing on that page that made clear which church's list is showing was the sidebar, easy to miss. The invite form's email input moved above the "Add to" multi-church checklist per the user's explicit ask.

**Copy updated to match the new behavior, not left stale**: "Add to team" -> "Send invite", "Added to your team..." -> removed entirely (that message can no longer happen), and `smooth-action.ts`'s default branch email no longer says "you've been added" for an existing-account invitee -- both cases now say "invited... sign in to review and accept." Also corrected a now-stale claim in that same file's own header comment (added during the reply_to work three edits ago): it said the staff-invite branch was "confirmed owner-only in the UI," which migration 029 made untrue the moment Managers could invite too.

Verified from this environment: `node --check` passes on `smooth-action.ts` and every non-module `<script>` block in `index.html`; confirmed in a local static preview that every new element id (`staff-invite-prompt-modal` and its children, `staff-page-church-name`, all five `invite-perm-*` checkboxes) exists exactly once, and that `checkPendingStaffInvite`/`loadTeamPanel`/`bindTeamInviteBtn` are all defined with no console errors beyond the pre-existing, unrelated Cloudflare Turnstile localhost failure. **Could not verify**: the actual accept/decline RPCs against a live database, the `ON CONFLICT` upsert's behavior against a real pre-existing row, or whether the suspected auto-accept trigger is still active -- all need the user's own Supabase project and a real signed-in session neither is reachable from here.

Build `2026-09-15-v4`.

---

## First real-world test of the Staff page + invite-accept flow surfaced 5 issues -- 2 fixed, 1 explained (pending migration), 2 need more info

User tested the features shipped earlier the same day and reported five problems in one message. Investigated each rather than assuming they were all one root cause.

**Fixed: re-inviting someone after removing them failed with "You already invited that email."** A real regression from the accept-required change above: `church_staff_invites` rows are never deleted now (accepting/declining only flips `status`), but `inviteStaffToOneChurch()` was still a plain `insert()` -- the table's unique constraint on `(church_id, email)` (inferred from the pre-existing 23505 error handling, its exact definition not visible from this repo) meant a second invite to the same email+church collided forever, even after the person was removed as staff or the first invite was declined. Changed to `.upsert(..., { onConflict: 'church_id,email' })`, explicitly resetting `status: 'pending'` and `responded_at: null` on every (re-)invite, since `ON CONFLICT DO UPDATE` doesn't re-apply column defaults the way a fresh insert would. The now-unreachable `alreadyInvitedEmail` i18n key is left in place, unused, rather than hunting down every reference to remove it.

**Fixed: a completed donation didn't show up on Giving Insights.** `loadGivingInsights()` only ever ran once, at page load (plus on a language toggle) -- `goDash()` had no per-tab-visit refresh for `insights` the way it already does for `events` ("refresh registration counts the moment someone actually looks at this tab"). A donation completed after the dashboard was already open (exactly the reported test: give, get redirected back, then check Insights) would never appear until a full page reload. Added the same pattern `events` already uses. Scoped narrowly to `loadGivingInsights()` since that's what was reported -- the same staleness almost certainly applies to Attendance/Involvement/Groups insights too (none of those get a tab-visit refresh either), flagged to the user as a likely follow-up rather than fixed blind alongside an unrelated report.

**Explained, not a code bug: "Could not find the table 'public.church_ministries'."** Confirmed `025_church_ministries.sql` is exactly the migration that creates this table (and it already ends with `notify pgrst, 'reload schema'`) -- this is PostgREST's standard error for a table it doesn't know about, meaning migration 025 simply hasn't been run against this database yet. An earlier GOTCHAS entry already flagged 025 as still-pending from before today's Manager-role/Staff-page work even started, so this isn't new. Told the user directly rather than guessing at a code fix for a migration that was never applied.

**Needs more information -- staff permissions not carrying over after accepting an invite.** Two different explanations fit depending on facts not visible from here: (a) migration `030_staff_invites_require_acceptance.sql` hasn't been run yet, so `church_staff_invites` has no ability columns, `checkPendingStaffInvite()`'s RLS-gated read would fail silently, and the invite never shows the new Accept prompt at all; or (b) it *has* been run, but the untracked auto-accept-on-signup trigger flagged as a known risk in that migration's own header comment fired first for a brand-new signup, creating a bare `church_staff` row before the new prompt ever had a chance to run `accept_staff_invite()`'s upsert. `accept_staff_invite()` was written defensively against (b) already (upserts, doesn't plain-insert) -- if that's really what happened, re-running Accept on the same invite (if it's still showing as pending) or having the owner re-open the permissions modal and re-save should still fix it going forward, but the actual root cause needs the user to confirm which migrations are applied and whether the affected person already had a FaithDock account or was a brand-new signup, since the diagnosis differs each way.

**Needs more information -- completing a Stripe donation redirected to "Churches near you" instead of back to the church page.** Traced the redirect logic: `successUrl` is built client-side from `window.location.hash` at the moment "Give" is clicked (should already be the church's own `#church/<name>` hash), and `showRouteFromHash()`'s not-found handling (`else if (window.supabase) { go('directory', ...); }`) is what actually lands on a page titled "Churches near you" (the standalone Directory page reuses that exact same heading string as the homepage section) -- so `findOrFetchChurchByName()` returned zero rows for a *confirmed* (not just not-ready-yet) lookup. Migration `018_church_is_hidden.sql`'s own header comment explicitly says a hidden church stays "fully usable by its owner... direct #church/<name> URL," which would mean `is_hidden` shouldn't be the cause -- but that comment describes intent at write time, not necessarily the live RLS policy on `churches` today, which isn't tracked in any migration in this repo (dashboard-only, never seen). Couldn't confirm which of "RLS actually does block a hidden church's direct lookup" vs. "a name-encoding mismatch" vs. something in the `stripe-create-checkout` edge function (not backed up in this repo at all -- unlike `smooth-action.ts`/`resend-webhook.ts`, its source has never been pasted in) is the real cause. Asked the user for either the live RLS policy on `churches` or the `stripe-create-checkout` source before guessing at a fix.

Verified from this environment: `node --check` passes on the two fixes above. Neither was testable end-to-end (both need a live donation/invite cycle against the user's actual Supabase project).

Build `2026-09-15-v5`.

---

## Root-caused the Stripe redirect bug: a single query-string-after-hash bug explained both the redirect AND the missing Giving Insights amount

Follow-up to the "needs more information" item above. User provided both pieces asked for: the live RLS policy list on `churches`, and `stripe-create-checkout.ts`'s full source (first time this function's code has ever been visible from this environment -- it was never backed up to this repo before, unlike `smooth-action.ts`/`resend-webhook.ts`).

**RLS ruled out cleanly.** `churches are publicly readable` with `qual = true` -- an unconditional permissive SELECT policy. `is_hidden` was never the cause; confirms `018_church_is_hidden.sql`'s own header comment was accurate about live behavior, not just original intent.

**The actual bug, found in the pasted source**: `success_url: successUrl + (successUrl.indexOf('?') === -1 ? '?' : '&') + 'session_id={CHECKOUT_SESSION_ID}'`. `successUrl` from the client is always a hash-routed SPA URL with no query string of its own (`https://faithdock.com/#church/My%20Church`, built in `bindGiveSubmitBtn` as `origin + pathname + hash`). Appending `?session_id=...` onto the end of that string puts the query string *after* the `#` fragment -- which browsers never parse as a query string; it's just more hash. One bug, two separately-reported symptoms:

1. `window.location.search` is empty when Stripe redirects back, so `checkForCompletedDonation()` never finds `session_id`, never calls `confirm_donation`, and the donation row stays `status: 'pending'` forever -- this is why the amount never showed on Giving Insights. Not the staleness/no-refresh issue fixed two entries above (that fix is still correct and needed, just wasn't the actual cause of *this* specific report).
2. The app's hash router tries to parse `"My Church?session_id=cs_test_..."` as the church name, finds no match, and falls through to `showRouteFromHash`'s not-found redirect -- landing on "Churches near you."

**Fix**: `buildSuccessUrl()` splits the URL on its first `#`, inserts `session_id={CHECKOUT_SESSION_ID}` into the query string of the part *before* the fragment, then reassembles with the fragment after -- correct URL syntax (query string before fragment) instead of blind string concatenation. Tracked `stripe-create-checkout.ts` in this repo for the first time (`supabase/functions/stripe-create-checkout.ts`), same dashboard-only deploy convention as the other two edge functions, so future changes can diff against a known-good copy instead of starting from zero visibility again.

**Flagged, not silently fixed**: `startPaidEventCheckout()` in `index.html` builds its own `successUrl` for paid event tickets using the exact same `baseUrl + churchHash` pattern, passed to a *different* edge function (`stripe-event-checkout`) whose source has never been pasted into this repo either. Very likely has the identical bug, but unconfirmed -- asked the user to paste it rather than assuming and patching code never seen.

`node --check` passes on the new file. Not deployed -- needs the same manual paste-into-dashboard-and-redeploy treatment as every other edge function change.

---

## stripe-event-checkout.ts had the identical bug -- confirmed once the user pasted it, not assumed

Follow-up to the entry above. Asked the user to paste `stripe-event-checkout.ts`'s source since `startPaidEventCheckout()` in `index.html` builds its `successUrl` the exact same way as the giving flow. They did, and it's the same bug, character for character: `success_url: successUrl + (successUrl.indexOf('?') === -1 ? '?' : '&') + 'event_session_id={CHECKOUT_SESSION_ID}'` -- same query-string-after-hash-fragment problem, same two consequences (event registration's `confirm_registration` step never runs since `window.location.search` comes back empty, and the router's not-found fallback fires on the malformed hash).

Fixed the same way: added a `buildSuccessUrl(rawSuccessUrl, paramName)` in this file (parameterized for `event_session_id` instead of `session_id` -- can't share the helper between the two functions, since each Supabase Edge Function deploys as a fully separate, standalone script with no shared module). Tracked `stripe-event-checkout.ts` in this repo for the first time too, same as its sibling.

**Separately, user asked about a related-looking but actually-unrelated report**: a church card still showed "Managed by this church" after signing out. Traced `churchStatusTag()` -- the badge is driven purely by `!!c.ownerId` (does this church have *any* owner at all), not by who's currently signed in. It's a directory trust/quality signal ("this is a claimed, real listing" vs. an unclaimed auto-imported one), correctly church-scoped rather than viewer-scoped, so it's expected to persist regardless of session state. Not a bug -- explained rather than fixed, since assuming it should be personalized and changing the underlying logic would have been wrong. Flagged that the label itself reads ambiguously (sounds self-referential/personalized at a glance) and offered to reword it, but didn't change copy on a guess without the user weighing in first.

`node --check` passes. Not deployed -- same manual paste-and-redeploy as every edge function change in this repo.

---

## Swapped the confusing "Managed by this church" text tag for a checkmark badge

Follow-up to the "not a bug, but the label is confusing" note above -- user came back and asked to remove the text from the card entirely, suggesting a corner checkmark instead. Implemented exactly that rather than just removing the signal outright, since it's still a real, useful distinction (claimed vs. unclaimed listing).

**Split into two render paths**, since Card and List view have different anatomy: `claimedCardBadge()` returns a small absolutely-positioned gold circle + checkmark SVG, anchored to `.thumb` (already `position:relative`, confirmed by reading the existing CSS before adding to it) -- top-right corner of the card's photo/placeholder. `claimedRowIcon()` returns a plain inline checkmark SVG next to the name for List view, which has no thumbnail to anchor a corner badge to (its own comment already explains why: "the whole point is that a logoless church takes no extra vertical space"). Both keep the exact same underlying condition (`c.real && c.ownerId`) and the exact same explanatory text as a `title` attribute (hover/long-press) -- only the always-visible presentation changed, not the signal itself or who it's shown to.

Replaced the single `churchStatusTag()` function (and its `window.churchStatusTag` export) with these two, updating both call sites (`churchCard()`, `churchRow()`) and one stale comment in `populateChurchPage()` that still referenced the old function name.

**Scoped to the card/list views only, not the profile page.** The church detail page's own "Managed by this church" line (`#church-managed-line`, in `populateChurchPage()`) still shows the same text -- the user's report was specifically about "the card" (matching their screenshot, a directory search result), and changing the detail page's copy wasn't asked for. Left as a known follow-up if wanted, not silently extended past what was requested.

Verified in a local static preview by injecting a synthetic claimed church directly through `churchCard()`/`churchRow()` (no live Supabase data needed for a pure rendering check) -- the badge renders as a legible gold circle with good contrast against the checkmark's navy stroke in both card and row layouts, confirmed by screenshot. `node --check` passes on all script blocks.

Build `2026-09-15-v6`.

---

## The checkmark badge didn't survive contact with the user either -- replaced with a real follow-church heart, plus a matching Directory "Followed" filter

Third attempt at this exact UI slot in one day: "Managed by this church" text -> a checkmark badge (previous entry) -> now dropped entirely per direct feedback ("this feature doesn't make sense yet") in favor of a genuinely different, interactive feature -- a follow/unfollow heart, reusing the `church_follows` table the church profile page's own Follow button already writes to.

**Found and reused existing infrastructure instead of building parallel state.** The church profile page already has a full follow implementation (`checkChurchFollowStatus()`, the `church-follow-btn` click handler, `church_follows` insert/delete) and the Events page already has a working "Churches I follow" filter checkbox (`filter-followed-wrap` / `window.myFollowedChurchIds`, populated by `loadEventFilterFollowState()` on every sign-in refresh). Neither needed to be reinvented -- `followHeartCard()`/`followHeartRow()` just read `window.myFollowedChurchIds` for their initial state, and the new click handler follows the exact same insert/delete pattern as `church-follow-btn`.

**`followHeartCard()` anchors to `.thumb`'s corner (card view); `followHeartRow()` sits on the row's right side, before the chevron** -- per explicit instruction ("for list view, the hearts is on right side"), not next to the name where the old checkmark sat. Unlike the claimed-indicator it replaces, followability no longer depends on `c.ownerId` at all -- every real church can be followed regardless of claim status, a genuine semantic change, not just a visual one.

**Click handling needed care because the heart lives inside an already-clickable card/row.** `churchCard()`/`churchRow()` wrap their whole content in `<a href="#church/...">`; the heart `<button>` nested inside it needs both `preventDefault()` and `stopPropagation()` in its click handler, or clicking the heart would also navigate to the church page. Toggling flips just the clicked button's own `data-following` attribute (and `window.myFollowedChurchIds`) rather than re-rendering the whole grid -- cheaper, and every other heart already reads fresh state the next time it's actually re-rendered (page change, filter change, sign-in).

**Directory's own "Followed" filter needed a real schema change, unlike Events'.** `search_events()` already had a `p_church_ids` parameter (added in migration 019/022) that its own "Churches I follow" filter uses to narrow results server-side; `search_churches()` never had the equivalent. Migration `031_search_churches_followed_filter.sql` adds it, repeating the exact drop-then-create hazard migration 023 already documented and hit for real ("Postgres identifies a function by name + full parameter signature... CREATE OR REPLACE does NOT treat an added parameter as replacing the existing overload, it creates a second one, and the RPC call then fails outright with 'function search_churches() is not unique'") -- the existing 9-parameter version is dropped explicitly first. New checkbox (`dir-filter-followed-wrap`) mirrors the Events page's markup/wiring exactly: hidden until `myFollowedChurchIds` is non-empty, wired into the existing `change`/`click` delegated handlers (including `filter-reset`), and folded into `currentDirectoryFilters()`/`renderDirectory()`'s existing `baseParams` object.

**`loadEventFilterFollowState()` extended, not duplicated** -- it already runs unconditionally on every sign-in refresh regardless of which page is showing (confirmed by reading its own early-return guard: only bails if the *Events* page's own elements are missing from the DOM, which never happens in this single-page app). Added the Directory checkbox's visibility toggle and two more unconditional re-render calls (`renderDirectory()`, `renderHomeChurches()`) alongside the existing `renderEvents()` one, so every heart already on screen picks up real follow state the moment it's available instead of staying stuck empty until something else happened to trigger a fresh render.

**Also removed, per explicit request**: the "Chosen now, before they accept..." hint line above "Permissions" on the Staff invite form (both the static HTML and the JS-built version in `loadTeamPanel()`) -- the now-orphaned `dashSettings.inviteAbilitiesHint` i18n key is left in place, unused, matching this file's established convention.

Verified in a local static preview: injected synthetic followed/unfollowed churches directly through `churchCard()`/`churchRow()` and confirmed both fill states render correctly (clay heart vs. outline) by screenshot, in both card and list layouts; confirmed the new Directory filter checkbox exists in the DOM and stays hidden by default (correct -- empty `myFollowedChurchIds` for a signed-out preview); confirmed the invite form's Permissions section renders cleanly with the hint line gone. `node --check` passes on all script blocks. **Not tested**: the actual click-to-follow round trip against a live `church_follows` table, or `search_churches()`'s new `p_church_ids` parameter against a live database -- both need the user's own Supabase project.

Build `2026-09-15-v7`.

---

## Follow heart: fixed a real click-through-to-navigation bug and a CSS specificity leak, both from direct user feedback on the previous entry's screenshot

Three concrete complaints about the just-shipped follow heart: remove the circle behind it, remove its border/outline, and clicking it was navigating to the church profile page instead of just toggling follow -- plus a color swap (dark grey empty, white filled, not the clay/outline scheme from before).

**The click-through was a real, confirmed bug, not a misunderstanding.** `preventDefault()`/`stopPropagation()` inside the new delegated click handler (added in the previous commit) never got a chance to run: an *earlier*-registered `document.addEventListener('click', ...)` handles every `[data-route]` element, and since the heart `<button>` sits inside the card/row's own `<a data-route="church">`, `ev.target.closest('[data-route]')` from that earlier handler finds the ancestor link and navigates *before* the heart's own handler (registered much later in the file) ever runs -- calling `stopPropagation()` afterward can't retroactively stop a sibling listener on the same element that already fired. Multiple listeners on the same element run in registration order regardless of what a later one does to the event. Fixed at the actual interception point: that earlier handler already had an established early-return exclusion list for exactly this situation (`.register-real-btn`, `.qr-btn`, `.group-join-btn`, `#waitlist-banner-close`) -- added `[data-follow-church-id]` to it rather than reordering handler registration or duplicating exclusion logic elsewhere. Verified the fix directly: simulated a click on a heart injected into a live preview and confirmed `location.hash` was unchanged afterward.

**The CSS fix needed two passes, not one.** First pass (reordering the heart's CSS block to come after `.thumb--denom`'s rules in the stylesheet) was based on an incomplete diagnosis -- assumed an equal-specificity source-order tie, confirmed via computed-style inspection that it was actually `html[data-theme="dark"] .thumb--denom svg` (specificity 0,0,2,2, generically styling *any* svg inside a logoless card's placeholder, including the heart nested inside it) beating the heart's own rule (0,0,1,1) on genuine specificity, not just source order -- reordering alone couldn't fix that. Re-diagnosed properly before reaching for `!important` on the specific properties that needed to win unconditionally (`fill`, `stroke`, `opacity`) rather than guessing at a fix and moving on. Confirmed via computed-style inspection after the real fix: `rgb(255,255,255)` (followed) and `rgb(74,74,74)` (not followed), both `opacity: 1`, matching what was asked exactly.

Circle background and stroke/border both removed outright (`background:none`, `border:none`, `stroke:none`) -- a `drop-shadow` filter is the only thing left keeping the plain silhouette legible against whatever photo happens to be behind it on the card, since there's no background plate anymore to guarantee contrast.

**Flagged, not silently overridden**: applied the exact grey/white scheme requested to both card and list-row hearts for consistency, but the list row sits on `.church-row`'s own card background (`--card: #FCFBF7`, near-white in light theme) -- a white filled heart there could read as nearly invisible in light mode specifically. This wasn't asked about and wasn't obvious from the card-only screenshot that prompted the request, so it's implemented as specified rather than unilaterally changed, with this called out directly so it can be verified/adjusted if it turns out to be a real problem in light theme.

`node --check` passes on all script blocks. Verified in a local preview: computed fill/stroke/opacity for both states, and the click-through fix via a simulated click + hash check. **Not tested**: light-theme List view specifically (the flagged legibility concern above), and the actual toggle against a live `church_follows` table.

Build `2026-09-15-v8`.

---

## List view's follow-heart click target was too small -- easy to miss and hit the row instead

Direct follow-up: 2px of padding around a 17px icon (~21px effective target) was too small to reliably hit, and missing it landed the click on the row itself, which navigates to the church page -- a plausible real annoyance given the previous entry's click-through bug meant this exact miss used to always misfire before the fix. Bumped `.follow-heart-row`'s padding to 9px (35x35px effective click target, confirmed via `getBoundingClientRect()` in a local preview, comfortably past typical minimum touch-target guidance) without changing the heart icon's own visual size -- only the invisible hit area grew. Added a small negative `margin-right` to keep the row's right-edge spacing looking the same as before relative to the chevron, since the extra padding would otherwise visibly push the icon and everything after it further right. Card view's heart (`.follow-heart-card`) wasn't touched -- the report was specifically about List view.

Verified in a local preview: measured the actual click target size before/after, and confirmed by screenshot that the row's layout doesn't overflow or misalign with the extra padding. `node --check` passes.

Build `2026-09-15-v9`.

---

## Follow-heart color/shadow refinements (v10-v13) -- recorded after the fact, several quick rounds without a GOTCHAS entry each

Three more direct-feedback rounds landed on the heart in quick succession without a paper trail at the time; recording the net effect now rather than leaving the gap.

**v10**: renamed the "Churches I follow" filter checkbox label to "Followed Churches" (one shared i18n key, `events.churchesIFollow`, covers both the Events and Directory filter panels -- Spanish updated to "Iglesias seguidas" too). No functional change, no entry needed at the time.

**v11**: made the card heart's *unfollowed* color theme-aware -- light grey (`#C7C7C7`) in light mode instead of the dark grey used everywhere, dark mode unchanged. Applied to both card and row.

**v12**: light-mode card heart redesigned again, per more specific feedback -- empty state's fill now matches the card's own background color (`hsl(var(--thumb-hue,220) 34% 88%)`, the exact formula `.thumb--denom` itself uses) with a grey stroke outline, so it blends into the pastel placeholder rather than sitting on top as a solid shape; followed state turns solid white. Drop-shadow removed in light mode (no longer needed once the fill deliberately matches the card) but kept in dark mode, where there's no single "card color" a stroke-only heart could reliably blend into. Had to explicitly scope the dark-mode followed-state override under `html[data-theme="dark"]` -- the plain dark-mode default rule (specificity 0,0,2,2) otherwise outranks an unscoped `[data-following="true"]` rule (0,0,2,1), so a followed heart would silently never turn white in dark mode without it.

**v13**: the click handler's brief `disabled = true` (blocking a double-click race while the follow/unfollow request is in flight) was showing the browser's default not-allowed cursor for that split second -- reported directly as a red "no entry" flash. Fixed with `.follow-heart-card:disabled, .follow-heart-row:disabled{cursor:pointer;}`, keeping the functional disable without the jarring cursor.

---

## List view heart redesigned again: hollow grey outline (light mode) / grey fill when followed, plus a confirmed-live dark-mode bug fix

Continuing the same feedback thread: light mode's List view heart should be a grey-bordered, unfilled outline when empty, and a solid grey heart (no card-color-blend treatment like the card gets -- rows have no single background hue to blend into) when followed. Separately, dark mode's followed heart should be white.

**The dark-mode "should be white" ask surfaced a real, live bug**, not just a preference -- checked before assuming: `.follow-heart-row[data-following="true"] svg{fill:#fff;}` was still unscoped (never got the same fix `.follow-heart-card` received in v12), so `html[data-theme="dark"] .follow-heart-row svg`'s higher specificity (0,0,2,2 vs. the unscoped rule's 0,0,2,1) was silently keeping a *followed* heart dark grey in dark mode List view. Confirmed via computed-style inspection in a local preview before fixing (`fill: rgb(74, 74, 74)` where white was expected), then fixed the same way as the card: `html[data-theme="dark"] .follow-heart-row[data-following="true"] svg{fill:#fff;}`, explicitly scoped so it outranks the dark-mode default.

Light mode's new hollow-outline treatment (`stroke:#8A8A8A;fill:none` empty, `fill:#8A8A8A` solid grey when followed) didn't need `!important` the way the card's rules do -- confirmed there's no `.thumb--denom`-style generic `svg` rule that could leak into `.follow-heart-row`, since List rows have no thumbnail element for the heart to nest inside.

Verified in a local preview: computed fill/stroke for all four combinations (light/dark x empty/followed) match exactly what was asked, confirmed by screenshot for the light-mode pair. `node --check` passes.

Build `2026-09-15-v14`.

---

## Added an upload-progress indicator for the church-logo field -- "Save changes" already waited for it, that part just wasn't visible

User reported "Save changes" seeming to hang on a large logo image, asking whether it could show a progress bar, and whether saving should wait for the upload to finish. Checked the existing code before assuming either was missing: `rc-submit-btn`'s click handler already `await`s `supabase.storage.from('church-logos').upload(...)` before touching the `churches` row at all, and `btn.disabled = true` was already set for the whole operation -- the wait was real and already correct, it just had zero visual explanation, so a large upload looked identical to a hung button.

**Genuinely indeterminate, not a fake percentage.** The Supabase JS storage client's `.upload()` is a plain `fetch` under the hood, which has no upload-progress event the way `XMLHttpRequest.upload.onprogress` does -- there's no real byte count to report without reimplementing the authenticated upload call by hand (bucket/path resolution, JWT header, content-type) outside the SDK, which felt like too much risk to a currently-working upload for what this needed. Built an honest animated sliding-fill bar (`@keyframes uploadProgressSlide`) instead of pretending to track real progress.

Shown only around the actual `.storage.upload()` call (`#rc-logo-upload-progress`, initially `display:none`), and unconditionally hidden in the click handler's existing `finally` block (already there for `btn.disabled = false`) -- guarantees it never gets stuck visible regardless of which path the function exits through (success, a thrown error, or an early `return` from `showRcError`).

Scoped to the register-church form's logo field (`rc-logo`/`rc-submit-btn`) only, matching the reported screenshot -- the Admin panel's separate church-edit form and the event-image upload field (`ce-image`) weren't touched, since neither was what was reported.

Verified in a local preview: confirmed the element exists and starts hidden, and visually confirmed the bar/label render correctly by screenshot. `node --check` passes. **Not tested**: an actual large-file upload against live Supabase Storage.

Build `2026-09-15-v15`.

---

## The progress bar from the entry above never hid itself -- my own edit put the hide logic in the wrong handler entirely

Real, live bug reported directly by the user: uploaded a large image, watched "Uploading image..." stay up seemingly forever, but separately confirmed via the directory grid that the church had actually saved successfully with the new logo. Asked one clarifying question before touching anything -- was the Save button *also* still stuck disabled, or had it gone back to normal? Answer: the button re-enabled fine, only the bar stayed stuck. Since both are set in the same `finally` block, that meant they couldn't both live in the block that actually runs for this handler -- a real, diagnosable clue, not a guess.

**Root cause: the previous entry's edit landed in the wrong function.** `rc-submit-btn`'s real click handler opens one `try` and doesn't close it (into its own `finally`) until much later in the file, after both the edit-church and create-church branches. In between sits an unrelated block -- the *sign-in form's* own `try/finally` -- whose closing `finally { btn.disabled = false; }` happens to be immediately followed by `showRcError`/`showRcSuccess`'s function definitions (register-church's own helpers, defined once, positioned right after the sign-in handler purely by file-organization coincidence, not because they belong to it). The previous edit's `old_string` match (`} finally { btn.disabled = false; } }); function showRcError(msg){`) was unique in the file, so the Edit tool didn't -- and couldn't -- catch the mistake; the match itself was correct, the assumption about which handler it belonged to was wrong. Confirmed by reading the surrounding code (`routeAfterLogin triggered via manual sign-in path`, `window.awaitingEmailConfirmation` handling) rather than trusting the earlier placement.

Net effect: the "show" call was correctly placed (inside the true `rc-submit-btn` handler, right before the actual `.storage.upload()` call), but the "hide" call sat in a handler that only ever runs when someone signs in -- never during a church save. The bar would show correctly and then simply never be told to stop.

**Fix**: reverted the sign-in handler's `finally` back to just `btn.disabled = false;`, and added the hide logic to `rc-submit-btn`'s actual closing `finally` (the one that comes after both the edit and create branches, right before the "Real event creation" section comment) -- the same block that already correctly resets `btn.disabled` for both branches. `node --check` passes; not re-tested against a live large-file upload from here, since that needs the user's own Supabase project.

Build `2026-09-15-v16`.

---

## Church-save success message now links to the public church page

User asked for the "Saved!" message to include a "View your church page" link so an owner can quickly check their update on the public side without hunting for it themselves.

**`showRcSuccess()` switched from `textContent` to `innerHTML`** to render an actual `<a>` tag -- checked every other call site first (all pass plain developer-authored strings with no `<`/`>`/`&` in them, so the switch is safe for those unchanged). The one call site that interpolates real user data (the church's own name, which anyone can type freely) escapes it itself before it ever reaches `showRcSuccess()`: `churchNameHtml` (`&`/`<`/`>` escaped, for the human-readable text between quotes) and `churchNameAttr` (`"` escaped, for the `data-church-name` attribute) are two separately-escaped values for two different contexts, not one shared string -- verified in a local preview with a deliberately hostile test name (`Test <b>2</b> & "Sons"`) that the `<b>` came through as literal escaped text, not a real bold element, before considering this safe.

**Reused the existing `[data-route="church"]` click-delegation pattern** rather than inventing new navigation logic -- the link carries `data-route="church"` and `data-church-name="..."`, the same two attributes `churchCard()`/`churchRow()` already put on every directory card/row link, so the document-level click handler that already knows how to resolve and navigate to a church page picks it up for free.

**Appended to both outcomes of a successful update, not just the plain-success case** -- the same link is appended whether the message ends up being the default "Saved!" text or one of the two `geocodeWarning` fallback strings (an exact-address-not-found or location-lookup-failure caveat), since the church itself saved successfully in every one of those cases; only the wording of what's said differs.

Scoped to the edit/update branch only -- the create-new-church branch doesn't call `showRcSuccess()` at all (it redirects straight to the new church's dashboard instead), so there's no equivalent "stay on this page and see a message" moment to add the link to there.

Verified in a local preview: rendered the exact same escaping logic against a hostile test name and confirmed via `querySelector` that the link's `href`/`data-church-name` are populated correctly and no real `<b>` element exists in the output. `node --check` passes.

Build `2026-09-15-v17`.

---

## Card-view followed heart was invisible against a real logo -- switched white fill to a distinct pink

User noticed the followed (filled) heart was hard to see against a church's uploaded logo, in *both* light and dark mode -- traced this back to `churchCard()`'s own background handling: a real logo's `.thumb` always gets a hardcoded `background-color:#fff` (see the earlier "why is there a white border" thread, kept intentionally so a transparent-PNG logo doesn't show through to something odd), and that white background doesn't change with theme. The followed heart's fill was `#fff` in both themes too, so it blended into any real logo's background regardless of light/dark mode -- not a theme bug, a straight color collision.

**Picked a hex that's genuinely new to the palette, not assumed distinct.** Checked the existing CSS variables first: `--clay` (`#A8503A` light / `#E2917A` dark) reads as coral/terracotta, not pink; `--clay-bg` (`#F3E4DE`) is a pale beige. Landed on `#F0A8C4`, a clear soft rose pink with no existing use anywhere in the stylesheet. Applied to both `.follow-heart-card[data-following="true"] svg` (light mode) and its `html[data-theme="dark"]`-scoped counterpart, replacing `#fff` in both -- the grey stroke stays unchanged in light mode.

Scoped to Card view only -- List view has no thumbnail at all, so its heart never sits on a logo's white background and wasn't affected by this specific collision.

Verified in a local preview: rendered a card with a real (placeholder) logo image and confirmed via computed style that the filled heart's fill is `rgb(240, 168, 196)` (`#F0A8C4`) in both light and dark mode, then confirmed by screenshot that it reads clearly against the white logo background. `node --check` passes.

Build `2026-09-15-v18`.

---

## Three requests in one message: simplified the staff-invite prompt, made granted abilities visible after the fact, and fixed a mobile layout bug on Settings

**Removed the ability tag pills from the staff-invite Accept/Decline modal** -- user judged them unnecessary there. `checkPendingStaffInvite()` no longer selects or renders `can_manage_*`/`is_manager` for the preview (still selected server-side by `accept_staff_invite()` itself when accepted, unaffected), and the now-empty `#staff-invite-prompt-abilities` div was removed from the modal markup.

**Made granted abilities visible after the fact instead**, per the second half of the same request -- "their permissions should be viewable to an invited staff member in the staff page and profile":

- **Staff page**: `loadTeamPanel()` previously gave a regular (non-owner, non-Manager) staff viewer a name-only list with no ability info at all, via a separate, narrower query than what the owner/Manager branch used. Checked `get_church_staff_detail()`'s own auth check first (migration 029) -- it's already callable by the owner *or any staff member* of the church, not owner/Manager-only -- so simplified to one unconditional call for every viewer, and added ability tags (same `tag sage` badge style the Overview panel already uses for this) to every row's display, not gated behind edit permissions. A regular staff member now sees the whole team's abilities, including their own, the same way an owner already could.
- **Profile page**: added a new "Staff at [church]" row (`#profile-staff-row`), shown whenever `getMyChurch()` resolves to `role: 'staff'` for the currently active church, with the same ability tags. Verified `getMyChurch`/`displayChurchName` are callable bare (no `window.` prefix) from `loadProfilePage()`'s scope by confirming both are already called bare from dozens of other locations spanning the same script block, rather than assuming.

**Fixed a real, reported mobile layout bug on Settings**, unrelated to the above but reported in the same message: the two-column Church-profile/Team layout stayed two narrow, cramped columns on mobile instead of collapsing to one. Root cause: `.two-col`'s own class rule already has a `max-width:860px` responsive breakpoint that collapses it to a single column, but the Settings page's specific `<div class="two-col">` carried an inline `style="grid-template-columns:1fr 320px;"` -- an inline style always wins over a media-query class rule regardless of screen width, so the breakpoint was being silently defeated only on this one page. Removed the inline override (the class's own default, `1fr 300px`, is close enough that dropping the extra 20px isn't a meaningful desktop change) and grepped every other `.two-col` usage in the file to confirm none of the other three had the same inline `grid-template-columns` override -- only Settings did.

Verified in a local preview: confirmed via computed style that `.two-col`'s `grid-template-columns` is `375px` (a single column) at mobile viewport width, by screenshot that Settings reads full-width and legible on mobile now, and via direct DOM population that the new profile staff-row and the Staff page's per-row ability tags render correctly. `node --check` passes. **Not tested**: the real invite-accept flow and Staff page against a live Supabase project with real staff rows.

Build `2026-09-15-v19`.

---

## Mobile follow-heart tap made the whole card "blink" -- browser's default tap-highlight, not a JS bug

User confirmed the earlier click-through fix actually works on mobile (tapping the heart no longer navigates), but noticed the whole card visibly flashes as if it were also tapped. Not a JS problem -- `preventDefault()`/`stopPropagation()` in the heart's click handler only stop the click's default action and its bubbling to other *JS listeners*; they have no effect on the browser's own tap-highlight overlay, which mobile WebKit/Chrome paint over an entire tapped link based on touch state alone, independent of what any click handler does. Since the heart sits inside the card's own `<a>`, a tap landing on the heart still lands inside the link's bounding box, so the browser highlighted the whole card regardless of the navigation being correctly suppressed.

Confirmed no existing `-webkit-tap-highlight-color` reset anywhere in the stylesheet before adding one (would have been redundant/conflicting otherwise). Added `-webkit-tap-highlight-color:transparent` to `.church-card`/`.event-card` (shared rule) and `.church-row`, the two link-wrapped containers the follow-heart lives inside.

Verified in a local preview: computed `webkitTapHighlightColor` on both `.church-card` and `.church-row` resolves to `rgba(0, 0, 0, 0)` (fully transparent) after the change. `node --check` passes -- pure CSS, no JS touched. **Not tested**: an actual physical mobile device/touchscreen, since this environment can only emulate viewport size, not real touch-highlight rendering.

Build `2026-09-15-v20`.

---

## Multi-word location names ("San Antonio") could break mid-name on the homepage heading

Reported with a mobile screenshot: "Churches near San / Antonio", the line break landing inside the city name itself rather than before it. `setDirLocation()` was building the whole heading (`"Churches near " + label`) as one plain string via `textContent`, so the browser was free to wrap anywhere a space allowed, including the one inside "San Antonio".

Fixed by wrapping just the location portion in its own `<span style="white-space:nowrap;">` -- the location now wraps as one atomic unit; a break can still fall before "Churches near ..." if the line's too narrow, just never inside the place name. Applied to both the church heading and the parallel "Upcoming events near ..." heading, which builds from the exact same `label` and had the identical latent bug, unreported but not left as a known gap.

**Switching `textContent` to `innerHTML` needed escaping first, checked rather than assumed safe.** Traced every call site of `setDirLocation()`: most pass a geocoding API's `formatted_address`, but a couple explicitly fall back to the raw text someone typed into the location field (`dirLocationInput.value`/`eventsLocationInput.value`) when a formatted address wasn't available -- meaning `label` isn't always trustworthy content. Escaped it (`&`/`<`/`>`) before building the span, same defensive pattern already used for the church-name link in `showRcSuccess()`. Verified against a deliberately hostile test string (`<b>XSS</b> & "Test"`) that it renders as literal escaped text, not a real bold element.

Verified in a local preview at mobile viewport width: confirmed by screenshot that "San Antonio" now stays together on one line instead of splitting, and confirmed via `innerHTML`/`querySelector` inspection that the escaping holds against injection. `node --check` passes.

Build `2026-09-15-v21`.

---

## Mobile: search fields auto-center on focus; follow-heart made bigger

Two small mobile-only requests in the same message.

**Search fields auto-center on focus, mobile only.** Tapping a keyword/location field left it wherever it happened to be scrolled to, easy to end up half-covered once the on-screen keyboard opens. One delegated `focusin` listener (not `focus`, which doesn't bubble, so a delegated single listener wouldn't catch it) covers all six keyword/location inputs across Home, Directory, and Events, calling `scrollIntoView({behavior:'smooth', block:'center'})` after a 300ms delay (keyboards animate in over a few hundred ms; centering before that finishes just gets shoved out of place again once it settles). Gated to `window.innerWidth <= 860` -- desktop has no on-screen keyboard displacing anything, so the same jump there would just be an unexplained page shift. Verified in a local preview by stubbing `scrollIntoView` and dispatching a synthetic `focusin`: fires with the right options at 375px width, confirmed it does *not* fire at a genuine desktop width (1400px) -- the pane's own "desktop" preset turned out to render at 800px in this environment, narrower than the 860px gate, which would have made the test wrongly report success without an explicit wide resize to rule that out.

**Follow-heart enlarged on phones**, per direct request. `600px` matches this file's own established phone-specific breakpoint (several other `max-width:600px` rules already exist in this stylesheet) rather than the broader ~860px tablet/layout one. Card heart's button/hit-area grows alongside its icon (28px -> 34px, 18px -> 22px) rather than just the icon inside an unchanged box, so it doesn't start crowding the card's corner; List row's icon grows on its own (17px -> 21px, its click target was already enlarged separately in an earlier fix). Caught and fixed a near-repeat of an earlier mistake before it shipped: the card heart's base size rule is `!important` (required to beat `.thumb--denom svg`'s specificity on logoless cards), so the mobile override needed `!important` too, or a non-!important media-query rule would silently lose regardless of matching -- checked this against the base rule before assuming a plain override would work.

**Debugging note, not a real bug**: initial verification showed neither change taking effect in the local preview at all, despite `window.matchMedia('(max-width:600px)').matches` correctly returning `true`. Root cause was simply a stale page -- the preview tab had been open since before the edit landed, and CSS changes to an already-parsed stylesheet don't retroactively apply without at least a reload of the page that references it. A fresh navigate to the same URL resolved it immediately. Worth remembering given the *live* site's own still-splitting "San Antonio" screenshot from the previous request landed in the same conversation -- almost certainly the identical cause (a not-yet-refreshed page, or Cloudflare Pages still finishing its deploy) rather than the fix having failed, though that one couldn't be directly confirmed from here since it's the user's own device on the live domain, not this local preview.

`node --check` passes on both changes. Verified in a local preview via computed style (`34px x 34px` / `22px x 22px` / `21px x 21px`, matching exactly) and by screenshot. **Not tested**: either behavior on an actual physical phone.

Build `2026-09-15-v22`.

---

## "Churches near you" on load: cards and location both made faster, two separate causes fixed

"when refreshing 'churches near you' on mobile and desktop, since it automatically inputs near me San Antonio in my case, it takes a second for the location to fill in the location bar and the cards to switch. can that be more immediate or faster?" Two independent, stacked sources of delay, fixed separately.

**Cause 1 -- cards were blocked on the wrong network call.** `autoDetectHomeLocation()` called `setDirLocation(lat, lng, label)` exactly once, only after *both* `navigator.geolocation.getCurrentPosition()` *and* a separate `google.maps.Geocoder().geocode(...)` reverse-geocode call had finished. But `renderDirectory()`/`renderHomeChurches()`/`renderEvents()`/`renderHomeEvents()` -- the functions that actually draw the cards -- only ever read `window.dirUserLat`/`window.dirUserLng`; none of them touch the human-readable label at all. The reverse-geocode call (a second, slower round trip, needed only to turn coordinates into a city name for display) was needlessly serialized in front of card rendering. Split `setDirLocation()` into `applyDirLocationCoords(lat, lng)` (sets the globals, fires all four render calls) and `applyDirLocationLabel(label)` (updates the location inputs, clear-button sync, and headings text only) -- `setDirLocation()` itself now just calls both in sequence for its other, pre-existing callers (the manual "use my location" button, etc.) so nothing else changed behavior. `autoDetectHomeLocation()` now calls `applyDirLocationCoords()` the instant the GPS fix resolves, and only calls `applyDirLocationLabel()` once the geocode callback fires afterward -- cards now render a full network round-trip earlier than the location text does, instead of both waiting on the slower call together.

**Cause 2 -- geolocation itself didn't start until Google's Maps script had finished loading, even though it doesn't need Maps at all.** `autoDetectHomeLocation()` is only ever invoked from `_runGoogleMapsSetup()`, gated on `window.googleMapsReady` -- so the browser's location permission prompt/fix couldn't even *begin* until the async Google Maps script (loaded separately, `<script async src="...maps.googleapis.com...">`) had finished fetching and firing its callback, purely because that's where the function happened to live, not because `navigator.geolocation.getCurrentPosition()` has any actual dependency on `google.maps`. Added an independent geolocation kick-off directly in the early `<head>` script (right next to the existing `googleMapsReady` flag-and-queue placeholder, which already exists for the same "don't wait on script load order" reason) that fires immediately on page parse, in parallel with both Google's script and this page's own larger module script further down. Its result is cached on `window.earlyGeoCoords`/`window.earlyGeoDone` and applied via `window.applyDirLocationCoords` the moment it resolves, if that function is already defined by then (it normally is, well before a user finishes a permission prompt) -- `_applyEarlyGeoCoordsOnce()` guards against double-firing either way. `autoDetectHomeLocation()` was changed to reuse this cached result (or wait on a small callback queue if it's still pending) instead of calling `getCurrentPosition()` a second, fully redundant time once Maps becomes ready.

Net effect: the GPS permission prompt/fix now starts as soon as the page begins parsing rather than after Maps loads, and the cards render as soon as that GPS fix resolves rather than after a second, unrelated geocoding round-trip on top of it.

Verified in a local preview: confirmed `window.applyDirLocationCoords`/`window.applyDirLocationLabel` are both defined functions and `window.earlyGeoDone` correctly flips `true` on load (geolocation is denied/unavailable in this headless preview environment, so `earlyGeoCoords` stayed `null` and the page correctly fell back to "Set your location to see distance" on every card, matching prior behavior for a denied/no-permission case). Confirmed no console errors from the new code (the Turnstile "110200" errors present in this preview's console are a pre-existing localhost-only Cloudflare Turnstile domain-validation limitation, unrelated to this change). `node --check`-equivalent syntax check passes on both edited script blocks (one unrelated "Unexpected token )" false-positive from the check script's own crude import-stripping logic on the ES-module block was confirmed to already exist identically at `HEAD`, before either edit). **Not tested**: real GPS resolution timing on an actual device, since this headless preview environment has no real geolocation to time against -- the two fixes are grounded in the network/call-ordering logic itself (each source of delay traced to its exact line), not a measured before/after on real hardware.

Build `2026-09-15-v23`.

---

## "Churches near you" still slow on mobile after the previous fix -- geolocation was never allowed to reuse a cached fix

Follow-up to the previous entry: "still takes a long time to load on mobile about 3-5 seconds, on desktop about 1 second... it takes a long time for the cards to switch and bar to fill." The previous fix removed the *unnecessary* delay (waiting on reverse-geocoding, waiting on Google Maps to load first) but left one real cause untouched: `getCurrentPosition()` was called with no options at all, which defaults to `maximumAge: 0` -- meaning every single page load or refresh forced the browser to go get a brand new location fix from scratch, even seconds after the same device had already gotten one. Mobile fixes are inherently slower than desktop's (desktop Chrome's is typically a near-instant Wi-Fi/IP-based lookup; mobile more often falls back to slower radio-based positioning, especially indoors) -- explaining the mobile/desktop gap the user measured directly (3-5s vs ~1s) even after the earlier fix, and why it was still happening specifically "when refreshing."

Added `{ maximumAge: 300000, timeout: 10000 }` to the early head-script `getCurrentPosition()` call (the one all the previous session's fixes centered on). `maximumAge: 300000` (5 minutes) lets the browser hand back a fix it's already holding onto instead of re-fetching, so a reload/re-navigation within that window resolves close to instantly instead of repeating the full fix every time -- directly targeting "when refreshing" from the original request. `enableHighAccuracy` was left at its default `false`, already the faster/less-precise option this app wants (city-level "near you" doesn't need GPS-grade precision) -- confirmed no call site anywhere passes `true`. `timeout: 10000` is a new safety net, not a speed fix: previously unset (no timeout, waits indefinitely), so a genuinely slow/stuck fix had no fallback at all; now it fails into the existing "denied/unavailable" path (generic "near you" heading, unfiltered cards) after 10s instead of hanging forever.

Left the two explicit "Use my location" button handlers (Directory and Events pages) unchanged -- those fire on a deliberate user click, where getting a fresh fix instead of a possibly-stale cached one is the more correct behavior (e.g. a user who's traveled since their last visit and wants their *current* city, not 5-minutes-ago's).

Verified in a local preview: geolocation denied/unavailable in this headless environment either way, so `earlyGeoDone`/`earlyGeoCoords` behave identically to before the change (confirms the options object didn't break the call itself); no new console errors. `node --check`-equivalent syntax check passes on the edited block. **Not tested**: actual cached-fix timing on a real mobile device, since a headless preview has no real geolocation provider to measure against -- the fix is grounded in the documented `maximumAge` semantics (MDN: reusing a "cached position [...] no older than the specified time" instead of requesting a new one) rather than a measured before/after here.

Build `2026-09-15-v24`.

---

## "Can it go even faster?" -- instant-paint from a localStorage-cached last-known location while the real fix is still in flight

Direct follow-up: the previous `maximumAge` fix only speeds up a *reload within 5 minutes* -- the browser's own internal geolocation cache doesn't survive a new tab or a browser restart, so the very first load of a session still pays the full fix time (still 3-5s on mobile, just now only on that first load instead of every load). Added a second, independent layer on top: a `localStorage`-backed "last known location," used to paint an instant guess the moment the page's own render functions exist, without waiting on geolocation, Maps, or anything network-related at all -- then silently corrected once the real fix (from the existing maximumAge-cached or fresh `getCurrentPosition()` call) resolves shortly after.

Two new pieces, both in the early head script alongside the existing `earlyGeo*` state:
- On every successful real fix, `localStorage.setItem('fd_last_geo', {lat, lng, ts})` -- a durable record of "the last place this device actually was," independent of the browser's own internal position cache.
- On load, before anything else resolves: read that back, and if present and under 7 days old, stash it as `window.earlyGeoInstantCoords`. Chose 7 days as "recent enough to be a plausible guess, old enough to almost always exist for a repeat visitor" -- deliberately generous, since staleness here only ever costs a brief, self-correcting flash (the real fix always follows and re-renders with the true position), never a wrong *final* result. Wrapped in try/catch -- private browsing or a full storage quota should silently skip the instant guess, not break the page.

The tricky part was *when* to apply it. It can't wait on Maps (defeats the purpose) or even on `autoDetectHomeLocation()` existing -- it needs to fire the instant `applyDirLocationCoords()` renders the moment that function itself is defined, which happens early in the module script, well before Maps or geolocation are involved at all. Added `window._applyInstantGeoIfPending()` as an explicit hook, called once from the module script immediately after `window.applyDirLocationCoords = applyDirLocationCoords;` is assigned -- the earliest possible point it's safe to call. Guarded with its own `earlyGeoInstantApplied` flag, separate from the real fix's `earlyGeoAppliedCoords` flag, since both are legitimately expected to fire independently (instant guess first, real correction after) rather than the second one being blocked by the first having already run.

Verified in a local preview by seeding `localStorage['fd_last_geo']` directly (no real geolocation available in this headless environment either way) and reloading: confirmed via JS inspection that `window.dirUserLat`/`dirUserLng` were set to the seeded coordinates and `earlyGeoInstantApplied` flipped `true` immediately on load, with no console errors beyond the pre-existing, unrelated localhost Turnstile ones. Separately confirmed an 8-day-old seeded entry is correctly rejected (`earlyGeoInstantCoords` stays `null`, `dirUserLat` stays `null`) -- the 7-day cutoff works. **Could not verify** the actual card/heading content updates from this, since this sandboxed preview has no real network egress to Supabase at all (no `search_churches`/`search_events` requests appear regardless of coordinates) -- a pre-existing limitation of this environment, not something this change could newly break; the coordinate-application code path itself (the only part this change touches) is confirmed working directly. `node --check`-equivalent syntax check passes. **Not tested**: real before/after load timing on an actual mobile device across a browser restart, for the same reason as the previous two entries in this chain -- no real geolocation to time here.

Build `2026-09-15-v25`.

---

## Don't flash unfiltered results before location-filtered ones replace them, when a location is actually expected

"can it be so that if location is autofilled or filled, then refresh doesnt not show unfilter cards at all, an results arent shown until the results are ready?" A real, previously-unnoticed consequence of the initial page-load render order, not something the earlier speed fixes touched: `loadRealChurches()` (and the equivalent `loadRealEvents()`) called `renderHomeChurches()`/`renderDirectory()` unconditionally, near the top of the module script -- and critically, this ran *before* `applyDirLocationCoords()` even gets defined a few hundred lines further down in that same script. So on every load, an unfiltered/default-ordered list was guaranteed to render first no matter what, then get silently replaced once real coordinates (instant-cached guess or the actual geolocation fix) came in -- exactly the flash the user was seeing, and something the previous session's fixes never addressed since they were about *speed*, not about *whether an intermediate state should render at all*.

Added `renderOnceLocationKnown(renderFns)`, shared by both `loadRealChurches()` and `loadRealEvents()`. Before rendering anything, it checks whether a location is actually expected to arrive at all: `window.earlyGeoInstantCoords` (the localStorage-cached guess from the previous entry) or a `'granted'` geolocation permission state -- both knowable *before* any geolocation callback fires, since the second one required a new addition: an early `navigator.permissions.query({name:'geolocation'})` call in the head script (never shows a prompt itself, resolves almost immediately, and is kicked off in parallel with everything else there, so it's already settled by the time the module script needs it). If neither signals a location is coming, renders immediately, same as before -- there's nothing worth waiting for. If one does, it holds off; `applyDirLocationCoords()` (called moments later by whichever resolves first, the instant guess or the real fix) renders these itself once real coordinates are known, so results only ever appear once, already correctly filtered. A fallback (queued on the same `earlyGeoCallbacks` array the rest of this chain already uses) still renders unfiltered if geolocation was expected to succeed but ultimately didn't -- covers permission being silently revoked between the query and the actual fix, hardware failures, etc. -- so a "location expected" page can never end up permanently blank.

Verified in a local preview: confirmed `window.earlyGeoPermissionState` resolves to `'denied'` in this sandboxed environment (no real geolocation permission available here), correctly triggering the immediate-render branch -- cards populate right away, unchanged from before this fix, as expected for a "no location coming" case. Directly unit-tested the gating logic's three branches in isolation via injected JS (mirroring the real function): confirmed it defers and queues a callback rather than rendering immediately when a location IS expected (`earlyGeoInstantCoords` set, not yet resolved), and confirmed the deferred render correctly fires once the queued callback resolves with `null` coords (the "expected but ultimately failed" fallback path). `node --check`-equivalent syntax check passes. **Not tested**: the real, intended path end-to-end (permission already granted on an actual device, confirming the unfiltered flash is actually gone and the fallback never over-fires) -- this sandboxed preview has no real geolocation permission to grant, so `earlyGeoPermissionState` can only ever come back `'denied'` here regardless of what's requested.

Build `2026-09-15-v26`.

---

## Two small, unrelated requests landed together: an unfollow "Undo" toast, and cross-links on empty homepage sections

**Undo after unfollowing, on My Churches.** "can there be a brief undo option that appears, in case it was unfollowed by accident?" The unfollow button already deleted the `church_follows` row immediately on click and re-rendered the list -- kept that exactly as-is (matches the click the person actually made, and avoids a "pending delete" state to track if they close the tab or navigate away before an undo window would've expired) and added a small toast afterward instead. `showUnfollowToast()` creates (once, lazily) a `#unfollow-toast` element, fixed to the bottom of the screen, with the church's name (read straight off the row's own `<h4>` in the DOM -- already the exact text just rendered, no extra query needed) and an "Undo" button; auto-dismisses after 6 seconds via a single tracked timer. Undo re-inserts the same `church_follows` row (`upsert`, same shape the follow-heart toggle elsewhere already uses) and refreshes the list -- a genuine re-follow, not a cancelled delete. No existing toast/snackbar component anywhere in this codebase to reuse, so it's new, self-contained CSS using the existing `--ink`/`--paper`/`--gold` theme variables (inverted: dark-on-light in light mode, light-on-dark in dark mode, so it reads correctly in both without its own dark-mode override block).

**"Browse churches"/"Browse events" links on an empty homepage section.** Separately reported with a screenshot: the "Upcoming events near [you]" section could render completely blank between its own heading and the next page section below it, with nothing there at all -- `renderHomeEvents()` only ever touched `#home-event-grid`'s content when the search actually returned rows; an empty result left whatever was already there (nothing, on first load) untouched. Found the exact same gap in `renderHomeChurches()` for the symmetric case. Added `homeEmptyStateHtml()`, shared by both, rendering a short message plus a cross-link to the *other* section (no churches nearby -> link to Events; no events nearby -> link to Directory) instead of leaving the grid empty -- `grid-column:1/-1` spans it across the 3-column `.grid` rather than squeezing it into one narrow cell. Deliberately set `window.homeChurchesLastRenderedRows`/`homeEventsLastRenderedRows` to `null`, not `[]`, in this branch -- `refreshHomeChurchesText()`/`refreshHomeEventsText()` (re-paint the already-fetched rows in the new language on a language switch, added in an earlier fix) guard on `!window.homeXLastRenderedRows` to skip when there's nothing to re-render; `[]` is truthy and would have passed that guard, silently wiping this new empty-state message back out to a blank grid the next time someone switched languages while looking at it.

Verified in a local preview: this sandboxed environment's own denied-geolocation, no-Supabase-network state happens to trigger the real empty-events case on every load, so the new fallback was visible immediately without needing to fake it -- confirmed via page text ("No upcoming events near you yet. Browse churches near you") and via DOM inspection that the link resolves to `href="#directory" data-route="directory"`. Manually created and toggled `.visible` on an `#unfollow-toast` element to confirm its styling (computed `position:fixed`, correct theme-driven background/radius) and, by mobile-viewport screenshot, that it reads cleanly with the message and gold "Undo" both legible at 375px width. `node --check`-equivalent syntax check passes on all edits. **Not tested**: the real end-to-end unfollow/undo flow against live Supabase data (delete, toast appears, click Undo, row reappears) or the real empty-churches-nearby case -- this sandboxed preview has no real Supabase network access or way to have zero churches exist near a real coordinate to trigger that specific branch.

Build `2026-09-15-v27`.

---

## A manually searched location was silently reverting to auto-detected "near me" on refresh

"when after searching for a different city, and then refreshing - it refreshes with autolocation, but if a user types in a new location, then a refresh should stay on the new location and not automatically search nearest." Root cause: nothing about a manual search was ever remembered past the current page's JS state -- every one of the app's manual-location entry points (Directory/Events Places autocomplete, the Enter-key/search-button geocoding fallback, "Use my location" on either page) already funnels through the one shared `setDirLocation(lat, lng, label)` function, but a real browser refresh throws away all of that and re-runs the auto-detect flow from a completely blank slate, with no way to know a search had ever happened.

Added persistence at that exact single choke point: `setDirLocation()` now also writes `{lat, lng, label}` to `sessionStorage['fd_manual_location']`. `sessionStorage`, deliberately not `localStorage` (used elsewhere in this same location chain for the auto-detected last-known-location guess) -- it needs to survive a refresh but must NOT quietly keep overriding auto-detection forever once the tab is actually closed and a genuinely new visit starts. The early head script now reads this back before anything else and, when present, treats it as authoritative over both the localStorage GPS-guess instant-paint AND the real geolocation fix -- skipping the `getCurrentPosition()` call (and the permission prompt that can come with it) entirely rather than letting it race against, and potentially overwrite, a location the user already explicitly chose. `clearDirLocation()` (the location field's own "x" clear button) removes the same key, so clearing a search and refreshing correctly falls back to auto-detection again rather than the just-cleared search reappearing.

This touched three other places already built in earlier fixes this session, each needing a small adjustment to stay correct with a third location source now in the mix (manual, alongside the existing auto-detected-instant-guess and real-GPS-fix paths):
- `_applyInstantGeoIfPending()`'s hook call had to move from right after `applyDirLocationCoords` is defined to after `applyDirLocationLabel` is *also* defined -- applying only coordinates for a remembered manual location would have shown correct, filtered results while leaving the location text box confusingly blank, since the label-applying function didn't exist yet at the earlier call site.
- `renderOnceLocationKnown()` (the "don't flash unfiltered results" gate from an earlier fix this session) needed an explicit manual-location check before its `earlyGeoDone` branch -- a manual location now makes `earlyGeoDone` true immediately (since the real GPS call never even runs), which without this check would have been misread as "geolocation already resolved with nothing coming," triggering exactly the unfiltered-flash bug that gate exists to prevent, specifically for this new case.
- `showRouteFromHash()`'s own unconditional `renderDirectory()` call (for landing directly on `#directory` via a bookmark or refresh) had the identical gap -- it lives in an earlier, separate, non-module `<script>` block that can't see the module script's local `renderOnceLocationKnown()`, so that function is now also exposed as `window.renderOnceLocationKnown` for this call site to reuse.

Verified in a local preview: simulated a manual search (`applyDirLocationCoords`/`applyDirLocationLabel` for Austin, TX + writing the sessionStorage key directly, since `setDirLocation` itself isn't exposed on `window`) and reloaded -- confirmed `window.earlyManualLocation` correctly read back, `earlyGeoInstantCoords` correctly skipped (stayed `null`), `earlyGeoDone` true with no real GPS coords requested, and `window.dirUserLat`/`Lng` automatically set to Austin's coordinates with both the location input field and the homepage heading correctly reading "Austin, TX, USA" / "Churches near Austin, TX, USA" -- all without any real geolocation call ever firing. Then called `window.clearDirLocation()` and confirmed both the live state and the sessionStorage key were cleared, and a further reload correctly came back with no manual location and fell through to normal auto-detection. No console errors beyond the pre-existing, unrelated localhost Turnstile ones. `node --check`-equivalent syntax check passes. **Not tested**: the real end-to-end flow through the actual UI (typing into the location field, picking a Places autocomplete suggestion, refreshing) on a live deploy -- this sandboxed preview has no real Google Places Autocomplete interaction available to drive that path directly, so the persistence and read-back logic was verified at the function/state level instead.

Build `2026-09-15-v28`.

---

## Two more gaps in the manual-location fix: hero search bypassed it entirely, and Directory still flashed unfiltered results

Direct follow-up, with specific reproduction steps: "it worked when checking on the 'churches near me' page, but still flashed the unfiltered results for a second. it didnt work from the hero (...typing austin in the hero and clicking search directed me to the correct austin results..., but refreshing went back to near actual near me.)"

**Hero search never called setDirLocation() at all.** Every manual-location entry point funnels through `setDirLocation()` -- except this one. `setupHeroLocationAutocomplete()`'s `place_changed` handler set `window.dirUserLat`/`window.dirUserLng` directly and called `goToDirectoryFromHero()` -- correct for the *current* page (same globals, same effect), but it never touched the sessionStorage key the previous fix relies on, so nothing about the search was ever remembered. Picking a location from the hero's own autocomplete now calls `setDirLocation(lat, lng, label)` like every other entry point, which persists it the same way.

**Directory still flashed because a second, EARLIER `showRouteFromHash(true)` call existed that the previous fix's gating never reached.** Traced with temporary console logging (confirmed real with `location.reload()` -- an in-tab `navigate()` to the same base URL turned out to be a same-document hash navigation, not a true reload, and silently failed to exercise this at all during earlier verification). There are two separate calls to `showRouteFromHash(true)` on a fresh load of `#directory`: one from inside `loadRealChurches()` (already correctly gated by the previous fix) and one **earlier**, pre-existing, added in an unrelated previous fix ("re-run the current route's setup... on a hard refresh landing directly on a route whose loader lives [in the module script]"). That earlier call runs before `window.renderOnceLocationKnown` -- previously defined near the bottom of a long chain of location-handling functions -- had even been assigned yet, so its own `typeof window.renderOnceLocationKnown === 'function'` guard found nothing and fell through to an immediate, unfiltered `renderDirectory()` call. Confirmed via logging: `renderOnceLocationKnown= undefined` on the earliest (pre-module, harmlessly no-op'd by the separate `window.supabase` guard) call, but the *second* call -- the real culprit -- also showed `undefined` before this fix and `function` after it.

Fixed by moving `renderOnceLocationKnown()`'s definition to the very top of the module script, right after its imports -- it only ever reads `window.earlyGeo*`/`earlyManualLocation` state, all already set by the head script long before the module script starts, so nothing actually required it to live near the other location functions further down; it just always had before. Re-verified with the same logging: the previously-`undefined` call now correctly shows `renderOnceLocationKnown= function` and takes the gated path instead of rendering immediately.

Verified in a local preview using `location.reload()` specifically (not `navigate()` to the same URL, which doesn't reliably force a real reload) with a manual location pre-seeded in `sessionStorage`: confirmed via temporary instrumentation that `renderDirectory()` now fires exactly once on a `#directory` reload, already using the correct manual coordinates, with no earlier unfiltered call preceding it. All debug logging removed afterward. `node --check`-equivalent syntax check passes. **Not tested**: the real hero-autocomplete click-through and a real-device confirmation that the Directory flash is visually gone -- this sandboxed preview has no real Google Places Autocomplete interaction available, so the hero fix was verified by code inspection (it now matches every other entry point's exact pattern) rather than a live click-through.

Build `2026-09-15-v29`.

---

## Church profile page: "Follow church" text button replaced with the same heart used everywhere else

"replace the Follow Church button with the heart and have it in the upper right corner across from denomination." The old `#church-follow-btn` was a plain `<button class="btn-gold">` sitting in the same button row as Message/Give, with its own dedicated click handler and text-swapping logic ("Follow church" / "Following ✓"). Removed it entirely and reused the same follow system the directory card/list hearts already use (`HEART_ICON`, the `[data-follow-church-id]`/`data-following` attribute pattern, and the one shared delegated click handler that already toggles `church_follows` for any element carrying those) -- the shared handler already had a special case built in for exactly this ("If this church is the one currently open on its own profile page, keep that page's own Follow button in sync too"), so no new click handler was needed at all, just a new element for it to find.

New empty `#church-follow-heart-slot` div added right at the top of the banner's `.wrap` (now `position:relative`, scoped to this page only), populated by `populateChurchPage()` with the same button markup `followHeartCard()`/`followHeartRow()` already build (just a new `.follow-heart-profile` class instead), then corrected by `checkChurchFollowStatus()` (adapted to set `data-following` on this element instead of swapping a button's `textContent`) once the real async follow-status check resolves -- same two-step "default state, then corrected" pattern the old button used. `.follow-heart-profile` is `position:absolute;top:0;right:0` within that now-relative `.wrap`, landing it at the same right edge the Message/Give buttons already sit flush against (via the banner's own `justify-content:space-between`), but pinned to the very top instead of bottom-aligned with that row -- level with `#church-eyebrow` (the denomination text) as asked, independent of how tall the rest of the left column (name, claim banner, badges) grows.

Colors deliberately don't need a `html[data-theme="dark"]` variant, unlike the card/row hearts -- `.banner`'s background is `var(--brand)`, and unlike `--ink`/`--paper`/etc., `--brand` is never redefined under `[data-theme="dark"]`, so this banner is always the same dark navy regardless of site theme. Empty-state stroke reuses `#8FA0C4`, the exact color `#church-eyebrow` already uses right next to it; followed-state fill reuses the same `#F0A8C4` pink the card/row hearts use elsewhere.

Removed the now-dead `church.followingCheck` i18n key (EN/ES) along with the button it only ever labeled, and updated two stale comments elsewhere that still referred to "church-follow-btn" by its old id.

Verified in a local preview: clicked through from the homepage to a real church's profile page and confirmed by screenshot the heart renders top-right, level with "CHRISTIAN / GENERAL", both at desktop and mobile (375px) width -- the mobile screenshot in particular confirmed it doesn't crowd even a longer two-word denomination label. Confirmed via DOM inspection that the rendered heart carries the real church's UUID as `data-follow-church-id`, starts `data-following="false"`, and its empty-state stroke computes to `rgb(143, 160, 196)` (`#8FA0C4`) as intended. Clicked it while signed out and confirmed the shared delegated handler correctly opened the existing "Create a free account or sign in to follow churches" modal -- proof the heart is properly wired into the existing follow system, not just visually present. No console errors beyond the pre-existing, unrelated localhost Turnstile ones. `node --check`-equivalent syntax check passes. **Not tested**: the actual follow/unfollow toggle and its visual fill-state change while genuinely signed in, since this sandboxed preview has no real authenticated session to complete that flow with.

Build `2026-09-15-v30`.

---

## Profile page follow heart sat flush against the page edge (even overlapping the scrollbar) instead of lining up with Message/Give

Reported with two screenshots, one highlighting the browser's own scrollbar running right through the heart's column. Root cause: `.follow-heart-profile{position:absolute;top:0;right:0;}` -- `right:0` for an absolutely positioned element resolves against its containing block's *padding edge*, which for `.wrap` (its containing block here, `padding:0 28px`) sits at the outer/border edge, not inset by that padding at all. So `right:0` put the heart flush against the very edge of `.wrap` -- and by extension, on a browser window where `.wrap` doesn't hit its own 1080px max-width cap, flush against the actual edge of the page -- while Message/Give (normal-flow children, which DO respect padding) sat visibly further in, 28px inset from that same edge. Changed to `right:28px`, matching `.wrap`'s own padding value exactly, so the heart now lines up with Message/Give's own right edge instead of overshooting past it.

Verified in a local preview: confirmed by screenshot the heart now sits inset from the page edge, and by direct `getBoundingClientRect()` comparison that its right edge (`981px`) matches the Give button's right edge (`981px`) exactly, pixel for pixel, at the tested window width. Pure CSS change -- no JS touched, `node --check`-equivalent syntax check passes trivially.

Build `2026-09-15-v31`.

---

## Follow-heart performance/correctness pass: three separate real bugs in one report

"when refreshing the church profile page and hero page, or navigating to them, their is a 1 or 2 second delay to when the heart is filled... there is also small delay when filling and un-filling the heart wither on the card, list, or profile page. When navigating to a profile from directory, then following profile, and hitting back to the directory - the church i just followed does not show followed." Three genuinely different root causes, all in the follow-heart system.

**1-2s delay before a followed heart shows filled.** Two stacked causes. First, `loadEventFilterFollowState()` (the one function that populates `window.myFollowedChurchIds`, which every heart's initial state reads from) ran two independent Supabase queries -- `church_follows` and `church_memberships` -- as sequential `await`s, and only re-rendered the heart-bearing grids after BOTH finished, even though the grids only actually care about the first one. Parallelized with `Promise.all`, applying the follow-state half (and re-rendering) the moment ITS OWN query resolves instead of waiting on the unrelated home-membership check too. Second, the church profile page's own `checkChurchFollowStatus()` always ran its own fresh two-step query (`auth.getUser()` then `church_follows.select()`) from scratch, completely redundant with what `loadEventFilterFollowState()` was already fetching into `window.myFollowedChurchIds` moments earlier -- now checks that array first and answers instantly (no network call at all) whenever it's already been populated this session, which is the common case for anyone navigating in from elsewhere in the app; only a genuinely fresh page load (nothing cached yet) still pays a real network round trip.

**Small delay on every click to fill/unfill.** The shared delegated click handler awaited the actual `church_follows` insert/delete *before* ever touching `data-following` -- so the heart visually sat in its old state for the full round trip on every single toggle. Made optimistic: `data-following` (and `window.myFollowedChurchIds`) now flip immediately on click, with the write happening in the background and only reverted if it comes back with an error.

**Followed church not showing followed after Back-navigating to Directory.** Two compounding causes, one a pre-existing gap and one a regression from earlier in this session. The direct fix: the optimistic toggle above now updates *every* element site-wide sharing the same `data-follow-church-id` -- not just the one actually clicked -- since this is a single-page app where Directory's grid, Home's preview, and a church's own profile page all stay alive in the DOM (just hidden) simultaneously; following from the profile page now immediately corrects that same church's card back on Directory's hidden DOM too, no re-render required. But investigating this also surfaced a real regression from the same-session "don't flash unfiltered results" fix: `renderOnceLocationKnown()` reads `window.earlyManualLocation`/`earlyGeoInstantCoords`/`earlyGeoDone` -- all one-time flags, set once during initial load and never cleared -- to decide whether to defer a render. That's correct for the very first call, but `showRouteFromHash()` calls this same function again on *every* later navigation to `#directory` (Back/Forward included), by which point those stale flags were silently making it decide "still deciding" forever and skip rendering entirely -- meaning the Directory grid could never genuinely re-render again for the rest of the session via that path, for any reason, not just this one. Fixed with an explicit `window._locationDecisionMade` flag, set the first time any branch actually finalizes a real outcome (either via this function's own `runAll()`, or via `applyDirLocationCoords()` for the manual/instant-cache path, which renders directly without going through `runAll()`); every call after that renders immediately, no further deferring.

Verified in a local preview: confirmed the optimistic toggle's code path and delegated-selector-based site-wide sync via review (this sandbox has no real authenticated session to click through a genuine follow/unfollow with). Directly confirmed the `renderOnceLocationKnown` regression is fixed: `window._locationDecisionMade` is `true` after initial load, and calling `window.renderOnceLocationKnown()` a second time (simulating a later in-session call, e.g. from Back-navigation) now renders immediately instead of silently doing nothing. No console errors beyond the pre-existing, unrelated localhost Turnstile ones. `node --check`-equivalent syntax check passes. **Not tested**: the actual query-latency improvement and the real click-to-fill responsiveness on a live device with real network conditions and a real signed-in session -- this sandboxed preview has no real Supabase network access to measure timing against, and no real auth to complete a genuine toggle with.

Build `2026-09-15-v32`.

---

## Unclaimed churches: a second, bottom-of-page notice to report incorrect info or claim

Requested with specific wording to use (chosen from a few options offered): "See something incorrect? This is an unclaimed, community-sourced listing. Email us at support@faithdock.com to report an issue, or claim this church to manage it yourself." A second, lower-key nudge at the very bottom of the page, distinct from the existing `#church-unclaimed-banner` at the top (which leads with "Is this your church? Claim your free FaithDock profile." -- a stronger, first-thing-you-see CTA) -- this one's for after someone's actually read the listing and might have spotted something wrong.

New `#church-bottom-unclaimed-notice`, same visibility logic as the top banner (`!isClaimed`, computed in `populateChurchPage()` from `c.ownerId`), placed right before the "Back to directory" link. `data-i18n` only ever sets `textContent` (confirmed in `applyTranslations()`), so a real `mailto:` link and the claim button couldn't just be embedded inside one translated string -- built instead from three separate translated text fragments (lead / mid / end) bracketing a real `<a href="mailto:support@faithdock.com">` and a real `<button>`, the same "static link/icon next to a data-i18n span" pattern already used elsewhere on this same page (the phone/website info rows). The claim button reuses the exact same flow as the other two claim CTAs already on this page (header banner, Events-tab empty-state pivot) -- that flow was already a delegated handler matching a comma-separated list of button ids specifically so a third could be added this easily, and already always reads the church id/name from `#church-unclaimed-banner`'s own data attributes regardless of which button was actually clicked, so no new state-passing was needed, just adding `#church-bottom-claim-btn` to that same selector list.

Verified in a local preview: confirmed by page-text extraction the full sentence reads correctly ("See something incorrect? ... Email us at support@faithdock.com to report an issue, or Claim this church to manage it yourself."), confirmed via computed style that the notice is visible with the expected gold-themed background/border, confirmed the mailto link's `href` is exactly `mailto:support@faithdock.com`, and confirmed clicking the new button opens the same "sign in to claim a church" prompt the other two claim buttons already trigger -- proof it's wired into the real shared flow, not just visually present. Checked mobile width (375px) by screenshot: wraps cleanly, button sits inline without crowding. No console errors beyond the pre-existing, unrelated localhost Turnstile ones. `node --check`-equivalent syntax check passes. **Not tested**: the notice correctly staying hidden on a genuinely claimed church's page, since finding or creating a claimed church wasn't practical in this sandboxed environment -- inferred instead from using the exact same `isClaimed` variable and toggle pattern the pre-existing top banner already uses correctly.

Build `2026-09-15-v33`.

---

## Bottom unclaimed notice: "Claim this church" changed from a button to a bold inline link

Direct follow-up: "make the 'Claim this church' part bold and linked, but remove the tag/button style." Stripped the `.btn-gold` class and its padding, replacing with a plain reset (`background:none;border:none;padding:0;margin:0;font:inherit;`) plus `font-weight:700` and the same `border-bottom:1px solid var(--gold-ink)` underline style the mailto link right next to it already uses -- so it now reads as a bold, underlined link flowing inline with the sentence instead of a standalone button interrupting it. Stayed a `<button type="button">` rather than switching to a plain `<span>`/`<a>` -- same element, same id, so the existing delegated claim-flow handler (matching `#church-bottom-claim-btn` alongside the other two claim CTAs) needed no changes at all, and a real `<button>` keeps this keyboard-accessible for free, which a bare `<span>` would not without extra `tabindex`/`role` work.

Verified in a local preview: confirmed by screenshot it now reads as bold underlined text inline with the sentence, no button box/background. Confirmed via computed style (`fontWeight:700`, transparent background, `1px solid` bottom border, zero padding, `cursor:pointer`) that the button-chrome removal is real, not just visual at a glance. Re-confirmed clicking it still opens the same "sign in to claim a church" modal as before (needed a brief wait in this test for the click handler's own `await supabase.auth.getUser()` to resolve before checking -- an artifact of the test itself, not a behavior change). `node --check`-equivalent syntax check passes.

Build `2026-09-15-v34`.

---

## Church profile header content drifted right -- the follow heart's wrapper was a phantom 3rd flex item

Reported with a screenshot, the eyebrow/name/claim-banner column circled in red, clearly shifted right of where the header nav and the tabs below it both start. Root cause: `#church-follow-heart-slot` (the empty div `populateChurchPage()` fills with the heart button, added when the "Follow church" button was replaced with a heart) is a plain, normal-flow `<div>` -- and `.wrap{display:flex;justify-content:space-between;}` treats it as a genuine THIRD flex item alongside the eyebrow/name column and the Message/Give button group, even though the *button* rendered inside it is `position:absolute` (removed from flow) once populated. `justify-content:space-between` on 3 items pins the first and last to the edges and spreads the middle one evenly between them -- so the eyebrow/name column, now stuck as flex item #2 of 3, got pushed away from the left edge toward the center instead of sitting flush against it, exactly matching the screenshot.

Fixed by moving `position:absolute` from `.follow-heart-profile` (the button) onto `#church-follow-heart-slot` (the wrapper div) instead -- removing the WRAPPER from the flex flow, not just its contents, restores `.wrap` to effectively two flex items again, same as before this element existed. The button itself no longer needs its own positioning, just sits normally within its now-absolutely-positioned parent.

Verified in a local preview: confirmed by screenshot at both desktop and mobile (375px) width that the eyebrow/name/claim-banner column is flush left again, matching the header nav and the About/Events/etc. tabs below it. Confirmed via `getBoundingClientRect()` that `#church-eyebrow`'s left edge is exactly `28px` (matching `.wrap`'s own padding, i.e. genuinely flush against the content area's left edge, not just visually close) and that the heart's right edge still matches the Give button's right edge exactly, unchanged from the previous fix. No console errors beyond the pre-existing, unrelated localhost Turnstile ones. Pure CSS change -- `node --check`-equivalent syntax check passes trivially.

Build `2026-09-15-v35`.

---

## "Claim this church" and the mailto link's underlines sat at different heights -- a button can't reliably become inline

Reported with a zoomed-in screenshot showing the two underlines clearly offset. First attempt: added `display:inline` to the `<button>` (its default is `inline-block`, which aligns by its own box edge rather than the text baseline the neighboring `<a>` uses) -- verified in a local preview that this did NOT actually work: `getComputedStyle()` still reported `inline-block` despite the inline style genuinely saying `display:inline`. This is a real, confirmed Chromium quirk, not a CSS specificity bug -- form controls like `<button>` keep their forced control-box layout behavior regardless of the declared `display` value.

Replaced the `<button>` with a real `<a href="#">` instead, styled identically to the mailto link right next to it (which was always correctly baseline-aligned, being a plain inline element by nature) -- confirmed this actually fixes it, `getComputedStyle()` now reports a genuine `inline`. `href="#"` needed one more change to be safe: this app's whole router depends on `location.hash`, and the shared claim click handler didn't call `preventDefault()` (never needed to, since its other two triggers are plain `<button type="button">` elements with no default action) -- added `ev.preventDefault()` to that handler, a no-op for the other two buttons, but essential for this new link so clicking it can never actually touch `location.hash`. Same `href="#"` + delegated-click + `preventDefault()` pattern already used elsewhere in this file for anchors that trigger JS instead of navigating.

Verified in a local preview: confirmed via `getComputedStyle()` the new element is a real `<a>` computing to `display:inline` (not `inline-block`). Measured actual same-line bounding-box bottoms for both links against their neighboring text spans: the mailto link and the claim link now show the exact same ~1px offset from their neighboring `<span>`s (an expected, consistent artifact of the link's own `border-bottom` width, not a misalignment) -- confirming both links now behave identically, where before the claim button's offset was visibly larger and inconsistent. Confirmed clicking it still opens the same "sign in to claim a church" modal, and that `location.hash` is provably unchanged immediately after the click (checked synchronously, before and after) -- `preventDefault()` is doing its job. No console errors beyond the pre-existing, unrelated localhost Turnstile ones. `node --check`-equivalent syntax check passes.

Build `2026-09-15-v36`.

---

## Dark-mode follow hearts (card + list): outlined-badge redesign

Requested directly: "for dark mode can the hearts be background of card color when empty and yellow border, and when filled remove yellow border and use the same pink." Replaced dark mode's previous solid-grey-silhouette treatment (`fill:#4A4A4A`, no stroke, drop-shadow -- chosen specifically because a photo thumbnail has no single color a stroke-only heart could blend into) with an outlined-badge look instead: empty state now fills `var(--card)` (the same background every card/panel/row already uses) with a `var(--gold)` stroke; followed state drops the gold stroke entirely and fills the same established pink (`#F0A8C4`) the light-mode/followed states already use everywhere else. Applied identically to both `.follow-heart-card` (thumbnail corner) and `.follow-heart-row` (List view) for consistency -- the List row heart in particular now blends seamlessly into `.church-row`'s own background (which is already `var(--card)`) until followed, since a row heart never had the "no single color to blend into" problem a photo thumbnail does.

Kept the same specificity-scoping discipline already established for these rules earlier this session: both `[data-following="true"]` overrides stay explicitly re-scoped under `html[data-theme="dark"]` (not left unscoped), since the plain dark-mode default rule is more specific and would otherwise silently outrank an unscoped override -- this exact trap has already been hit and fixed multiple times for this same component, so it was checked proactively rather than by trial and error again. Kept the card heart's drop-shadow for legibility against a busy/colorful thumbnail; the card-color fill doesn't try to blend into the photo itself (impossible for the same reason as before), it deliberately reads as a chip matching the site's own UI chrome sitting on top of it instead.

Verified in a local preview (already in dark theme by default here): confirmed via `getComputedStyle()` that the card heart's empty state computes to `stroke: rgb(217, 182, 70)` (`#D9B646`, exactly `--gold`) and `fill: rgb(24, 35, 56)` (`#182338`, exactly `--card`), and the followed state to `stroke: none` and `fill: rgb(240, 168, 196)` (`#F0A8C4`) -- confirmed the identical pattern for the List view row heart too, plus by screenshot (multiple rows toggled to followed side-by-side with untouched ones, visually confirming both states at once). Confirmed light mode is untouched -- toggled `data-theme` to `light` and back, computed style still showed the original grey stroke/no-fill outline, since none of these edits touch any non-`[data-theme="dark"]`-scoped rule. No console errors beyond the pre-existing, unrelated localhost Turnstile ones. Pure CSS change -- `node --check`-equivalent syntax check passes trivially.

Build `2026-09-15-v37`.

---

## Church profile Events tab: dropped the heading and gold claim-pivot box for a plain empty state

Requested directly: remove "Upcoming events here" / the gold "This church hasn't added events yet..." claim box, and make the empty state read more like Groups/Ministries' plain "No groups posted yet." Removed the `<h3>` heading and the entire `#church-no-events-unclaimed` box (its own paragraph + `#church-events-claim-btn`) from the Events tab, matching Groups/Ministries tabs exactly -- neither of those ever had a heading at all, just a loading message that gets replaced by the list or a plain "No X posted yet." paragraph. Reworded `church.noUpcomingEventsPosted` from "No upcoming events posted yet." to "No events posted yet." (EN/ES), matching the "No {noun} posted yet." template Groups/Ministries already use.

`loadChurchEvents()` simplified accordingly -- it used to branch on `!!c.ownerId` to decide between the plain no-events paragraph and the gold claim-pivot box; now it always just shows the plain paragraph when there are no events, regardless of claimed status. Not a functional loss -- the bottom-of-page unclaimed notice (added earlier this session) already covers "claim this church" for an unclaimed listing, so this tab-specific pivot had become a redundant second prompt for the exact same action. Removed `#church-events-claim-btn` from the shared claim-flow click handler's selector list (down to two triggers now: the header banner and the bottom notice) and the now-fully-unused `church.upcomingEventsHere`/`church.noEventsUnclaimedPivot` i18n keys (EN/ES).

Verified in a local preview (had to restart the dev server first -- it had been stopped since an earlier turn): confirmed by page-text extraction that the Events tab on an unclaimed church with no events now shows only "No events posted yet." with no heading and no gold box above or around it. No console errors beyond the pre-existing, unrelated localhost Turnstile ones. `node --check`-equivalent syntax check passes. **Not tested**: the populated-events case (a church with real upcoming events) and the claimed-but-empty-calendar case, since this sandboxed preview's one real church under test has neither real events nor an owner -- both paths were verified by code reading instead (the grid/no-events toggle logic is otherwise unchanged, only the removed branch was touched).

Build `2026-09-15-v38`.

---

## My Churches -> Manage -> Back not working on the first press (investigated, best-evidence fix, not fully confirmed)

Reported directly: from the multi-church "My Churches" overview, clicking "Manage" on a specific church lands on that church's dashboard; pressing Back does nothing on the first press, and only on a second press jumps past My Churches straight to the home page, instead of landing on My Churches on the first press as expected.

**Investigated thoroughly but could not get a live reproduction** -- this requires a real signed-in account that owns 2+ churches (the multi-owner Overview grid this bug starts from), and this sandboxed preview has no real Supabase auth session available, so `window.isSignedIn`/`hasChurchAccess`/the multi-owner dashboard code path can only be reasoned about via code reading and partial simulation, not a genuine end-to-end repro. Traced the full routing chain in detail: the click handler (`[data-manage-church-id]`), `setActiveChurchAndReload()` (sets the active church, then `location.reload()`), the dashboard's own default-tab logic in `loadDashboardHeader()` (`goDash('churches', true)` for a bare `#dashboard` landing, already correctly using `replaceState` -- this exact class of duplicate-entry bug was already found and fixed once before for a related case, per an existing comment on that code), and the single `popstate` listener (`showRouteFromHash(true)` -> `go(..., true)` -> also `replaceState`). Directly verified via injected test code that each of these individual operations (`location.hash=` assignment, `history.pushState`, `history.replaceState`, `location.reload()`) behaves exactly as expected in isolation -- none of them alone visibly duplicates a history entry.

**The one concrete, fixable issue found**: the "Manage" click handler used a plain `location.hash = '#dashboard';` assignment immediately followed by `setActiveChurchAndReload()`'s `location.reload()` -- unlike every other navigation in this app, which goes through `go()`/`safeHistoryUpdate()` (a direct `history.pushState`/`replaceState` call). A raw hash assignment followed immediately by a synchronous reload is a known cross-browser gray area: the hash assignment's own `hashchange` event fires asynchronously, so the reload can fire before the browser has fully settled that change into the joint session history, in a way that varies by engine. Changed it to call `history.pushState(null, '', '#dashboard')` directly -- the same History API operation `go()` itself uses, just inlined here since going through the full `go()` function would also fire a bunch of page-display side effects (page hide/show, nav highlighting) that are about to be blown away by the reload anyway.

Verified in a local preview (in a fresh tab, to get a clean history stack): confirmed `history.pushState(null, '', '#dashboard')` adds exactly one entry and sets `location.hash` correctly, matching the same behavior the previous raw assignment had when tested in isolation. **This change is a genuine improvement (removes a real inconsistency with how every other navigation in this app manages history) and is the most concrete, well-supported fix available from static analysis, but it was not possible to confirm it actually resolves the exact reported Back-button sequence without a real signed-in multi-church session** -- please verify after this deploys, and if the issue persists, the next step would be reproducing it with real DevTools access to inspect `history.length`/`history.state` at each step live.

Build `2026-09-15-v39`.

---

## Big one: My Churches refresh bug, Give/Message removed from unclaimed churches, owner toggles, and a new staff "receives messages" ability

Four requests in one message: (1) a user reported following a church from Directory, then going to My Churches, not seeing it there until a manual refresh; (2) remove the Message/Give buttons from every unclaimed church; (3) make both togglable per-church from Settings; (4) let the owner choose who receives contact-form messages -- themselves and/or specific staff, multiple recipients, using the existing staff-invite/ability system and respecting plan staff limits.

**Bug 1 fixed**: `loadMyChurches()` was only ever triggered by an auth-state-change event (sign-in/session-restore) or by an action taken from inside the My Churches page itself (unfollow, undo) -- unlike `my-events`/`my-groups`/`profile`, there was no case for `route === 'my-churches'` in the main nav-link click handler, so a follow made mid-session (already signed in, no new auth event coming) never triggered a refresh on the next visit. Added the missing case, matching the existing pattern exactly.

**Give/Message removal + new toggles**: New migration `032_church_give_message_toggles.sql` adds `churches.giving_enabled`/`messaging_enabled` (both default `true`) and `churches.owner_receives_messages` (default `true`, separate from the master messaging switch -- an owner can hand messaging off entirely to staff without disabling it church-wide). `populateChurchPage()` now hides `#church-message-btn`/`#church-top-give-btn` whenever `!isClaimed` (the actual ask) or the matching column is explicitly `false` (the new owner override) -- `!== false`, not a truthy check, so a row from before this migration ran (or missing the field for any reason) reads as "on," matching each column's DB default. Settings gained two new toggles: one inside `#settings-funds-section` (positioned there deliberately, by the funds list it affects, not the separate bank-connect section above it) for Give, and a new `#settings-messaging-section` with the master Message switch plus "send me a copy" -- each checkbox saves its own column immediately on change, no separate Save button, reverting itself if the write errors.

**New staff ability, not a reused one**: `church_staff.receives_contact_messages` (mirrored on `church_staff_invites`, surfaced through `get_church_staff_detail()`, carried through by `accept_staff_invite()`, settable via `update_staff_abilities()` -- the exact same grantable-ability plumbing migration 029 already built for the other five abilities, extended rather than reinvented) is deliberately separate from the pre-existing `can_manage_messages`, which gates the *outbound* Messages/announcements dashboard feature. Conflating the two would have meant every staffer already trusted to send announcements automatically starting to receive every visitor contact-form submission too. Added as a sixth checkbox everywhere the other five already appear (both invite-modal markups -- the static one and the JS-built multi-church one -- and the permissions-edit modal), and as a new ability tag (`Receives Messages`) wherever the others already render as tags (the Staff page's per-row list, the Profile page's own staff-row summary). "Limited by staff invite limits" -- already true for free: this ability is just one more field on the SAME `church_staff` row every other ability already lives on, so it's automatically subject to the existing per-plan staff-count cap in `inviteStaffToOneChurch()`; no separate limit needed.

**Delivery**: `smooth-action.ts`'s `contact_church` handler (Edge Function, manually deployed -- **not yet pasted into the dashboard, needs to be**) now builds its recipient list from the owner (if `owner_receives_messages !== false`) plus every staff member with `receives_contact_messages = true`, resolving each to a real email via the same `auth.admin.getUserById()` call the owner's address always used, deduped, and sent as multiple `to` addresses in one Resend call instead of a single hardcoded owner address. Added a server-side `messaging_enabled` re-check too -- the client hides the button, but this endpoint didn't previously verify that itself.

**A real deployment-safety issue found and fixed before shipping**: first pass added `giving_enabled, messaging_enabled` directly to `PUBLIC_CHURCH_COLUMNS`, the shared column list `findOrFetchChurchByName()` (and nothing else, but that one function backs every single church profile page load) uses in its `.select()`. Testing this directly against the real database (this sandboxed preview *does* have real network access to Supabase, confirmed by directly running the query and reading back the actual error) showed exactly why that's dangerous: a column that doesn't exist yet doesn't fail that one field softly, it fails the *entire query* (PostgREST `42703`, "column does not exist") -- which would have broken every church's profile page church-wide for however long passes between this code deploying and the migration actually being run by hand. Fixed by reverting `PUBLIC_CHURCH_COLUMNS` and fetching just those two columns as a separate, independent query right after the main one, that soft-fails: if the columns aren't there yet, `mapped.givingEnabled`/`messagingEnabled` simply stay `undefined`, which the `!== false` checks already treat as "on" -- so the site keeps working normally, just without the new per-church override, until the migration runs.

**⚠️ Migration 032 and the updated Edge Function still need to be applied by hand** -- same manual workflow as always (SQL Editor for the migration, paste `smooth-action.ts`'s new `contact_church` section into the Edge Functions dashboard and redeploy). Until the Edge Function is updated, `contact_church` will keep working exactly as before (single owner recipient, no messaging_enabled check) -- it isn't broken by the client-side changes shipping first, just not yet honoring the new toggles/recipients.

Verified in a local preview: confirmed the my-churches route fix (`node --check`-equivalent syntax check). Confirmed, directly against the real database, that `PUBLIC_CHURCH_COLUMNS` unmodified still fetches church profile pages correctly (church name, unclaimed banner all populated correctly) even though the new columns don't exist there yet -- and confirmed the SEPARATE toggle-column fetch 400s exactly as expected (visible in the console) without breaking anything else, proving the soft-failure design actually works, not just in theory. Confirmed `#church-message-btn`/`#church-top-give-btn` both compute to `display:none` on that same still-unclaimed church. Confirmed all six new Settings/invite/permissions-modal elements exist in the DOM. **Not tested**: the actual claimed-church path (both buttons showing, the per-church toggles actually saving, a real message send routing to multiple recipients) -- this sandbox has no real authenticated owner session, and the new DB columns/RPCs don't exist on the live database yet regardless.

Build `2026-09-15-v40`.

---

## Migration 032 verification: not actually live yet, despite running it

Asked to verify migration 032 and the redeployed Edge Function after the user ran/redeployed them. Tested directly against the real database from this environment (confirmed real network access to Supabase earlier this session): `select giving_enabled from churches` and `select receives_contact_messages from church_staff` both still come back `42703 column does not exist`. This is a genuine Postgres-level error (not a PostgREST schema-cache staleness symptom, and not a permissions error, which would be a different code) -- the columns are not actually there. **Migration 032 has not taken effect on the database this app connects to**, despite the "ran it" confirmation -- worth re-checking the SQL Editor for an error partway through the script (a later statement failing wouldn't necessarily undo already-applied earlier `alter table` statements, but it's also possible the paste was incomplete, or it ran against a different project than the one this app's anon key points at). Re-run it and confirm no red error text appeared for any statement, then this is easy to re-verify the same way. Left the deployed `smooth-action.ts` state unconfirmed too, since the multi-recipient `contact_church` code depends on these same columns existing to do anything useful either way.

## Unfollowed a church from My Churches, came back later and it was still followed

Reported directly. Root cause: `#unfollow-toast` (the "Unfollowed X. Undo" toast from the earlier unfollow-undo feature) is a `position:fixed` element appended straight to `<body>`, outside any `.page` container -- so unlike everything else on screen, it does NOT go away when the route changes. Its own 6-second auto-dismiss timer is the ONLY thing that was ever hiding it, meaning it stayed fully visible and fully clickable (`pointer-events:auto` while `.visible`) across a navigation that happened to occur within that window. Someone who unfollows a church and then quickly clicks anything else near the bottom of whatever page comes next -- the church's own name to view its profile, a "Back to directory" link, anything else sitting at that same fixed screen position -- could land squarely on "Undo" without ever noticing, silently re-following the church. That fully explains "unfollowed it, came back later, it was followed again" with no conscious undo click in between.

Fixed at the one central choke point every single route change already goes through: `go(route, skipPush)` (the shared page-switching function used by nav clicks, `popstate`/Back-Forward, and everything else) now dismisses the toast (removes `.visible`, same as its own timer does) as the very first thing it does, unconditionally. This doesn't require exposing anything from the module script that owns the toast -- `go()` already lives in the earlier, separate classic `<script>` block, but `document.getElementById('unfollow-toast')` works identically regardless of which script created the element, and the guard (`if (openUnfollowToast)`) already handles it not existing yet (nobody's unfollowed anything this session). Doesn't touch the underlying 6-second timer itself (a module-scoped variable `go()` can't reach) -- letting that fire later and redundantly remove an already-removed class is harmless.

Verified in a local preview: seeded a fake visible toast, called `window.go('directory')` directly, and confirmed its `visible` class was removed as a direct result of that one call -- not a timeout, not a coincidence. No console errors beyond the pre-existing, unrelated localhost Turnstile ones. `node --check`-equivalent syntax check passes. **Not tested**: the exact real-world sequence (unfollow, then a genuine accidental click elsewhere) end to end, since this sandboxed preview has no real authenticated session to unfollow a real church with -- the fix targets the mechanism directly confirmed above (the toast no longer outlives its own page), which is sufficient to close the reported gap regardless of exactly which second click the user's report involved.

Build `2026-09-15-v41`.

---

## Migration 032 actually failed to apply: CREATE OR REPLACE can't change a table-function's return columns

Running migration 032 for real (finally, after the earlier verification found the columns missing) surfaced the actual cause: `42P13: cannot change return type of existing function... Use DROP FUNCTION get_church_staff_detail(uuid) first`. The migration's own comment on that function had confidently claimed "Postgres allows redefining a function's OUT columns via a plain CREATE OR REPLACE as long as the column names/types are only being appended" -- that claim was wrong, not verified against real Postgres behavior when written. `CREATE OR REPLACE FUNCTION` on a `returns table(...)` function requires the OUT-parameter row type to match *exactly*; appending even one column is a different row type, full stop, no exception for pure appends. This is a distinct hazard from the parameter-list-overload issue migrations 023/031/032-elsewhere already knew to guard with drop-then-create -- that one's about the function's *input* signature; this one's about its *output* shape, and Postgres is strict about both but for different reasons.

This also explains why the earlier verification found NONE of migration 032's changes live, not just this function: the Supabase SQL Editor runs a pasted multi-statement script as one transaction, so this error partway through rolled back the churches/church_staff `alter table` statements that ran successfully just above it too.

Fixed by adding `drop function if exists get_church_staff_detail(uuid);` immediately before its `create or replace`, matching the pattern already used for `update_staff_abilities` (parameter-hazard) just below it in the same file. Corrected the file's own comment to state the real rule instead of the wrong one. Re-sent to the user to re-run.

No build bump -- this is a migration-file-only fix, `index.html` untouched this pass.

---

## IMPORTANT, project-wide: `churches` uses COLUMN-level SELECT grants, not a table-level one -- every new column needs its own `grant select`

Discovered re-verifying migration 032 after the DROP FUNCTION fix above finally let it run clean: the `alter table` statements succeeded (confirmed -- the earlier "column does not exist" error was gone), but reading the new columns as anon now failed with a *different* error: `42501 permission denied for table churches`, hint `GRANT SELECT ON public.churches TO anon`. Isolated it directly against the live database: `select id, name` works fine as anon; `select giving_enabled` (or any of the other two new columns, tested individually) fails every time with that same error. Older columns added by *past* migrations (`is_hidden`, `denomination_tags`) work fine as anon too -- so this isn't "new columns generally need something," it's specific to this one table.

Checked those two past migrations directly rather than guessing further, and found the actual answer: **both `018_church_is_hidden.sql` and `023_denomination_tags.sql` explicitly `grant select (their_new_column) on churches to anon, authenticated;` right after their own `alter table add column`** -- this project's `churches` table has column-level SELECT grants configured for anon/authenticated (not the usual blanket table-level `grant select on churches to anon`), meaning a normal table-level grant does NOT automatically cover a new column the way it would on a table using ordinary grants. Migration 032's first version missed this entirely -- neither the AI session that wrote it nor the review before shipping caught that this table specifically needs it, since most tables in this project (confirmed: `church_staff`/`church_staff_invites` both worked immediately with no extra grant needed) don't.

**Fixed by adding `grant select (col) on churches to anon, authenticated;`** for `giving_enabled`/`messaging_enabled` (meant to be publicly readable -- they gate a public church page's buttons for any visitor) and `grant select (owner_receives_messages) on churches to authenticated;` only (deliberately not anon -- never meant to be publicly readable, same reasoning `PUBLIC_CHURCH_COLUMNS` in `index.html` already excludes it for). No matching UPDATE grant added -- `denomination_tags` (client-updatable via the register-church form) has no UPDATE grant in its own migration either, meaning `churches` already has a working blanket UPDATE grant to `authenticated`, with the existing owner-only RLS policy doing the actual row-level restriction; only SELECT is column-gated here.

**Rule for next time, so this isn't rediscovered the hard way again**: any future migration that runs `alter table churches add column ...` MUST also add `grant select (that_column) on churches to anon, authenticated;` (or just `authenticated` for anything not meant to be publicly readable) in the same migration, or the new column will silently 42501 for every anon/authenticated read the moment it ships, exactly like this one did. This is specific to `churches` -- no other table in this project has shown the same requirement so far.

Re-sent the corrected migration file to the user to re-run (idempotent -- safe to run again in full, `alter table add column if not exists` and `grant` are both no-ops/harmless on already-applied state).

No build bump -- migration-file-only fix again, `index.html` untouched.

---

## My Churches' own "Unfollow" button never synced with Directory's heart for the same church

Reported directly: follow a church from Directory, go to My Churches, unfollow it there, go back to Directory -- still shows followed. Root cause: My Churches has TWO independent unfollow-related code paths that both write to `church_follows`, but only one of them ever kept `window.myFollowedChurchIds` and every page's `[data-follow-church-id]` heart in sync -- the shared heart-toggle handler (search `applyFollowState`, fixed earlier this session for the exact same class of bug in the other direction: following from a church's own page not showing up on Directory). My Churches' own dedicated "Unfollow" button (a plain text button, not a heart, used only on that one page's list) was a completely separate handler that deleted the row and refreshed My Churches' own list, full stop -- it never touched `window.myFollowedChurchIds` or any OTHER page's DOM at all. So Directory's already-rendered (hidden, not destroyed -- SPA) card for that same church kept showing `data-following="true"` indefinitely, since nothing ever told it otherwise, until something else happened to force a fresh Directory render.

Fixed by hoisting `applyFollowState` (previously a closure defined fresh inside the heart-toggle handler on every click) out into a shared, top-level function taking `churchId` as a parameter, and calling it from both of My Churches' own follow-state-changing actions: the "Unfollow" button (`false`) and the undo toast's "Undo" button (`true`, since re-following via Undo had the exact same gap -- confirmed by reading that handler too, not just the one actually reported). Now every follow-state change in the app, regardless of which of the (now three) entry points triggered it, updates the same shared `window.myFollowedChurchIds` array and every matching heart site-wide.

Verified in a local preview: confirmed the refactor introduces no syntax errors and the page loads cleanly with no new console errors beyond the pre-existing, unrelated localhost Turnstile ones. Did not re-verify the underlying `document.querySelectorAll` site-wide sync mechanism itself from scratch -- that exact mechanism was already directly tested and confirmed working earlier this session when the heart-toggle handler first got this same treatment; this change reuses it verbatim via a parameter instead of a closure, with two new call sites following the identical established pattern. **Not tested**: the exact real-world reported sequence end to end (follow from Directory, unfollow from My Churches, confirm Directory reflects it without a refresh), since this sandboxed preview has no real authenticated session to follow/unfollow a real church with.

Build `2026-09-15-v42`.

---

## Unchecking Give/Message in Settings didn't hide the button on the public profile page

Reported directly, right after migration 032 finally went fully live. Root cause: `findOrFetchChurchByName()` -- the public church profile page's own data source -- caches a fetched church object in the in-memory `churches` array for `CHURCH_CACHE_TTL_MS` (45 seconds) before it'll re-fetch on a repeat visit. If the owner had already viewed their own church's public page earlier in the same session (a natural thing to do right before going to check Settings), that cached copy's `givingEnabled`/`messagingEnabled` stayed exactly as they were *before* the toggle, for up to 45 more seconds after the DB write had already genuinely succeeded -- the Settings save itself was never the problem.

Fixed by having `bindGiveMessageToggleSave()`'s save handler patch the SAME cached object directly, the moment the write succeeds, instead of leaving it to the TTL to eventually catch up. `churches` (the array `findOrFetchChurchByName()` reads and writes) lives in the earlier, non-module `<script>` block as a plain top-level `var` -- which attaches it to `window`, making it reachable as a bare identifier from the later module script too (confirmed directly: `'churches' in window` is `true`), the same cross-script-sharing this whole file already relies on pervasively. Looks the cached entry up by `id` (not `name`, since that's all this handler already has via `getMyChurch()`) and writes straight to whichever camelCase field (`givingEnabled`/`messagingEnabled`) that column maps to -- `owner_receives_messages` has no matching cache field since it doesn't feed this page's button gating at all, so it's deliberately left out of the sync.

Verified in a local preview: confirmed `window.churches` is genuinely reachable and populated from the module script's own scope. Directly simulated the exact sequence -- seeded a fake cached church entry with `givingEnabled: true`, ran the identical patch logic the real save handler now runs, confirmed the cached object's `givingEnabled` flipped to `false` in place while `messagingEnabled` stayed untouched, matching exactly the intended one-column-at-a-time update. No console errors beyond the pre-existing, unrelated localhost Turnstile ones. `node --check`-equivalent syntax check passes. **Not tested**: the real end-to-end sequence (toggle off in Settings as a real owner, immediately reload the actual public page, confirm the button is gone) -- this sandboxed preview has no real authenticated owner session to drive that with; the fix was verified at the exact mechanism level (the cache object itself) that the bug report pointed to.

Build `2026-09-15-v43`.

---

## Give/Message toggles still showed the old buttons after the v43 cache fix -- because the save was never reaching the database

Reported directly, right after v43 shipped: still unchecked, still showing. The v43 fix (above) patched a real bug, but it was the wrong layer -- it fixed the *display cache* on the assumption the database write was already succeeding. Confirmed that assumption was false by querying the live church row directly as anon right after the report: `giving_enabled` and `messaging_enabled` were both still `true` in the database, despite the Settings checkboxes showing unchecked. The write itself was never landing.

Root cause: `bindGiveMessageToggleSave()`'s save handler called `.update(update).eq('id', myChurch.id)` with no `.select()` after it. Supabase/PostgREST returns `{ error: null }` for an `.update()` call that RLS or a missing grant silently matches **zero rows** on -- that's not an error condition from PostgREST's point of view, it's just "nothing to report," and the old code had no way to tell that apart from a real save. The most likely actual cause: `churches` uses column-level grants on this table (confirmed earlier this session for SELECT, migrating 018/023's established pattern) and the original migration 032 comment assumed a "blanket UPDATE grant to authenticated" already covered these new columns, citing `023_denomination_tags.sql` as precedent -- but rechecking that file shows `denomination_tags` is never actually written via a plain client `.update()` anywhere in `index.html`, so that precedent never actually proved anything. The assumption was never tested, just carried forward.

Fixed two ways, deliberately overlapping rather than picking one:
1. **Migration 032**, appended `grant update (giving_enabled/messaging_enabled/owner_receives_messages) on churches to authenticated;` -- the same explicit, per-column grant pattern already used for SELECT on this table.
2. **`bindGiveMessageToggleSave()`**, added `.select('id')` to the update call and now treats an empty/missing result the same as an `error` -- reverts the checkbox and shows "Could not save this setting" instead of silently claiming success. This closes the hole regardless of *why* a future write might match zero rows (grant, RLS, or anything else), not just this one specific cause.

This also directly answers the two questions that came with the report: no Save button is needed -- the immediate-save-on-change pattern was always fine, the underlying write was the actual problem, not the lack of a confirm step; and the "works without refreshing, across navigation" requirement is what the added `.select()` check + v43's cache patch now genuinely deliver together, once the write itself lands.

Verified live: queried `giving_enabled`/`messaging_enabled` directly against the production database (anon, matching what the client's read path already does) and confirmed both are still `true` right now, proving the write has never succeeded for this test church -- this is what led to the diagnosis, not a guess. **Not yet re-verified**: the fix itself, since it requires the user to run the new grant statements in the Supabase SQL Editor and then re-test as the actual signed-in owner (no real authenticated session available in this sandbox to drive that end to end).

Build `2026-09-16-v44`.

---

## The v44 fix actually worked -- the report was checking a different church than the one Settings was editing

Reported again after v44 shipped: "still doesn't work." Traced it all the way through with real evidence this time, network trace included: the owner (Robert Budnick) opened DevTools Network, toggled a checkbox, and shared the resulting PATCH request -- `200 OK`, `Content-Range: 0-0/*`, a 47-byte body (a single returned row). That's a genuine success, not a silent failure. The id in that request was `acd1af32-...`. Querying that exact id directly confirmed `giving_enabled: false, messaging_enabled: false` -- the write had landed. A completely fresh navigation to that church's public page (not a reload of an already-open tab) confirmed both buttons render `display: none`. The v44 fix was correct and complete.

The actual mismatch: the owner has (at least) two similarly-named test churches -- "Test 2" (id `3ebef06e-...`) and "Test 2 church" (id `acd1af32-...`). Settings was editing "Test 2 church" (confirmed from the Settings screenshot's own "Delete church" copy: "permanently deletes Test 2 church..."), but the public profile page being checked for the fix was "Test 2" -- a different, untouched church whose toggles were never changed and were still sitting at their `true` defaults. Not a code bug at all; a same-owner, near-duplicate-name mixup, surfaced by directly diffing the church id in the network request against the church id on the page being checked, rather than trusting that "looks like the same page" meant it was.

Separately, a real and legitimate gap the report also raised: there was no Save button, and no confirmation of any kind that a toggle change had actually gone through -- correct that this was a gap, but the fix isn't a Save button (each checkbox already saves immediately on change, which is the right pattern here, matching the rest of Settings). Added an inline "✓ Saved" (or a red error) message next to each checkbox instead, driven straight off `bindGiveMessageToggleSave()`'s already-existing success/error paths -- it was already always known whether the write worked, the UI just never said so. Gave each of the three toggles its own status span (`settings-giving-enabled-status`, `settings-messaging-enabled-status`, `settings-owner-receives-messages-status`) rather than reusing the old shared `#settings-messaging-status` div (removed, now dead) -- that div only physically sat inside the Messaging section, so the Giving toggle's own feedback had nowhere sensible to render. Each status span tracks its own pending-hide `setTimeout` on itself (`statusEl._hideTimer`), not a single shared/global timer, so toggling more than one checkbox in quick succession can't cancel or hide the wrong one's message.

Verified: syntax-checked all four `<script>` blocks (0 errors), confirmed the removed `#settings-messaging-status` div had no other reference left anywhere in the file. **Not tested**: the actual visual "✓ Saved" / error flash in a live browser, since reaching this page requires a real signed-in owner session this sandbox doesn't have.

Build `2026-09-16-v45`.

---

## Renaming a church didn't update "Manage my churches" until a refresh

Reported directly: renamed "Test 2 church" to "Test 3" from the church profile edit form, then went to the "Manage my churches" overview -- still showed the old name until a hard refresh. Same underlying class of bug as the Give/Message toggle cache staleness earlier this session (a successful write not telling every OTHER place that cached the same data), just a different write path and a different reader.

Root cause: the edit form's save handler (the `rcEditingChurchId` branch) already correctly writes and re-reads the updated row, but never told anything else about it. The "Manage my churches" grid (`#dash-churches-grid`) reads from `window._dashOwnedChurches`, which is populated exactly once by `loadDashboardHeader()` -- nothing re-runs that after a profile edit saved from a completely different part of the dashboard, so the grid kept rendering whatever name it had at the last page load, indefinitely, until something (a full reload) re-ran `loadDashboardHeader()` from scratch.

Fixed by patching every cache this save path can reach, at the point of a successful write, same pattern as the toggle fix:
1. `findOrFetchChurchByName()`'s own `churches` array cache -- the stale entry is **dropped outright**, not patched, since it's keyed by name and a rename makes that key permanently wrong rather than just old; the next visit (by either name) does a correct fresh fetch on its own.
2. `getMyChurch()`'s short-lived cache (`window._myChurchCache`) -- cleared outright rather than patched, since it carries several derived/joined fields (`ownedChurches`, `staffedChurches`, `role`) this form has no way to correctly recompute from the update response alone.
3. `window._dashOwnedChurches` -- the entry for this church is patched in place (name/denomination/logo_url), and `loadDashboardChurchesPanel()` is called immediately afterward to re-render the grid on the spot if it's the panel currently showing.
4. The dashboard header's own church-name text -- updated directly if this is the currently active church.

This fixes the one reported path (the church profile edit form), not every write in the app that could leave some other cache stale -- that's the same category of bug as the toggle fix and the earlier My-Churches follow/unfollow sync fix, and each has needed its own targeted patch as it's been found, not a single systemic fix. Flagged directly to the user as scoped to this one save path, not a blanket "site-wide" guarantee.

Verified: syntax-checked all four `<script>` blocks (0 errors). **Not tested** end to end (rename a real church, confirm the overview grid updates immediately with no reload) -- no real authenticated owner session available in this sandbox to drive that with.

Build `2026-09-16-v46`.

---

## Display name save didn't update the nav bar until a refresh

Reported directly, pinpointing the exact cause: `profile-name-confirm-btn`'s success handler updated `#profile-name` (the profile page's own heading) but never touched `#nav-user-name` (the account dropdown label in the nav bar) -- a separate element the handler simply didn't know about, so the nav bar kept showing the old name until a full reload re-ran whatever populates it at page load.

Fixed by setting `#nav-user-name`'s text alongside `#profile-name` in the same success branch, right after the `update_profile_name` RPC succeeds.

Build `2026-09-16-v47`.

---

## Dashboard header and church switcher dropdown went out of sync after a rename

Reported directly, with a specific ask to check two named hypotheses: (1) the switcher built from data fetched once and never refreshed on back-navigation while the header re-fetches fresh, or (2) popstate/back restoring a cached prior render instead of re-fetching. Traced both.

Actual root cause was closer to (1) than (2), but more specific: `loadDashboardHeader()` is the single function that builds the big header name, the multi-church switcher `<select>`'s `<option>` list, `window._dashOwnedChurches` (the "Manage my churches" grid), and several permission-gated sections -- but before this fix, it **only ever ran twice in a page's whole lifetime**: once at page load (`loadDashboardHeader();`, a bare top-level call), and again on auth-state changes (sign-in, session restore). Neither `go()` nor `goDash()` -- the two functions that actually handle navigating into and around `#dashboard` -- ever called it. Every other comparable route (`my-churches`, `my-events`, `my-groups`, `profile`) already had its own "refresh on every visit" hook in both `showRouteFromHash()` (covers popstate/back, since that's literally what popstate calls) and the generic `[data-route]` click handler (covers in-app forward clicks) -- `dashboard` was simply missing from both places.

This explains the exact asymmetry reported: the header showed the new name only because the church-rename save handler (from the earlier "Manage my churches" cache-staleness fix, same session) directly patched `#dash-church-name`'s text as an immediate, same-page confirmation. The switcher was never patched by that same handler -- its `<option>` list has no standalone patchable piece of state; it only exists as markup built inline inside `loadDashboardHeader()`. So the header looked "live" purely by coincidence of a manual patch, while the switcher reflected whatever it was built with at the last of those two rare full-refresh events, indefinitely, regardless of how many times you navigated away and back.

Fixed three places:
1. `showRouteFromHash()` -- added a `loadDashboardHeader()` call whenever the resolved route is `dashboard`, right after the existing `goDash()` call. Covers popstate (browser Back) and any other path that flows through this router.
2. The generic `[data-route]` click handler -- added the same call for `route === 'dashboard'`, matching the exact pattern already used for `my-churches`/`profile`/`directory` immediately above it. Covers in-app forward clicks (`nav-dashboard-link`, "← Back to my church" links) that never route through `showRouteFromHash()` at all.
3. The church-rename save handler -- replaced the earlier direct-patch-in-place logic (header text + `_dashOwnedChurches` entry, from the previous fix) with a single `await loadDashboardHeader()` call now that `window._myChurchCache` is already cleared right before it. One real fetch instead of two parallel, hand-maintained patches that could drift apart from the real function's own logic over time -- the switcher bug this time was exactly that kind of drift (a patch that covered the header and the grid but missed the third thing built by the same function).

Verified: syntax-checked all four `<script>` blocks (0 errors), confirmed no duplicate/overlapping fetch -- the two new call sites (popstate-driven router vs. plain click handler) are mutually exclusive triggers, never both firing for the same navigation. **Not tested** end to end (rename a real church, confirm the switcher's own text updates via both a click and an actual browser Back) -- no real authenticated owner session available in this sandbox to drive that with.

Build `2026-09-16-v48`.

---

## Follow-heart buttons flashed a rectangular focus outline on click

Reported directly, with the root cause already identified: `.follow-heart-card`, `.follow-heart-row`, and `.follow-heart-profile` all set `border:none`, but `outline` is a separate CSS property entirely unaffected by that -- so a click still triggered the browser's default `:focus` outline, flashing a rectangle around the heart.

Fixed with `:focus:not(:focus-visible){outline:none;}` on all three classes, not a blanket `:focus{outline:none;}` -- `:focus-visible` is the browser's own heuristic for "this focus almost certainly came from a keyboard, not a pointer," so scoping it this way only removes the outline for the mouse/touch-click case being fixed and leaves keyboard Tab navigation with a fully visible indicator, same accessibility bar as everywhere else in a project that already ships a dedicated Accessibility page.

Verified directly in a local preview: a real mouse click on `.follow-heart-card` left `document.activeElement.matches(':focus-visible')` `false` and computed `outlineStyle: 'none'`; a real keyboard Tab onto the same class of button left `:focus-visible` `true` and computed `outlineStyle: 'auto'` (a real, visible outline). No console errors beyond the pre-existing, unrelated localhost Turnstile ones.

Build `2026-09-16-v49`.

---

## Refreshing on Directory page 5+ silently reverted to page 1

Reported directly: land on page 5 of Directory results, hit refresh, back on page 1. The URL already correctly encoded the page (`#directory/5`), and `directoryPageFromHash()` correctly reads it -- so the bug wasn't in the URL/hash layer at all.

Root cause: `renderOnceLocationKnown()` (the gate that decides when it's safe to render Directory results, since real churches need a location to compute distance) has two totally different render paths depending on whether geolocation/a remembered location is expected. When NONE is expected, it runs its own `renderFns` callback array directly -- which correctly calls `renderDirectory(directoryPageFromHash())`. But when a location IS expected (geolocation already granted from a prior visit, or a manual location remembered in `sessionStorage` from before this exact refresh -- both very common on an ordinary refresh, not edge cases), that callback array is deliberately never run at all; its own comments say so explicitly ("`applyDirLocationCoords()` has already rendered... nothing to do in that case"). `applyDirLocationCoords()` is what renders instead once real coordinates land, and it called `renderDirectory()` with no page argument -- which, by `renderDirectory`'s own documented convention ("no arg -> a filter changed -> snap to page 1"), silently overwrote whatever page the hash still correctly pointed at.

Fixed by giving `applyDirLocationCoords(lat, lng, resetToPageOne)` a third parameter, defaulting to page-preserving (`directoryPageFromHash()`) rather than always resetting. Its three page-load-time callers (early instant-geo guess, a manual location restored from `sessionStorage`, the real GPS fix finishing) all pass nothing and get the new, correct page-preserving default. `setDirLocation()` -- the one place someone is actually choosing a brand-new location to search (autocomplete, "Use my location", Enter in the location box) -- now passes `true` explicitly, since that genuinely is a new search and page 1 is the right landing spot (whatever page they were on for the OLD location's results may not even exist for the new one). `clearDirLocation()` was left untouched -- clearing the location filter is exactly the "a filter changed" case `renderDirectory()`'s own no-arg convention already exists for, same as every denomination/distance/keyword filter change elsewhere in this file.

Verified live in a local preview: seeded `sessionStorage.fd_manual_location` (the exact mechanism a real remembered location uses) and set `location.hash = '#directory/3'`, then did a genuine `location.reload()` -- confirmed `window.directoryPage === 3` and the pager's `.dir-pager-current` element read "3" after the reload, not reset to 1. No console errors beyond the pre-existing, unrelated localhost Turnstile ones.

Build `2026-09-16-v50`.

---

## Event data (title, capacity, "Almost full"/"Full") could go stale indefinitely, worse than churches ever did

Third staleness audit this session, same class of bug as the nav-bar name and the dashboard church-switcher: same underlying data (an event) displayed or reachable from more than one place, only some of those places actually refreshing. Checked every location event details appear: the Events listing (`renderEvents`), the homepage's "Upcoming events" preview (`renderHomeEvents`), a church profile's own Events tab (`loadChurchEvents`), the event detail page (`populateEventPage`, reached via `findOrFetchEventById`), and the Dashboard's own event management table (`loadDashboardEvents`). Checked two distinct scenarios, as asked:

**Scenario 1 (editing an event) -- confirmed bug, fixed.** The edit-save handler (event-edit submit, `ceEditingEventId` branch) only ever called `loadDashboardEvents()` afterward -- refreshing the Dashboard's own table, nothing else. `findOrFetchEventById()` -- what the public event detail page actually reads from when reached via a card click, a direct `#event/<id>` link, or the Dashboard's own "View public page" row action -- had **no staleness fallback at all** (unlike `findOrFetchChurchByName`'s 45-second TTL): once an event was cached in the shared `events` array from ANY source, it stayed frozen for the rest of the browser session, full stop, edit or no edit.

**Scenario 2 (capacity changing from someone else's registration) -- confirmed bug, fixed, and worse than expected.** The Events listing, home preview, and church-profile Events tab all correctly re-fetch fresh data (including current `confirmed_participant_count`) every time they render -- so far so good. But their own merge-into-shared-cache step was `if (!existing) events.push(e)` -- meaning if that event was ALREADY cached from an earlier fetch, the fresh row's up-to-date capacity/fillBadge was silently discarded, every time, forever. Confirmed the concrete failure path: click an event card straight off the (correctly fresh) listing grid -- the card's own text is current, but the click routes through the global `[data-route="event"]` handler, which looks the event up in the stale shared array FIRST, not the fresh row the card was just built from. So the listing could show "Almost full" while the detail page one click away still showed "Registration open," from a cached read that might be hours old. This is explicitly the "navigating to a fresh view should pick up the change" case, not the out-of-scope "live push to an already-open tab" case (per how this was scoped) -- and it was failing even on a genuine fresh navigation, not just an already-open tab.

Fixed three places, following the same "one source of truth, everything re-renders from it" pattern as the last two fixes, not a hand-patch per element:
1. `findOrFetchEventById()` gained the same TTL pattern as `findOrFetchChurchByName` -- `EVENT_CACHE_TTL_MS = 45000` / `eventCacheFetchedAt{}`, refreshing the cached object in place (not pushing a duplicate) when a re-fetch happens, exempting non-real (sample/demo) events from the TTL entirely, same as churches.
2. A new shared `mergeEventIntoCache(e)` helper, called from `renderEvents`/`renderHomeEvents`/`loadChurchEvents`'s row-merge step instead of their old "push only if not present" logic -- now every fresh listing fetch actually updates the shared cache (and resets its TTL clock) instead of only feeding its own grid.
3. The event edit-save handler now does `delete eventCacheFetchedAt[ceEditingEventId];` right after a successful save -- forcing the very next lookup to genuinely re-fetch, rather than hand-mapping the save response into the cache's shape (which would have silently missed the joined church name/plan and the live registration count, neither of which the update response carries).

Verified live in a local preview: confirmed `window.eventCacheFetchedAt` is reachable cross-script (same classic-script-`var`-attaches-to-`window` mechanism already confirmed for `churches`/`events` this session) and that `window.findOrFetchEventById` is exposed; seeded a fake cached "real" event with a fresh timestamp and confirmed a lookup returned the identical object instantly (0.10ms, no network call); then backdated its timestamp past the 45s TTL and confirmed the same lookup took 335ms (a genuine network round-trip) and correctly fell back to the stale object once the fake id predictably matched nothing server-side. `mergeEventIntoCache` itself isn't on `window` (by design -- only ever called internally within the same classic script, same as `renderEvents`/`renderHomeEvents`), so it couldn't be unit-tested directly the same way; verified by code review instead. No console errors beyond the pre-existing Turnstile ones and one expected 400 from the fake test id's own lookup attempt.

Build `2026-09-16-v51`.

---

## Four follow-ups on Events, checked and reported individually

**1. The event-edit staleness fix (b8a2e76) didn't actually work -- confirmed by the user with the exact repro, re-investigated and actually fixed this time.** The previous fix only did `delete eventCacheFetchedAt[ceEditingEventId]` after a save -- clearing the TTL timestamp `findOrFetchEventById()` checks. That function was never the whole story: `showRouteFromHash()` (a direct `#event/<id>` visit, or Back/Forward) and the global `[data-route="event"]` click handler ("View public page" from the Dashboard's own event row uses exactly this) BOTH check the raw `events` array directly first -- `events.filter(...)[0]` -- and only call `findOrFetchEventById()` as a fallback if that comes up empty. Clearing the TTL timestamp did nothing for those two lookups: the stale object was still sitting right in the array, so they found and returned it immediately, never reaching the function whose cache was actually patched. Fixed by splicing the entry out of the `events` array entirely on a successful save (not just clearing its timestamp) -- with nothing left under that id, all three lookup paths correctly come up empty and fall through to a genuine fresh fetch. This is the mistake the previous verification made too: tested the TTL mechanism's own timing in isolation, not the actual reported end-to-end sequence (edit -> immediately open the public page, no refresh) -- a reminder that a mechanism can be individually correct and still not be what a real user path actually calls.

**2. Max Participants was gated behind Require Registration -- fixed.** The "Max participants" input lived inside `#ce-registration-options`, a container `display:none` unless "Require registration" was checked -- bundling a plain headcount cap in with genuinely registration-dependent fields (ticket price, fees, discount codes). Moved it to its own always-visible block right after the Require Registration checkbox, outside that gated container. No submit-handler change needed: `maxParticipantsRaw` was already read unconditionally (unlike max volunteers/guests, which ARE deliberately gated by their own separate toggles) -- only the field's *visibility* was ever tied to registration, not the save logic. Left volunteer/guest signups untouched -- those still gated behind Require Registration, since accepting a volunteer or guest signup genuinely depends on the registration system being on, unlike a plain capacity cap.

**3. Placeholder/demo content ("Fall Community Picnic", "Grace Fellowship Church") flashing on the event detail page -- found and removed every instance on that page.** Audited `#page-event`'s entire static HTML, not just the two spotted strings. Confirmed real leaks: `#event-title` ("Fall Community Picnic"), `#event-host-link` (text + a stale `data-church-name="Grace Fellowship Church"` attribute), `#event-description` and `#event-description-2` (full paragraphs of sample copy), `#event-when` and `#event-location` (fake date/address text after their icons). All emptied in the static HTML -- `populateEventPage()` already unconditionally overwrites every one of these on load, confirmed by reading it, so nothing here was ever the actual data source, just a leftover default sitting in front of it. Also gave `#event-description-2` a default `display:none` (it previously had none, so a blank line could still flash before JS decided whether to show it). Checked and deliberately left alone: `#event-badge`'s "Registration open" default and `#event-audience-row`'s "Open to anyone" default (generic i18n fallbacks, not fake sample-specific data -- a materially different thing from a hardcoded fake title/address); `#share-modal-title`'s own "Fall Community Picnic" (a separate modal, `display:none` until explicitly opened by a click that always sets its title in the same action -- doesn't flash on page load/refresh, which is what was actually reported); several "Grace Fellowship Church" strings elsewhere in the file confirmed to be on unrelated, already-unroutable marketing/conference page sections, not `#page-event` itself.

**4. "Almost Full"/"Full" -- checked, and it does exist, wired correctly, on the two surfaces that matter (not a missing feature).** `eventCard()` and `populateEventPage()` both already render a `fillBadge` ("Almost full" at ≥90% capacity, "Full" at 100%, computed by `mapSearchEventRow()`) -- confirmed by reading both functions directly, not assumed. It's deliberately gated to only show for an event that (a) actually has a `max_participants` cap set at all, and (b) is at least 90% filled -- an uncapped event, or one well under capacity, correctly shows nothing, by design, not a bug. The Dashboard's own event table genuinely does NOT have this badge -- it shows a plain "X/Y Registrations" count instead (`formatRegCell()`), matching exactly what the user already observed and correctly described as raw data rather than a status badge; that's an intentional, different presentation for an admin's own operational view, not an oversight. Most likely explanation for not seeing it while testing: the specific event(s) tested either had no capacity cap set, or weren't yet at ≥90% fill -- both of which correctly suppress the badge by design. Reported plainly as already-working rather than folded into the staleness fix, per the request.

Build `2026-09-16-v52`.

---

## Unregistering from a full event never updated the "Full" tag, and Back-then-Forward still showed registered

Reported directly, with an embedded UX request too: "the Full tag should be by the register button so it's more visible to people attempting to register." Two separate, real bugs plus that placement request, all fixed.

**The "Full" tag never updating.** Registering/unregistering only ever called `setEventRegisteredUI()` -- the button's own text/state -- nothing recomputed `#event-fill-badge` after the participant count actually changed. `checkEventCapacity()` looks like it should cover this but doesn't: it's only ever called for events with `allowVolunteers` on, so a plain participant-only event (probably the more common case) never ran it at all, on load or after (un)registering. Added a new, general-purpose `refreshEventCapacityBadge(eventId)` -- re-fetches the real confirmed count via the same `get_event_registration_counts` RPC, recomputes the fill badge with the exact same thresholds `mapSearchEventRow()` uses (>=90% almost full, 100% full), updates `#event-fill-badge`, and patches the matching entry in the shared `events` cache array directly (not via `mergeEventIntoCache()` -- that function pushes a whole new entry when nothing matches, which would be correct for a full fresh-fetched object but would corrupt the cache here, where only two fields are actually known). Wired into all three success paths: the free-delete unregister, the paid-cancel unregister, and a brand-new registration.

**Back then Forward still showing registered.** A different, more fundamental mechanism than a stale cache: modern browsers can restore a page from the back/forward cache (bfcache) as a frozen DOM snapshot with **no JavaScript re-running at all** -- including `checkEventRegistrationStatus()`, which otherwise queries the database fresh every time (not cached, so it isn't the earlier events-staleness class of bug) and would have caught this correctly on any real navigation. A bfcache restore isn't a real navigation as far as this app's own router is concerned, so nothing re-ran. Fixed with the standard approach for this: a `pageshow` listener checking `event.persisted` (true only for a bfcache restore), which re-runs `showRouteFromHash(true)` -- the same full route-resolution a genuine navigation would trigger -- so a bfcache-restored page re-populates itself from current data instead of showing whatever was frozen into it.

**Placement.** Moved `#event-fill-badge` from beside the top badge (next to the title) down to directly above the Register button -- removed the `marginLeft` `populateEventPage()` used to set for its old position, no longer relevant now that it sits alone on its own line rather than next to another tag.

Verified: syntax-checked all four `<script>` blocks (0 errors); confirmed in a local preview that `#event-fill-badge` now sits directly between the "no registration needed" note and the Register button in the DOM, and that `window.refreshEventCapacityBadge` is correctly exposed. No console errors beyond the pre-existing, unrelated Turnstile ones. **Not tested**: the actual live register/unregister/bfcache sequence end to end -- no real authenticated session available in this sandbox to drive that with.

Build `2026-09-16-v53`.

---

## v53's Full-badge fix still left the badge stuck, and re-registered the user via their own confused re-click

Reported again after v53, with a real network trace attached. The trace confirmed the DELETE succeeded (`204`) and `get_event_registration_counts` genuinely fired and returned `200` right after it -- so v53's re-fetch WAS running. But the fetch was never `await`ed, and `btn.disabled = false` ran immediately after starting it, not after it finished -- so the badge's actual update landed whenever that round trip happened to resolve, with nothing holding the UI in a "still working on it" state until then. The trace also showed the exact same registration pre-check sequence (`event_questions`, `events?select=allow_guests`, `get_event_registration_counts`) repeating three times in a row -- almost certainly the user clicking Register again themselves, out of reasonable confusion (the badge still said "Full," so nothing looked like it had worked) -- and since unregistering had genuinely freed a spot by then, that click correctly succeeded and re-registered them. Not a code loop; a real, reasonable action by someone who couldn't tell their first click had worked.

Root-caused the actual gap and fixed it two ways rather than one:
1. **Awaited** the capacity refresh at all three call sites (both unregister paths, and a successful registration) -- the button no longer re-enables and the status message no longer shows until the badge is actually settled, removing the timing window where the UI could look unchanged while a real update was still in flight.
2. **Added an optimistic update**, via a new `optimisticDelta` parameter (`-1` on unregister, `+1` on a participant registration, `0` for a volunteer one since volunteers don't count toward `max_participants`). This applies the known local math -- current cached count plus/minus this device's own just-completed action -- to the badge **synchronously, with zero network round trip**, using `applyFillBadgeFromCount()` (extracted so the optimistic and real-fetch paths can't render the badge two different ways). The real RPC re-fetch still runs right after, to reconcile against whatever the server actually has (covers someone else registering in the same instant, or a cache entry with no known count yet) -- but the FIRST, instant paint no longer depends on that round trip's timing at all, which is what actually fixes "stayed Full" regardless of whatever caused the visible delay.

Verified live in a local preview: seeded a fake cached event at 10/10 ("Full"), called `refreshEventCapacityBadge('id', -1)`, and confirmed the badge read "Almost full" (9/10) **synchronously**, before the (deliberately fake-id, guaranteed-to-fail) reconciliation fetch had any chance to resolve -- and confirmed the failed reconciliation's `console.error` fired without reverting that already-correct optimistic result, proving the error path is non-destructive. No console errors beyond that expected one and the pre-existing Turnstile noise. **Not tested**: the real end-to-end sequence (unregister a full event as a real signed-in user, confirm the badge and re-registration both behave correctly) -- no authenticated session available in this sandbox to drive that with; this is exactly the gap that let the previous fix's own verification miss the real bug, flagged here explicitly rather than repeated.

Build `2026-09-16-v54`.

---

## The Full-badge/registration bug's actual root cause: a server-side RPC disagreeing with itself

After v54 still failed the exact repro, went back to direct database evidence instead of another client-side theory. Compared two ways of counting the same event's registrations, at the same moment: a raw filtered query (`event_registrations` where `status='confirmed'` and `role='participant'`) returned **0**; the `get_event_registration_counts` RPC -- what every fix this session (v53, v54) has been calling to refresh the badge -- returned **1**. Same event, same instant, two different answers.

This means every client-side fix made across v53/v54 (awaiting the refresh, the optimistic update, the shared `applyFillBadgeFromCount()` helper) was correctly reacting to what that RPC reported -- the badge logic itself was verified working via direct simulation against the real event id and real cached data, and it faithfully rendered "Full" because the RPC it trusted said the event was still full. The actual bug is server-side, in a function whose source was never in this repo (predates migration tracking, same gap as a couple of other functions found earlier this session). Not fixable from here without seeing it -- flagged directly rather than continuing to guess at more client-side causes, which is what cost real time on this one already.

Confirmed live in a second browser session, signed out, on the real event page: it showed "✓ Registered — click to unregister" and "FULL" for an anonymous visitor who couldn't possibly be registered for anything, until a refresh -- consistent with `checkEventRegistrationStatus()` never running for a signed-out user (it bails immediately with `if (!userData.user) return;`) combined with sign-out never resetting any already-rendered event button's state (see the next entry). Not the RPC bug specifically, but adjacent evidence that pointed toward checking auth-state handling next.

**Needed from the user**: the actual SQL body of `get_event_registration_counts` (Supabase dashboard → Database → Functions → find it → view/edit), pasted directly, so this can be diagnosed and fixed with an actual migration instead of guessed at again.

---

## Sign-out left every event button showing "Registered" for a now-anonymous visitor

Found while investigating the report above. Signing out (either entry point -- the Profile page's own button, or the nav dropdown's) only ever called `supabase.auth.signOut()` then `go('home')` -- navigating away, but never resetting any *other* already-rendered page's own state. An event card or the event detail page's button, if it had shown "✓ Registered — click to unregister" before sign-out, kept showing exactly that afterward -- reachable again via Back, or simply because sign-out happened from a nav menu overlay sitting on top of the same page the whole time -- for a visitor who, now signed out, cannot possibly be registered for anything.

Fixed in the one place that already reacts to every sign-out regardless of which button triggered it: the `onAuthStateChange` listener's existing `if (event === 'SIGNED_OUT')` block (already resetting the signup/login forms for an unrelated, previously-fixed bug). Added a reset of every `.register-real-btn` currently in the DOM -- both event cards and the detail page's own button -- via the same `setEventRegisteredUI()` function every other register/unregister path already uses, so there's no second, hand-rolled way of clearing this state to drift from the real one.

Build `2026-09-16-v55` (continued below with two more fixes from the same session).

---

## Church/event tab row overflowed on mobile, stretching the entire page's layout viewport

Reported with a screenshot: the church profile page's hero section showed a hard-edged cutoff partway across the screen, with the page's own background bleeding through the remaining strip, and the tab row (About/Events/Groups/Ministries/Location) looked cut off. Traced directly by measuring the real DOM in a mobile-width preview: `window.innerWidth` reported **461** despite the viewport being set to 375 -- the actual overflowing element was a single `.tab` div (Location, the 5th tab) sitting at `left:378, right:442`, past the true screen edge.

Root cause: `.tabs{display:flex}` never wrapped or scrolled, and plain flex children don't shrink or clip by default -- with 5 tabs on a church page, the row didn't fit in a phone-width screen and just overflowed. That overflow didn't stay invisibly off-screen: with nothing constraining it, the browser widened the whole page's *layout viewport* to accommodate it, which is what actually broke everything else -- the hero section, sized correctly against the real screen width, ended up sitting inside a page stretched wider than the screen, and the "cut off" look was that extra width's own background showing through.

Fixed with `overflow-x:auto` (plus `-webkit-overflow-scrolling:touch`) on `.tabs`, `flex-shrink:0` and `white-space:nowrap` on `.tab` -- horizontal scroll for the tab row (the same pattern a native app's own tab bar uses) rather than shrinking tab text to fit or wrapping to a second line, either of which reads worse for a nav-style row. Verified in a local mobile-width (375px) preview: `window.innerWidth` correctly reads 375 (was 461), `document.body.scrollWidth` matches it exactly (was 442, i.e. overflowing), and `.tabs` computes `overflow-x: auto`.

---

## Heart buttons still flashed a box on mobile tap, after the desktop :focus-visible fix

Reported directly, specifically on the church profile page's own heart (`.follow-heart-profile`), after the earlier `:focus:not(:focus-visible){outline:none;}` fix (verified working on desktop with a real mouse click) apparently didn't fully hold. Root cause: a *different* browser mechanism entirely -- `outline` and `:focus-visible` govern the CSS focus ring; mobile WebKit/Blink browsers separately paint a native tap-highlight box on any tapped element, controlled by `-webkit-tap-highlight-color`, unaffected by outline or focus-visible in any way. This exact codebase had already hit and fixed this once before, for `.church-card`/`.event-card` -- their own comment even calls out "tapping the follow-heart button nested inside this `<a>` triggers it on the ENTIRE CARD" -- but that fix only addressed the highlight bleeding onto the CARD; the heart BUTTON itself is its own independently-tappable element with its own separate native highlight, never addressed until now.

Fixed by adding `-webkit-tap-highlight-color:transparent;` directly to all three heart classes (`.follow-heart-card`, `.follow-heart-row`, `.follow-heart-profile`), matching the exact fix already established in this same file for the card/event-card case. **Not tested** on a real mobile device/browser -- no such device available in this sandbox; this is the standard, well-established fix for this exact symptom, but flagged as unverified live, unlike the tabs/viewport fix above which was measured directly.

Build `2026-09-16-v55`.

---

## The actual root cause, at last: unregister's DELETE/UPDATE had no way to detect a silent zero-row write

Reported again after v55, with the exact same symptom repeated across many attempts: unregister, Full tag stays, refresh shows still-registered, no way to unregister at all. The RPC-discrepancy theory from the previous entry was a real, confirmed observation, but not the actual root cause -- this one is.

Both unregister paths -- the free `.delete()` and the paid-registration `.update({status:'cancelled'})` -- called their mutation with no `.select()` afterward. This is the **exact same silent-failure hole found and fixed for the Give/Message toggles earlier this session**, missed here despite already having learned the lesson once: Supabase's `.update()`/`.delete()` report `{ error: null }` even when RLS (or a missing grant) matches **zero rows** -- there is no way to tell that apart from a real success without checking what, if anything, came back. Every fix made across v53/v54/v55 (the badge timing, the optimistic update, the RPC investigation) was reacting to symptoms of this: the code genuinely believed the unregister had succeeded every time, because nothing ever told it otherwise, and called `setEventRegisteredUI(btn, false, null)` unconditionally right after. The database row, if RLS or a grant is actually blocking the delete, was very likely never touched at all, on any of the many attempts -- which is exactly why a refresh always "re-registered" the user: they were never actually unregistered in the first place, just shown a UI that confidently said otherwise.

Fixed by adding `.select('id')` to both mutations and checking the returned array's length, same pattern as the toggle fix: an empty result is now treated exactly like an error -- the button reverts, and a real, visible message shows ("Couldn't unregister you — please try again...") instead of silently reporting success. This doesn't yet prove *why* the row isn't being affected (RLS policy, a missing grant, something else) -- `event_registrations`' policies aren't tracked in this repo's migrations (same gap as `churches`), so that part still needs verifying live. But it stops the app from lying about what happened, which is what turned one real bug into what looked like several different ones across this whole back-and-forth.

**Next step if this still fails**: the new error message will now actually appear instead of silence. If it does, that's confirmation this is a genuine server-side permission gap (RLS or a grant on `event_registrations`), the same category of issue the toggle bug turned out to be -- and the fix from here is the same kind of targeted SQL snippet, once the actual policy/grant state is checked directly in the Supabase dashboard.

Build `2026-09-16-v56`.

---

## Confirmed: unregistering was blocked by a missing RLS DELETE policy on event_registrations

v56's `.select()` row-count check did its job on the very first test -- the new "Couldn't unregister you" message appeared instead of the old silent fake-success. That single observation was enough to pin the cause exactly, by elimination rather than by another guess:

1. `checkEventRegistrationStatus()` selects from `event_registrations` with `event_id = X and user_id = <me>` and **finds** the row -- that is the only reason the button ever reads "Registered". So SELECT can see it.
2. The unregister deletes with the **identical** where clause and affects **zero** rows.
3. Postgres returned **no error**. A missing table-level DELETE grant raises `42501` instead; the client fell through to its own generic fallback string, which only happens when `error` is null.

Same row, same filters, visible to SELECT, silently not deletable, no error raised -- RLS is the only mechanism in Postgres that behaves that way (it filters rows out of a statement's scope instead of failing loudly). So the table has RLS on with working SELECT/INSERT policies and no matching DELETE policy. By the same reasoning the paid-cancel path (`update status = 'cancelled'`) had no UPDATE policy either.

Fixed in `033_event_registrations_self_service_rls.sql`: adds a DELETE policy and an UPDATE policy, both scoped to `user_id = auth.uid()` (the UPDATE one with `with check` as well as `using`, so a registration can't be reassigned to someone else's user id on the way through), plus explicit `grant delete, update ... to authenticated` so nothing depends on the grant inference being right. This table's original policies aren't in this repo (predates migration tracking, same gap as `churches`), but permissive policies OR together in Postgres, so these can only add the intended access, never narrow what's already there -- same additive reasoning migration 029 established for `church_staff`.

**Worth noting plainly**: this almost certainly never worked -- not a regression, a feature that was wired up client-side but never had the database permission to actually do anything. Every client-side fix earlier in this thread (badge timing, the optimistic update, the bfcache handler, the RPC count investigation) was chasing symptoms of a write that silently did nothing. The thing that finally cracked it was adding the row-count check that made the failure *visible*, which should have been the first move rather than the fifth -- this exact silent-write hole had already been found and fixed on another feature (the Give/Message toggles) earlier in the same session.

Build `2026-09-16-v56` (client-side); migration 033 is the actual fix and has to be run by hand.

**Verified after 033 was run**: the RPC's `participant_count` for the test event went from `1` to `0` -- the delete actually landed for the first time -- and the Full badge correctly renders hidden. Confirmed on production, not just locally.

**Correction to the previous entry**: the "RPC disagrees with a raw filtered count" finding in it was NOT a bug, and that entry's conclusion was wrong. `get_event_registration_counts` is SECURITY DEFINER precisely so it can report real totals; a raw `event_registrations` count run as anon returns 0 because RLS correctly hides other people's registration rows. The two "disagreeing" numbers were RLS working exactly as designed, compared against each other incorrectly. Nothing is wrong with that RPC and its source does not need to be dug up.

---

## Two search_events overloads existed at once, silently breaking the homepage events preview and every church's Events tab

Found while verifying 033, not reported -- both had been failing silently, probably for a long time.

`renderHomeEvents()` (homepage "Upcoming events near you") and `loadChurchEvents()` (a church profile's Events tab) were returning nothing at all and rendering their empty states ("No upcoming events near you yet" / "No events posted yet") no matter how many real, public, upcoming events existed.

Cause: two `search_events` functions live in the database simultaneously. Migration 022 added `p_keyword` using a plain `CREATE OR REPLACE`, reasoning in its own comment that *"appending, not inserting, keeps this a backward-compatible CREATE OR REPLACE for any other caller still on the old signature."* That is wrong in one specific way: `CREATE OR REPLACE` only replaces a function with the **same parameter list**. Adding a parameter -- even with a default, even appended last -- creates a **separate function**. Migration 019's 11-arg version stayed live next to 022's 12-arg one.

PostgREST picks an overload from the set of named arguments sent, so this broke callers *selectively*, which is exactly why nobody caught it:

| Call site | Args sent | Result |
|---|---|---|
| `renderEvents()` (main Events page) | all 12, incl. `p_keyword` | matches only the 12-arg version — **works** |
| `renderHomeEvents()` | 5 | both versions satisfy it — **PGRST203, broken** |
| `loadChurchEvents()` | 3 | same ambiguity — **PGRST203, broken** |

Because the main Events page was fine, Events always "looked fine." Verified live against production by replicating each call site's exact argument set. Also checked `search_churches` the same way -- **not** affected, since migrations 023/031 correctly used drop-then-create for its signature changes. This is the identical hazard those migrations already documented; 022 is the one place it was missed.

Fixed in `034_drop_stale_search_events_overload.sql` (drops the old 11-arg version, leaving one unambiguous candidate).

**Second, equally important half**: both broken call sites destructured only `{ data }` and threw `error` away entirely, so a hard RPC failure rendered as a completely plausible empty state. That is the same silent-failure class as the unregister bug immediately above, and it is why this hid indefinitely. Both now read the error and log it. An empty result and a failed call are not the same thing and must not look identical -- this is the third distinct bug in this session traceable to a swallowed error, after the Give/Message toggle grants and the unregister RLS gap.

Build `2026-09-16-v57`; migration 034 must be run by hand.

---

## Two follow-ups once unregistering finally worked: stale cards on Back, and the button flashing on refresh

Both reported right after 033/034 went in, and both are ordinary UI-state bugs that were simply invisible while the underlying write was broken.

**1. Register/unregister, press Back, the listing card still showed the old state until a refresh.** `setEventRegisteredUI()` only ever updates the single button handed to it, but the same event is routinely on screen in more than one place: this is an SPA, so the listing page a detail page was reached from is *hidden, not destroyed*, and its card -- with its own `.register-real-btn` for the same event id -- sits in the DOM the whole time. Fixed with `applyEventRegisteredState(eventId, isRegistered, role)`, which updates **every** button for that event id, called from all three success paths (register, free unregister, paid cancel). This is deliberately the same shape as `applyFollowState()`, which fixed the identical bug for follow hearts earlier in this session -- same problem, same solution, so there's one way to do this rather than two.

Also fixed a real second-order bug in `refreshAllCardRegistrationStates()` found while looking at this: it had no `else` branch, so it could turn a button **into** the registered state but never back out of one. A card still reading "Registered" for a registration that no longer existed stayed that way every time it ran. Its query returns the user's full authoritative list of confirmed registrations, so an absent event id unambiguously means "not registered" -- the else branch now says so.

**2. Refreshing an event page you're registered for flashed "Register" a couple of times before settling.** `populateEventPage()` unconditionally reset the button to the unregistered state (`data-registered='false'`, dropped `btn-registered`, overwrote the label with "Register", re-showed the role radios). It runs several times per page load -- the classic script's own first `showRouteFromHash`, again once the module script is ready, again when auth resolves -- and the async `checkEventRegistrationStatus()` put the state back a moment later each time, so the eye caught every round trip.

The reset is still correct when populating a **different** event (that event's state is meaningless for a new one and must not leak across), so it's now keyed on the button's own `data-event-id`: skipped only when re-populating the *same* event, where what's on screen is already known-good and the pending status check will confirm or correct it regardless.

Verified in a local preview by driving the real functions directly: marking the button registered then re-populating the **same** event preserved "✓ Registered — click to unregister", while populating a **different** event correctly reset to "Register" (so the guard fixes the flash without letting state leak between events); and `applyEventRegisteredState()` flipped both a listing card's button and the detail page's button for the same event id, in both directions.

Build `2026-09-16-v58`. No migration needed.

---

## Volunteer registration showed on every event, plus live capacity, the "2/10" count, and the event-page sputter

Five things reported together. Checked the data first this time rather than assuming, which immediately reframed the biggest one.

**1. "Every event has the volunteer registration."** Queried live: `allow_volunteers` is `false` on every event in the database, so this was purely a rendering bug. `setEventRegisteredUI()`'s not-registered branch did `choiceEl.style.display = 'block'` unconditionally -- never checking whether the event accepts volunteers -- and `checkEventRegistrationStatus()` calls exactly that for every visitor who isn't registered, i.e. almost everyone, on every event. `populateEventPage()` now stamps the real answer onto the element as `data-role-choice-available`, and `setEventRegisteredUI()` respects it. A card's `.card-role-choice` needs no attribute: `eventCard()` only emits that markup when the event allows volunteers, so its presence already means yes.

**2. The "Are volunteers needed?" checkbox.** It already existed ("Also accept volunteer signups") and already gated the max-volunteers question -- but it lived inside `#ce-registration-options`, so it was invisible unless "Require registration" was ticked, which is why it read as missing. Moved out to sit beside Max participants (which came out of that same gate earlier), relabelled to the plainer question, with a hint stating the one real dependency that remains: volunteers sign up the same way participants do, so volunteer signups still only appear publicly when registration is required.

**3. The Full tag needing a refresh.** `populateEventPage()` renders whatever `fillBadge` the cached event object happens to carry, which can be a whole cache TTL out of date and is stale the moment anyone else registers. Both event-route entry points now also call `refreshEventCapacityBadge(id, 0)` -- reconcile-only, nothing optimistic -- so arriving at the page is as accurate as refreshing it was.

**4. "Events with limits should show how full they are (ex. 2/10)."** New `#event-capacity-count` on the detail page ("2 of 10 spots taken") and a `data-capacity-count-for` tag on each card ("2/10"). Deliberately separate from the Full/Almost-full badge rather than folded into it: that badge only appears at 90%+, but knowing it's 2/10 is useful long before then. Both are always emitted and hidden when empty, rather than conditionally emitted -- otherwise an event going from not-full to Full would have no element to write into. `applyFillBadgeFromCount()` now updates the detail page, every matching card badge, and every matching card count together, so a registration corrects all of them at once instead of cards keeping whatever was baked in at render time.

**5. The event page "sputtering" on refresh** -- flashing blank title, "Hosted by (blank)", no details, and the role radios. `populateEventPage()` runs several times per load (the classic script's first route pass, again once the module script is ready, again when auth resolves), and the first pass can run before the event data has been fetched at all, painting an empty shell. Removing the old hardcoded sample text earlier is what made that emptiness visible instead of merely wrong. Fixed with the loading-then-content shape `#page-group` already uses: `#event-page-loading` shows a single quiet line until there's real data, `#event-page-content` is revealed by `populateEventPage()`. The loading line is only shown when there's genuinely nothing to display yet -- going from one event straight to another would otherwise trade one flicker for a different one.

**Staleness sweep**, as asked: `events` and `home` were the last two card-rendering routes with no refresh-on-visit hook, so their rendered cards kept whatever registration state they were built with until a full refresh. Both now call `refreshAllCardRegistrationStates()` on visit, in both the click handler and `showRouteFromHash` (Back/Forward). Deliberately not `renderEvents()`, which would re-run the search and reset "Load more" pagination just for visiting the tab.

Verified in a local preview by driving the real functions: a no-volunteer event keeps its radios hidden *even after* the status-check call that used to force them visible, while a volunteer event still shows them; the loading line is up before any populate and swaps to content after; capacity reads "3 of 10 spots taken" / card "3/10" at 30% with no Full badge, then "10 of 10 spots taken" / "10/10" with the card badge appearing and reading "Full" at capacity; and the moved volunteer checkbox is confirmed outside the registration gate while still revealing the max-volunteers question when ticked.

**Also surfaced during verification: migration 034 has not been run yet.** The new error logging added in v57 printed `renderHomeEvents search_events: PGRST203` in the console, which is the duplicate-overload error -- so the homepage preview and church Events tabs are still broken until that migration is applied.

Build `2026-09-16-v59`. No new migration, but 034 is still outstanding.

**Migration 034 verified** after being run: all three call sites resolve with no `PGRST203` -- homepage preview 2 rows (and 2 real cards rendered, empty state gone), church Events tab 2 rows for a visible church, Events listing 2 rows. Note for anyone re-checking this: "Catholic Church of San Antonio" is `is_hidden = true`, so its two events are correctly excluded from all three views (migration 019's whole purpose) -- that's why 4 events exist but only 2 appear, and it is not a bug.

---

## Capacity only makes sense where there are signups to count

Reported directly, and it reverses an earlier request in this same session -- worth recording honestly because the second reasoning is the correct one. Max participants was originally moved OUT from behind "Require registration" on the request that a headcount cap is useful even without formal registration ("show up, first 50 get in"). The follow-up realisation: with no registration there is no signup to count, so a cap can be neither enforced nor displayed. That is also exactly what produced a meaningless **"0/1"** on a no-signup event's card -- real data, since `max_participants` was already set on events whose `registration_required` is false.

Fixed as one rule rather than three copies of it:
- `mapSearchEventRow()` -- `fillBadge` now requires `registration_required` alongside a cap and a known count. This is the single place fillBadge is computed, so both the detail page and every card inherit it.
- `eventCard()` -- the `2/10` tag gates on `registrationRequired && maxParticipants` (it reads `maxParticipants` directly, so it needed the gate explicitly).
- `refreshEventCapacityBadge()` -- treats a no-registration event as uncapped, which makes the badge, the "x of y spots taken" line, and every card count hide themselves through paths they already had.
- The submit handler now saves `max_participants` as null unless registration is required -- a hidden input keeps whatever was typed in it, so without this an organiser who set a cap and then switched registration off would silently persist a cap nothing can count. That's how the existing rows got theirs.

Form-side, Max participants and the volunteer block both moved back inside `#ce-registration-options`, restoring a single coherent rule: everything about signups (cap, volunteers, guests, ticket price, fees, discount codes) lives under "Require registration". The volunteer block came back for the same reason -- a volunteer signs up exactly like a participant -- which also made its "this only shows when registration is on" hint redundant, so that hint and its two i18n strings were removed rather than left dangling.

Verified in a local preview: DOM nesting confirmed (max participants, volunteer checkbox, volunteer options, price section and guests all inside the gate; `#ce-repeats-section` not swallowed by a stray tag), the gate toggles `none`/`block` with the checkbox, and on the public side a capped-but-no-registration event shows no capacity count, no fill badge and no card tag, while a capped event that DOES require registration still reads "4 of 10 spots taken".

Build `2026-09-16-v60`. No migration.

---

## "Featured" events removed (deliberately, not lost)

Asked what the Featured tag meant, the honest answer was: nothing about the event. It was computed purely from the host church's plan -- `church_plan_type === 'premium' || 'multi_church'` -- so every event a top-tier church posted was featured automatically, with no per-event control of any kind.

Removed on the follow-up reasoning, which is correct: a Multi-Church account running several churches, each posting plenty of events, could fill every top slot at once and crowd everyone else out. The rotation existed to spread exposure evenly (it reshuffled featured events into the top slots on every render so nobody permanently owned "first"), but shuffling within a pool doesn't help when one account can dominate the pool itself.

Removed cleanly rather than left as dead code or a hidden flag:
- the gold Featured tag in `eventCard()`
- `applyFeaturedRotation()` and both of its call sites in `renderEvents()` -- listings now show events in whatever order `search_events` returns, with no plan-based reordering at all
- the `featured` field in `mapSearchEventRow()` (`church_plan_type` is still returned by the RPC; nothing reads it now, which is harmless)
- the `events.featured` i18n strings in both languages
- three stale comments elsewhere that referenced "featured-rotation reshuffle"

A note at the old `applyFeaturedRotation()` site records what was removed and what a replacement would need (per-event opt-in, a cap per church, a bounded paid-placement window -- something with real limits), so this can be rebuilt deliberately rather than rediscovered.

Verified in a local preview: no Featured tag in any rendered card or anywhere in the DOM, event cards still render their title and `2/10` capacity normally, the events grid still populates, and zero remaining references to `applyFeaturedRotation`, `e.featured`, or `events.featured` anywhere in the file.

Build `2026-09-16-v61`. No migration.

---

## Imageless event cards used the church icon

An event card with no image fell back to `buildingIcon` -- the exact same church silhouette a logoless church card uses -- so in a mixed grid the two placeholders were indistinguishable. Added a `calendarIcon` (solid fill, no strokes, same 24-unit grid and flat-silhouette treatment as `buildingIcon`, so they sit together consistently) and a `.thumb--event` rule sizing it to 54px, matching `.thumb--denom` rather than the generic 34px `.thumb svg`, so an event placeholder carries the same visual weight as a church one instead of looking like a shrunken afterthought. No `--thumb-hue` for events: that variable is keyed to denomination, which an event doesn't have, so it gets a neutral ink tint with its own dark-mode value.

Verified in a local preview by rendering an imageless event card beside a logoless church card: both icons compute to 54x54, and the event card's SVG is the calendar (5+ rects) not the building.

Build `2026-09-16-v62`. No migration.

---

## Church-home membership becomes approve/reject instead of self-granted

Requested as "the prime way that churches can secure their membership and control registration so it's constrained to approved members." Before this, clicking "Make this my Church Home" upserted a `church_memberships` row instantly and that person was a member; a church could only see and remove them afterwards.

**Reused rather than rebuilt**: `church_memberships` (unique on `user_id, church_id`, `is_permanent = true` meaning church home) and `church_member_invites` plus its whole email-invite flow both already existed. Neither table's original definition is in this repo, so migration 035 is entirely additive and assumes nothing about their existing policies.

**Enforcement is a trigger, not an RLS policy, and that choice is the point.** This table's existing policies aren't visible here, and permissive policies OR together -- so if any existing policy already lets someone update their own membership row, adding a stricter policy would not take that away and anyone could set their own status to `approved`. A `BEFORE INSERT OR UPDATE` trigger runs regardless of which policy allowed the statement, so it can actually hold the line. RLS decides which rows you may touch; the trigger decides what you may turn them into.

Trigger behaviour:
- **Insert by an authorized actor** (owner or staff with the new ability): value taken at face value -- a church adding someone is itself the approval.
- **Insert by anyone else**: forced to `pending`, *except* when a matching `church_member_invites` row exists for their email, which auto-approves. An invited person has already been vouched for; making them wait for a second approval would be nonsense.
- **Update**: status changes are reserved to authorized actors, with one deliberate exception -- `rejected -> pending`, so someone turned down can ask again. Without that the re-request arrives as an UPDATE, silently touches nothing, and the button does nothing forever with no error: precisely the silent-no-op class that made unregistering look like it worked for weeks (migration 033). Nothing in that exception can move a row toward `approved`.
- **Service-role callers** (no `auth.uid()`) pass through untouched, so edge functions aren't forced into `pending`.

**Grandfathering**, as chosen: the column is added with default `pending`, then every row is immediately updated to `approved`. At the moment the migration runs every existing row is by definition pre-existing, so a blanket update is exactly "leave current members alone" -- written as two explicit steps rather than a clever default.

**New ability `can_manage_members`**, deliberately its own rather than reusing `is_manager`: deciding who counts as part of the congregation is a different kind of trust than managing staff, and a church may well want a membership secretary who isn't a manager. Wired through all eleven of the usual touch points (both invite modals -- static and the JS-rebuilt duplicate -- the permissions modal and its open/save handlers, `loadTeamPanel`'s tag and data attribute, `inviteStaffToOneChurch`, the invite submit payload, `getMyChurchUncached`'s owner and staff branches, and the profile ability tags), mirroring `receives_contact_messages` exactly.

Also carried the two signature hazards this repo has now hit four times: `get_church_staff_detail` gains a column so it is DROPped before recreation (return-type change, 42P13), and `update_staff_abilities` gains a parameter so the previous 9-argument overload is dropped -- the same thing that, when missed in migration 022, silently broke the homepage and church Events tabs.

Client side: the church-home button now reads every membership row rather than `.limit(1)` (someone can have an approved home at one church and a pending request at another -- one arbitrary row can't answer both questions), shows a distinct disabled "Request sent — awaiting approval" state, and reports what actually happened after a request rather than assuming, since an invited person is auto-approved and telling them they're awaiting approval would be wrong. A Members panel sits above Recently Joined (the queue with something to decide should be the one you see first), driven entirely by the new RPCs so authorization is explicit and a zero-row result is reported rather than read as success. The Recently Joined hint, which said "Membership stays instant for everyone… not a gate anyone has to wait on", was corrected -- it is now exactly false.

**Still open, flagged rather than assumed**: anything that treats "has a membership row" as "is a member" without checking `status = 'approved'` will now count pending people. The directory-people RPC that computes `is_member` is one of the untracked functions, so it can't be checked or fixed from here -- worth reviewing in the dashboard before relying on member counts.

Verified pre-migration in a local preview: all six new elements present, `loadMembersPanel` exposed, no console errors (it hides itself when `getMyChurch()` returns null rather than erroring), and both new RPCs correctly report `PGRST202 not found` -- the expected state until 035 is run.

Build `2026-09-16-v63`; **migration 035 must be run by hand.**

---

## 035 follow-up: leaving a church never actually left, which broke two other things

Three symptoms reported right after 035 went live, all one root cause: "leaving" only flipped `is_permanent` to false and left the row behind with `status = 'approved'`.

1. **No way to cancel a pending request** -- the pending button was rendered disabled, a dead end with no way out.
2. **Re-joining failed** with "Only the church can change a membership's approval status." The leftover row made the re-join an UPDATE going `approved -> pending`, and 035's trigger only carved out `rejected -> pending`.
3. **The church's directory still listed the person as a member the whole time**, because the approved row never went anywhere.

Fixed by making leaving mean the row is deleted, so coming back is a plain INSERT with nothing to reconcile:

- **`leave_church(target_church_id)` RPC** (migration 036) covering both verbs -- cancelling a pending request and leaving an approved membership are the same operation on the data, and splitting them would only invite the two copies to drift. An RPC rather than a client-side delete plus a policy, for the reason this repo keeps relearning: `church_memberships`' existing policies aren't visible here, so a `.delete()` would depend on an unseen policy and could silently affect zero rows (migration 033). The function's WHERE clause is `auth.uid()` and doesn't take that from the caller, so it deletes your own row and nobody else's.
- **The trigger's exception widened** from `rejected -> pending` to the actual invariant worth protecting: nobody unauthorized may move a row TO `approved` or `rejected`, but moving *your own* row to `pending` is a request, not an escalation -- it strictly reduces what you have -- so it's allowed from any prior state. Guarded by `new.user_id = auth.uid()`, which the trigger can't assume RLS already enforces, for the same reason 035 used a trigger at all. The narrow rule would have kept biting: a row left at `is_permanent = false` by the switch-church-home path hit the same wall.
- **Switching church homes now deletes the old row too**, rather than leaving it at `is_permanent = false` -- previously that kept you listed as the old church's member forever after you'd moved on.
- **The pending button is now clickable** ("Request pending — click to cancel") instead of disabled.

**Seven membership reads gained `status = 'approved'`**, which is the other half of symptom 3 and would have been a live bug on its own: every place that treated "has a row" as "is a member" now counts pending people. Covered the user's own church-home reads (event filter, My Churches, profile home-church name), the church-side counts (overview per-church member counts, reporting member list, `getChurchPeopleIds`), and Recently Joined. Deliberately left unfiltered: the switch-home lookup, which should clear *every* prior home row including a pending one at another church.

Still outstanding and unfixable from here: the untracked directory-people RPC that computes `is_member` server-side. If it counts any membership row, pending people will show as members in that table regardless of the client-side filters above.

Build `2026-09-16-v64`; **migration 036 must be run by hand** (035 first).

---

## Leaving gets its own button, and the membership badge stops being a toggle

Requested directly after 036: a dedicated "Leave church" button, a confirm step warning that rejoining needs approval again, and the "This is your Church Home" button made non-clickable once you're in.

The underlying point is worth writing down, because the old behaviour was a real hazard rather than just an odd affordance: once you're a member, that button is a **statement of fact**, not a toggle. A badge that says "you're in" and destroys what it describes when clicked is the kind of thing people hit by accident -- and under the approval model the cost of that accident is no longer symmetric, since getting back in means asking again and waiting on a decision that isn't yours to make. So the `is-home` state now sets `disabled = true`, and leaving moved to its own button that only appears in that state.

Confirm copy, recommended and used: **"Leave this church?" / "You'll be taken off this church's member list. If you want to come back later, you'll need to request to join again and wait for them to approve it." / "Yes, leave this church" / "Never mind."** The middle sentence is the part that matters -- it names the actual consequence (a second approval you don't control) rather than a generic "are you sure", which is what makes a confirm worth showing at all.

Deliberately NOT behind a confirm: cancelling a pending request. Nothing has been granted yet, so there's nothing to lose by cancelling, and a confirm there would be friction with no hazard behind it.

Uses the same styled-modal shape as `confirmSwitchChurchHome()` rather than a native `confirm()`, for the reason that function's own comment already gives: a "faithdock.com says..." popup reads as a stray system alert rather than part of the product. Kept as a second small function instead of generalising the two into one parameterised helper -- there are exactly two, and the indirection would cost more to read than the duplicated lines save.

The click handler's old `is-home || pending` branch narrowed to `pending` only, since `is-home` is now unreachable through that button.

Verified in a local preview by driving the real `checkChurchHomeStatus()` with its queries stubbed (so the actual function's branches run, not a reimplementation of them): approved member gives a disabled "✓ This is your Church Home" with the Leave button shown; pending gives an enabled "Request pending — click to cancel" with Leave hidden; no membership and has-other-home both give the normal enabled "Make this my Church Home" with Leave hidden. Then clicked Leave for real and confirmed the modal opens and that cancelling makes **zero** RPC calls.

Build `2026-09-16-v65`. No new migration (036 still required).

---

## Members-only events, in three modes, plus the tag split that made them expressible

The three modes chosen: Public; Members only *listed* (anyone can see it, only members can register -- the incentive case); Members only *hidden*.

**Stored as two columns, not a four-valued enum.** `visibility` already answers "who can SEE this" (public/private/draft); the new `events.members_only_registration` answers "who can SIGN UP". They really are independent questions, and mode 2 is a genuinely public listing -- giving it its own `visibility` value would mean teaching every existing visibility check about a value that, for seeing purposes, behaves exactly like `public`. The UI still presents one 4-way choice, mapped in exactly two places (save and edit-load), so nothing downstream knows about the UI's vocabulary. Defaults to false, so every existing event stays as public as it is today.

**`search_events` was hiding members-only events from members too.** Its filter was a flat `e.visibility = 'public'`, so mode 3 was not merely unimplemented -- it was unusable, since a private event could never be seen by anyone including the church's own congregation. Widened to also return private events to approved members of the owning church. Deliberately left INVOKER rather than SECURITY DEFINER: the membership subquery only reads the caller's OWN rows (`cm.user_id = auth.uid()`), which any sane policy already allows, and a SECURITY DEFINER search function is a far bigger thing to get wrong. Recreated with DROP first since the return table gains a column (42P13), with the parameter list matched exactly -- getting that wrong leaves a second overload behind, which is the bug that broke the homepage and church Events tabs when 022 added `p_keyword`.

**Enforcement is a trigger, not the hidden button.** The client can hide Register from a non-member, but that's a courtesy; a church is being asked to *rely* on this, and anything enforced only in the browser can be skipped by calling the API directly. `enforce_event_members_only()` raises the fixed string `EVENT_MEMBERS_ONLY`, following the existing `EVENT_CAPACITY_FULL` / `EVENT_GUESTS_FULL` convention so the client shows localized copy instead of a raw database error. Cancelled rows skip the check (not someone taking a spot) and service-role callers pass through (a paid-checkout edge function has already done its own checking and has no `auth.uid()`).

**The tag split, which is what made the earlier naming confusion fixable.** "Open to anyone" and "No signup needed" were one tag driven by `registration_required`, and read as overlapping because they aren't parallel: one describes who may come, the other whether signup exists. Now two tags -- `Public event` / `Members only`, and `Registration required` / `No signup needed`. This is why the literal "rename Open to anyone to Public event" would have been wrong on its own: it would have labelled a members-only event "Public event", since that tag was never about visibility.

Verified in a local preview: all four modes round-trip through the real select and both mapping directions (`public`, `members_listed`, `members_hidden`, `draft` each come back as themselves), and legacy rows stored as `private` before this feature existed map to `members_hidden` rather than a blank. Tag rendering checked through `eventCard()` across five combinations, including the one that was previously impossible to express: "Members only" + "No signup needed".

**Deliberately not done**: the Register button is not pre-emptively hidden for non-members on a members-only event -- they get the trigger's clear message on clicking instead. The enforcement is real either way; pre-empting it is a UX nicety worth doing separately rather than half-wiring now.

Build `2026-09-17-v66`; **migration 037 must be run by hand** (035 and 036 first).

---

## Member decisions didn't refresh the Directory table above them

Reported with a screenshot: removing someone from the Members panel left them sitting in the Directory table above, with their old role, until a full refresh.

Same "one fact, several views" shape that keeps recurring here (the follow hearts, the register buttons, the church switcher). The Members panel's handler refreshed itself and Recently Joined but not `loadDirectoryPeople()`, which owns that table. Notably the OLDER Recently-Joined remove handler already refreshed the directory correctly -- the new panel was the outlier, which is its own small lesson about adding a second path to do something that already had one.

Fixed for all three decisions, not just the reported one: approve and reject need it as much as remove, since approving is precisely the moment someone becomes a Member in that table.

Also switched the Recently-Joined handler's direct `.delete()` on `church_memberships` to the `remove_church_member` RPC added in 035. It was the last direct membership delete in the file, and it depended on an RLS policy this repo can't see while reporting success either way -- the same silent zero-row shape as migration 033. There are now no direct membership deletes left in the client.

Verified in a local preview by clicking the real buttons with `getMyChurch`'s cache seeded (`window._myChurchCache`) so the actual handler ran rather than a stand-in: approve fires `set_church_membership_status(approved)`, reject fires it with `rejected`, remove fires `remove_church_member`, and all three reload the Members panel and the Directory table.

Build `2026-09-17-v67`. No new migration (035/036/037 still required).

---

## Events by church on the all-churches overview, and following events

Two of the remaining requests from the same batch.

**Events by church (tier 4/5 Overview).** Mirrors the existing Staff-by-church section -- same card/row classes -- rather than inventing a second layout for the same "one card per church, rows inside" idea. Each church lists its next five upcoming events with date, registration count, and a Members only tag where it applies. Count formatting follows what the data can actually support: `x/max` when capped, "n registered" when uncapped, "No signup needed" when registration is off (there is nothing to count).

Two things worth noting in the implementation. The existing events query was widened rather than a second one added -- it already fetched `id, church_id, start_at` for the tile stats, so the extra fields ride along on the same round trip. And registration counts come from **one batched query** across every upcoming event (`.in('event_id', ids)`) rather than a call per event: a Multi-Church account with five churches can easily have dozens of events, and that many round trips to draw one panel is how a page starts feeling broken. It's fired after the grid is already on screen, so a slow count delays nothing else.

Verified with stubbed queries driving the real panel: a capped event renders `2/10` (correctly counting only participants -- the volunteer row in the fixture is excluded), an uncapped one renders "0 registered", a no-signup one renders "No signup needed", a private event picks up the Members only tag, a past-dated event is excluded, and the rows come out soonest-first.

**Following events.** `event_follows` (migration 038), deliberately defined properly since `church_follows` -- the thing it mirrors -- predates migration tracking and couldn't be copied: unique on `(user_id, event_id)`, cascade deletes on both foreign keys so removing an event or an account doesn't leave orphan rows, and three separate RLS policies (select/insert/delete, all `user_id = auth.uid()`) rather than one `FOR ALL`, so widening a single verb later -- letting a church see who follows its events, say -- is a change to one policy instead of a rewrite.

Client side reuses the church-follow machinery rather than paralleling it: same `HEART_ICON`, same `.follow-heart-card` / `.follow-heart-profile` styling, same optimistic-then-revert write, same slot position on the detail page. It's the same gesture to the person using it and should feel identical. The only difference is `data-follow-event-id` instead of `data-follow-church-id`, which is what routes a click to the event handler. `applyEventFollowState()` exists for exactly the reason `applyFollowState()` does: the same event can be on screen twice at once (a listing card plus the detail page behind it, since this SPA hides pages rather than destroying them), and updating only the clicked heart is how the church version originally got this wrong.

Initial state loads as a third parallel query alongside the existing follow/home lookups, for the same reason those two were split apart -- an event heart shouldn't wait on an unrelated church-membership check before it stops showing its pre-sign-in empty state.

Verified in a local preview: the heart renders on cards in both states, the detail page slot reflects the same state, `applyEventFollowState()` updates a card and the detail heart *and* the ids array together in both directions, and a real click follows then unfollows, writes the right rows, and does **not** navigate despite the heart sitting inside a click-through card.

**Scope note**: following is currently "keep an eye on this" only -- it does not hold a spot, does not touch capacity (a Full event is still followable, which is arguably when it matters most), and there is no notification or dedicated "events I follow" view yet. Those are the natural next steps rather than things half-wired now.

Build `2026-09-17-v69`; **migration 038 must be run by hand** (and 035/036/037 if not yet).

---

## The event heart: two bugs, and a verification that passed for the wrong reason

Both reported immediately after v69 shipped, and the second one is the more instructive.

**1. Tapping the heart on an event card opened the event instead.** The heart's own handler calls `stopPropagation()`, which is the instinctive fix and is not one here: `stopPropagation()` stops the event travelling to *other elements*, but it does not stop other listeners bound to the **same** element. Both the heart handler and the `[data-route]` navigation handler are bound to `document`, so they are siblings on one element and the navigation handler ran regardless. The only thing that actually keeps a card's navigation from firing is the explicit bail-out list already in that handler -- which is why `[data-follow-church-id]` is in it -- and `[data-follow-event-id]` had simply never been added.

**2. There was no heart on the event detail page at all.** `#event-follow-heart-slot` is `position:absolute`, and `#event-page-content` had no `position:relative`, so the slot resolved against the viewport instead of the content wrap and landed behind the site header. The church page's `.wrap` carries an inline `position:relative` for precisely this reason; the event page's didn't. Load-bearing, not decoration, and now commented as such in both places.

**The part worth remembering.** v69's verification explicitly claimed the heart "does not navigate" -- and it did navigate. The test used a made-up event id, so the navigation path bailed out early (`findOrFetchEventById` returns null, alerts, returns) long before it would have changed the hash. The assertion `hashChanged === false` was true for a reason that had nothing to do with the thing being tested. A negative assertion is only worth anything if you have shown the mechanism it's negating would otherwise fire: re-run with a **real** cached event and it failed immediately. Re-verified that way, plus `elementFromPoint` at the detail heart's own centre returning the heart rather than the header.

Build `2026-09-17-v70`.

---

## Followed events on My Events

Hearting an event now puts it on My Events, which is the point of following -- v69 shipped the gesture with nowhere for it to land.

Merged rather than appended: one entry per **event**, not per relationship, so an event you both registered for and hearted is a single row carrying both tags. This is the same `{ event, labels }` shape (and the same `byId` merge) that `loadMyChurches()` already uses for Owned / Staff / Home / Following, deliberately, so the two pages read as the same idea. Unfollow shows whenever Following is one of the labels rather than only when it's the sole one -- un-hearting an event must not cancel a registration for it -- and routes through `applyEventFollowState()` so hearts on any other page agree immediately.

Sorting stays purely chronological. A followed event you're still deciding about is most useful next to the ones you've committed to, not exiled below them, and the page's own subtitle promises "in order".

One defensive choice: a failed `event_follows` query is logged and skipped, not fatal. Registrations are what this page exists for, and blanking them because the newer secondary query failed trades a small missing feature for a big broken page -- relevant right now, since the page behaves correctly on a database where **038 has not been run yet**. Logged rather than swallowed, because a silently-empty list is exactly the plausible-looking empty state that hid the `search_events` overload for weeks.

Verified against stubbed queries driving the real loader: a followed-only event appears with a Following tag and an Unfollow button, a registered-and-followed event appears **once** with both tags, unfollowing the followed-only row removes it, unfollowing the dual row keeps it and drops only the tag, and a 42P01 on `event_follows` still renders the registrations.

Build `2026-09-17-v70`; **migration 038 must be run by hand** for any of this to persist.

---

## Both follow hearts moved into the detail card

Reported with screenshots of both pages: the heart was "in a weird place". It was -- on the event page it hung above the content wrap with nothing around it, and on the church page it was pinned to the banner, so once the page scrolled it appeared to hover near the Details card without belonging to it. Both now sit in the top-right corner of the card itself (Details on the church page, Event details on the event page).

The non-obvious part is the color. The comment on `.follow-heart-profile` correctly explained that this heart needed no dark-mode variant, because `.banner`'s background is `var(--brand)`, which is never redefined under `[data-theme="dark"]` -- always the same navy. That reasoning was sound and it is exactly what stopped being true the moment the heart landed on a card: `var(--card)` **does** flip with the theme, so one fixed color can no longer be right in both. `#8FA0C4` was chosen to match `#church-eyebrow` against that navy and would have been a muddy blue-grey on a white card. Now recolored to follow `.follow-heart-row`'s treatment -- the closest analogue, a flat card surface with no photo to blend into.

Which dragged in the specificity trap this file has now hit three times: `html[data-theme="dark"] .follow-heart-profile svg` is (0,0,2,2) and an unscoped `[data-following="true"]` rule is only (0,0,2,1), so the followed override has to be re-scoped under the dark selector or a followed heart stays a gold outline forever in dark mode. Verified by reading computed `fill`/`stroke` in both themes rather than assuming the pattern carried over.

`position:relative` went on the church card's inner padded div and inline on the event card, **not** on the `.side-note` class. `.side-note` is shared by several unrelated panels, and turning every one of them into a containing block to position one heart is the kind of change that resurfaces as a mystery layout bug somewhere else weeks later.

`#event-page-content`'s own `position:relative` (added in v70 for the old slot position) is now vestigial for the heart. Left in place, with the comment corrected to say so -- quietly changing what any absolutely-positioned descendant of a broad `.wrap` resolves against is a bigger change than one harmless declaration.

Verified in a local preview on both pages: the slot's `offsetParent` is the card, 15px in from its top and right edges, `elementFromPoint` at the heart's centre returns the heart, and -- since an `h4` is full-width, making a bounding-box overlap test meaningless -- a `Range` around the actual heading glyphs confirms 132px of clear space, with a worst-case long church name ("San Antonio North Foursquare Church") and a denomination tag also clearing it.

Build `2026-09-17-v71`.

---

## Register button flashed on every filter toggle

Reported directly: checking or unchecking a type/category filter made each card you're registered for flash "Register" for a moment before settling back to "✓ Registered — click to unregister".

Nothing was going wrong. That was the truth arriving late, and it was guaranteed to happen every time. `eventCard()` unconditionally emitted a plain "Register" button; `refreshAllCardRegistrationStates()` then corrected it -- but only after a network round trip. Since every filter change re-renders the whole grid, the wrong state was painted first, always, and the "flash" was simply how long the query took.

Fixed the same way the follow heart's version of this was: `refreshAllCardRegistrationStates()` now keeps what it learned in `window.myRegisteredEventRoles`, and `eventCard()` renders from it, so the first paint is already correct. The async refresh still runs and is still the authority -- it just has nothing left to correct in the common case. `applyEventRegisteredState()` updates the cache alongside the buttons, which matters more than it sounds: without it, registering and then touching a filter would re-render straight back to "Register", trading a brief flash for a permanent wrong answer.

The card markup deliberately duplicates `setEventRegisteredUI()`'s output down to its hardcoded English, because the two agreeing is the whole point -- **if they ever disagree, the async refresh becomes its own flicker**. That equality is what the verification actually checks: render a warm card, snapshot computed button text / `data-registered` / `btn-registered` / role-radio and role-label display, run `setEventRegisteredUI()` over it, snapshot again, and require the two to be identical. They are.

**Known remaining case**: the very first render after a cold page load still flashes, because the cache is empty until the first query answers and there is no honest way to know the answer before asking. Every re-render after that is instant. Fixing that properly means persisting the list client-side, which is a real decision about staleness (a registration cancelled on another device would show as current until corrected), not a tweak -- deliberately not done here.

**Noted, not fixed**: `setEventRegisteredUI()` hardcodes "✓ Registered — click to unregister", "Registered as a volunteer" and "Registered as a participant" in English, with no `window.t()` keys, so they stay English under ES. Pre-existing, and out of scope for a rendering fix.

Build `2026-09-17-v72`.

---

## A Trips category, and the translation bug hiding behind translating four strings

**Trips.** Added as a full category rather than just an icon, since an icon with nothing behind it filters to nothing. A category lives in six places in this file and all six had to agree: the icon row on the Events page, the EN and ES dictionaries, the create-event checkbox grid, the sidebar filter checklist's `categories` array, and the two separate `categoryI18nKey` maps (one for rendering tags on cards, one for building that checklist). No migration: `category_tags` is a plain `text[]` with no constraint in any tracked migration, and the client already writes arbitrary strings into it.

A suitcase, not a plane or a bus. "Trips" covers mission trips, retreats and youth trips alike -- a plane quietly implies the international ones, a bus the local ones, and luggage is the established glyph for a section literally called Trips elsewhere on the web, so it needs no learning.

Also deleted a comment claiming a "fixed set of eight" above a list of nine. A count in a comment is wrong the first time anyone adds one.

**The translation bug.** The four registered-button strings were hardcoded English. Translating them looked like a five-minute job and would have shipped a *new* bug, because `applyTranslations()` rewrites `textContent` for every `[data-i18n]` element on the page on a language switch -- and the register button is static markup carrying `data-i18n="events.registerForEvent"`. Switching language while registered would have reset a correct "✓ Inscrito" back to "Register for this event", state and all.

The fix is that **the key moves with the state**: whenever anything writes this button's text, it also sets the `data-i18n` key that text came from, so a later language switch re-applies the right string instead of an obsolete one. Three writers had to learn this together -- `setEventRegisteredUI()`, `eventCard()`'s render-time copy (v72), and `populateEventPage()`.

The priced case gets the opposite treatment: "Register — $12.00" is a composed string no single key can describe, so the key is *removed*. Better a label that lags a language switch than one that silently loses what the event costs.

Verified in both languages: the painted card and the post-refresh card remain byte-identical (the v72 equality that keeps the async refresh from becoming its own flicker -- translating these strings is exactly the kind of change that could have broken it); a registered button survives an EN->ES->EN round trip still registered and correctly translated; and a priced button keeps its price across a switch.

Build `2026-09-17-v73`. No migration.

---

## Reworking the category set: Fellowship, no Holidays, Classes & Studies merged

Community became Fellowship, Holidays was removed, and Classes and Studies merged into one "Classes & Studies". Ten categories down to eight -- which as a side effect means the icon row no longer needs the horizontal scrollbar it had, so every category is visible at once on a desktop width instead of two hiding off the right edge.

The merged category keeps Studies' open book rather than Classes' closed one: it's the glyph that reads as *studying* rather than as *a book*. It uses the short-label-in-the-row, full-name-everywhere-else split that Support Groups and Sports & Recreation already established, so the row says "Classes" while a card tag says "Classes & Studies".

**The part that isn't just find-and-replace.** These names aren't only labels -- they're the literal strings stored in `events.category_tags`, so renaming one in the client orphans any event already carrying it: still tagged, no longer matching any filter, and no error anywhere to notice. `event_categories_remap.sql` (untracked, repo root) handles the stored side: it rebuilds each affected array rather than running four `array_replace` passes, because two old values collapse into one new one and an event tagged both Classes *and* Studies must end up with a single 'Classes & Studies' rather than a duplicate. An event whose only tag was Holidays ends up `'{}'` rather than null, matching how an untagged event is already stored so `search_events`' `array_length(...) is null` check keeps treating it identically.

Holidays is dropped rather than folded into Celebrations. Folding would have been a guess about what those events actually are; the script says so and leaves the alternative one edit away.

As anon I could see exactly one event and zero category tags in use, so the remap may well be a no-op -- but "may well be" isn't "is", and private events, members-only events and events at hidden churches are all invisible from here.

A category lives in six places in this file and all six have to agree, or a filter click sends a value nothing else recognises. Verified by reading all three sets out of the live DOM -- icon row, create-event checkboxes, sidebar filter checklist -- and asserting they're the same set, that no retired value survives anywhere, and that every tag resolves through `translateCategoryTag()`. That last check was initially wrong and worth recording: run in English, a correctly-mapped tag translates to a string equal to itself, so everything looked unmapped. Re-run in Spanish, where a real mapping always changes the string, all eight resolve.

Build `2026-09-17-v74`. No migration; one untracked data script to run if any event turns out to carry a retired tag.

---

## Category icons fill the row instead of scrolling inside it

Three requests together: show the full "Classes & Studies" rather than the short "Classes", make the icons big enough on desktop to reach the end of the line below them, and get rid of the horizontal scrollbar.

They turned out to be one change. The row was a fixed-size flex scroller -- 84px circles, `flex-shrink:0`, `overflow-x:auto` -- so its width had nothing to do with the page's, and `auto` put a scrollbar track under it. It's now a grid of equal fractional columns, with each circle sized at `width:100%` of its column and `aspect-ratio:1` keeping it round. The circles came out at 100px and the row now starts and ends exactly on the tab row's edges below it (28 and 981, measured, not eyeballed), with nothing that can overflow.

`grid-auto-flow:column` + `grid-auto-columns:1fr` rather than an explicit `repeat(8,1fr)`: the column count then follows however many buttons are actually in the markup. The category set has already been edited twice in two days, and a hardcoded 8 would eventually leave a ninth button wrapped onto its own line or an empty column at the end, with nothing to point at why.

**The trap that came with it**: the phone layout at `max-width:640px` sets `grid-template-columns:repeat(4,1fr)` to wrap into rows of four. `grid-auto-flow:column` from the desktop rule still applies inside that media query and overrides `grid-template-columns`, squeezing all eight back into one line -- so the mobile rule needs an explicit `grid-auto-flow:row`. It also needs `aspect-ratio:auto` to undo the desktop ratio, since a quarter of a phone screen is small enough that a column-filling circle makes the glyph inside hard to read; phones stay at a fixed 64px. Checked at 375px rather than assumed: two rows of four, 64px circles, no scrollbar, and the longer label wrapping cleanly onto a second line.

The svg is sized in percent now (39%, the ratio the old fixed 33px-in-84px pair already had) so the glyph grows with its circle and there's no second number to keep in sync.

"Classes & Studies" is the only category showing its full name in the row -- Support Groups and Sports & Recreation still show short forms. That's deliberate but inconsistent, and worth revisiting as a set rather than one at a time.

Build `2026-09-17-v75`.

---

## The card heart moved off the thumbnail -- and took three layout attempts

Requested with screenshots of both the Directory and the Events page: move the heart on church and event cards out of the thumbnail's corner and into the card body's top right, so it no longer sits on top of the graphic.

Three approaches, in order, and the first two are worth recording because each looked right until it was measured:

1. **position:absolute** in the card body. Fine on a church card with one tag; an event card carries up to three tags that wrap, so sooner or later one would end up underneath the heart.
2. **float:right** as the first child of `.card-body`. Collision-proof by construction -- a float is a hole in the text flow. But a float only sits beside content that *fits* next to it, and "Christian / General" is a 145-154px tag in a 181px column. On the Directory the heart floated onto a line of its own **above** the tag rather than level with it, which isn't what the screenshots asked for. Caught by measuring `levelWithTag` across six cards with different denominations, not by looking at one.
3. **A flex tag row**, which is what shipped: `.card-tags` (flex:1, wrapping) beside the heart (flex-shrink:0). The tags get their own column to wrap inside, so the heart is in the same place on every card and nothing can collide with it at any width.

**Recolored, same lesson as the profile heart.** The empty heart's fill was `hsl(var(--thumb-hue))` -- deliberately the denomination hue, so it blended into the pastel placeholder behind it. There is no thumb behind it now and `--thumb-hue` isn't set on `.card-body`, so that fill would have fallen back to a pale blue sitting on the card. It now uses the same treatment as `.follow-heart-row` and `.follow-heart-profile`. The whole `!important` scaffolding went with it: it existed solely to beat `html[data-theme="dark"] .thumb--denom svg`, a selector the heart is no longer nested inside. The dark-mode drop-shadow went too -- it held the heart legible against an arbitrary photo, and on a flat card it only muddied the outline. The `[data-following="true"]` override still has to stay scoped under `html[data-theme="dark"]`; that's the same specificity trap for the third time across three heart variants.

**One easily-missed follow-on**: `applyFillBadgeFromCount()` set `cardBadge.style.marginLeft = '6px'` when writing a live "Full" update, matching the inline margin the tags used to carry. Those margins are gone now that `.card-tags` has its own flex `gap`, so leaving that line would have made a tag drift 6px right of where it rendered the moment capacity changed -- visible only after someone else registered, which is exactly the kind of thing that never shows up in a static check.

Verified by measurement on six Directory cards spanning tag widths from 66px to 145px (heart below the thumb, level with the tag, zero overlap, consistent 18px inset) and on an event card with all three tags showing. `elementFromPoint` at the heart's centre returns the heart on both. The Directory was also confirmed visually; the event card's screenshot wouldn't capture (the preview pane stopped rendering), so that one rests on the measurements plus the fact that both card types now share the same `.card-tag-row` structure.

Build `2026-09-17-v76`.

---

## A Followed Events filter, and shipping a client ahead of its migration

Following an event now leads somewhere on the Events page itself, not only My Events: a "Followed Events" checkbox beside "Followed Churches" and "My Church Home".

**Why this needed a migration rather than a client-side filter.** `search_events` paginates and returns `total_count`, so discarding rows after the fact would give a wrong count, a Load-more button that lies, and pages that come back part-empty. The filter has to happen where the `LIMIT` does. Migration 039 adds `p_event_ids`, which is exactly what 031 did for `search_churches` when "Churches I follow" was built -- the precedent was already in the file, in a comment next to the checkbox this one sits beside.

It drops the function before recreating it. `CREATE OR REPLACE` cannot add a parameter: it leaves the 12-argument version in place and creates a *second* 13-argument one beside it, after which PostgREST can't tell which a call means and raises PGRST203. That is precisely what migration 022 did to this same function by adding `p_keyword`, silently breaking the homepage preview and the church Events tabs until 034 cleaned it up.

**The part worth keeping.** Migrations here are run by hand, so there is always a window where the deployed client is ahead of the database. PostgREST resolves an RPC by the exact set of argument *names* sent, so unconditionally passing `p_event_ids: null` would be PGRST202 against a pre-039 database -- and that breaks **every** events search, not just this filter. So the parameter is added to the call object only when the filter is actually on. Omitted, the call still matches the 12-argument function.

That isn't a theoretical precaution: verified against the live database, which returned `PGRST202: Could not find the function public.search_events(p_event_ids, p_limit)` while the Events page beside it carried on reporting "1 event found". The failure mode is real and the guard is what stops it.

Empty array, never null, when nothing is followed. `null` means "no filter" to this RPC, so a checked box with no follows would silently show *every* event to someone who asked for their followed ones -- the opposite of what they clicked. `'{}'` matches nothing, which is the honest answer. The checkbox is hidden in that state anyway, but the call shouldn't depend on the UI remembering that.

The checkbox appears only once you follow something, same rule as the two beside it. It re-evaluates when `loadEventFilterFollowState()` runs, so hearting your first event reveals it on the next load rather than instantly -- the alternative is a round trip per heart tap.

Build `2026-09-17-v77`; **migration 039 must be run by hand** for the filter to do anything. Until it is, ticking the box changes nothing rather than breaking anything: the param is omitted, so the search comes back as though the box were unchecked.

---

## get_directory_people didn't know the approval workflow existed

Flagged as a suspicion while building the membership queue, then confirmed by reading the deployed function: `get_directory_people()` predates migrations 035/036 and was never taught that asking to join and being a member are different things.

```
left join church_memberships cm
  on cm.user_id = p.id and cm.church_id = target_church_id
  and cm.is_permanent = true
```

No `status` anywhere, and `is_member` is `coalesce(cm.is_permanent, false)`. A row created by someone merely *requesting* to join is `is_permanent = true, status = 'pending'`, so two things went wrong at once: the person was reported as a full member, **and** the outer `where cm.id is not null` is what admitted them to the result at all -- someone with no other connection to the church appeared in its Directory purely by having asked. That defeats the point of an approval queue: the church sees them as already in before deciding anything.

One missing predicate causes both, so one line fixes both. It goes in the JOIN condition, not the WHERE: this is a LEFT join, and a `where cm.status = 'approved'` would quietly turn it into an inner join and drop every staff member, owner and event registrant who has no membership row at all.

Migration 040 uses `CREATE OR REPLACE` with no DROP, unlike 039 the same day. That's not inconsistency: 039 *added a parameter*, which REPLACE cannot do (it leaves a second overload and the PGRST203 that 022 caused). Here the argument list and the `RETURNS TABLE` row type are byte-identical and only the body changes, which is precisely the case REPLACE handles. The migration is the live `pg_get_functiondef` output with one line changed, not a reconstruction from memory -- worth insisting on for an untracked function, since anything reconstructed would silently become the new truth.

No build stamp: this is entirely server-side, no index.html change.

---

## Full category names in the icon row, breaking where they're meant to

The icon row showed "Support" and "Sports" while the merged category showed the full "Classes & Studies" -- inconsistent, and fixed by going full everywhere, with the second half of each name dropped to its own line.

The mechanism is worth knowing because the obvious one doesn't work here. `applyTranslations()` assigns `el.textContent`, so a `<br>` in the label would be shown literally as the characters `<br>` the moment anyone switched language. Instead the break lives in the dictionary value as a real `\n`, and only `.event-category-btn span` sets `white-space:pre-line` to honour it.

The nice part is that the *same* keys are reused by the create-event checkboxes, the sidebar filter checklist and card tags, where `white-space` is the default `normal` -- which collapses a newline to an ordinary space. So one dictionary entry reads "Support / Groups" under a circle and "Support Groups" everywhere else, with no second string to keep in sync and no per-context logic.

Spanish gets its own break points rather than the English ones transliterated: "Clases / y estudios" divides after the noun, not before the conjunction the way "Classes / & Studies" does.

Verified by measuring rather than reading, since `textContent` always reports the raw `\n` and says nothing about how it paints: the icon-row label computes `white-space: pre-line` and two line-boxes in both languages, while the sidebar filter label and a card tag compute `normal` and one. (The create-event label measured zero height because that page is hidden at the time -- it computes `normal` too, so it collapses the same way, but that one is inferred rather than measured.)

Build `2026-09-17-v78`.

---

## Stored XSS in the card templates (confirmed, then fixed)

`eventCard()` and `churchCard()` built their markup by string concatenation and interpolated stored fields -- event title, church name, denomination, service times, a nested event title -- with no escaping at all. Confirmed by probe rather than by reading: an event titled `<b class="xss-probe">INJECTED</b>` came back from `eventCard()` as a live `<b>` element. An `onerror=` would have run in every visitor's browser with their session.

Severity comes from who can reach it. An event title is written by a church account, and churches can be claimed -- so there is no compromise step. Sign up, claim a church, name an event, and the payload executes for everyone browsing Events, the Directory or the homepage.

**Escaping goes in the template, not the helper.** `displayChurchName`, `formatChurchNextText`, `formatChurchNextEventText` and `translateBadgeLabel` all return plain strings and are also used in `textContent` contexts, where a pre-escaped `&amp;` would show up literally. The escape belongs where the HTML context is.

`escapeHtml` also now escapes both quote characters. `&`, `<`, `>` are enough between tags, but these templates interpolate into `class="..."`, `data-church-name="..."` and `style="..."`, and there a bare `"` ends the attribute and starts a new one -- which is how you attach an `onerror=` without ever writing a `<`. Verified: a church named `" onmouseover="..." x="` produces an anchor with exactly four attributes and no `onmouseover`.

**The URL half needed its own function, and my first version of it was still exploitable.** HTML-escaping does nothing to `javascript:` -- it contains no special characters -- so a URL field is the classic way an XSS survives a careful escaping pass. `safeImageUrl()` allows only `http(s):` and `data:image/`, rejecting `javascript:`, `data:text/html` and protocol-relative `//evil.com` (which inherits the page scheme).

The quotes then have to be **percent-encoded, not HTML-escaped**: the HTML parser decodes entities in an attribute value before the CSS parser sees it, so an escaped `&#39;` turns back into a real `'` and closes the `url()`. The first implementation used `encodeURIComponent` for that and **was still vulnerable** -- caught only by testing with a real breakout string, `https://x/a.png');background-image:url('javascript:alert(1)`, which came back unchanged. `encodeURIComponent` leaves the unreserved marks `! ' ( ) * ~` alone, and `'` and `)` are exactly the two characters needed to escape a `url(...)`. Replaced with an explicit escape table. Now the browser parses one `background-image`, not two.

Worth keeping as a general lesson: a function named "encode" that silently declines to encode the characters that matter is a good argument for spelling out the table, and for testing an escaper with the attack it is meant to stop rather than with a benign `<b>`.

Build `2026-09-17-v79`. No migration.

### Audit of the remaining innerHTML sites

313 `innerHTML` assignments in total, of which **152 are static or clearing** (`= ''`, fixed markup) and carry no risk. Of the 161 that interpolate:

- **38 render `error.message` directly.** A Postgres error can quote the offending input back (`Key (name)=(...)`), so this is attacker-influenceable, but the reader is normally the same person who caused it. A real category worth fixing as a class, not an emergency.
- **A handful carry genuinely user-controlled data and are still unescaped**, notably `myChurch.name` into a dashboard `<h2>` (16893), `c.name` into `data-church-name` with no escaping at all on the admin church page (22734), an owned church name in the delete-account warning (23442), and a group name quote-stripped by hand rather than escaped (21763) -- the same partial pattern `churchCard` used before this fix.
- **The large remainder is legitimate internal markup**: element ids, counts, i18n strings, colour class names. Blanket-escaping those would be noise and would break the markup they intentionally build.

### Separately: `javascript:` in social links

The audit's URL half turned up a live one. `populateChurchPage()` does `fbLink.href = c.facebookUrl` and the same for Instagram, with **no scheme check** -- verified on the real element, which reports `protocol === 'javascript:'` after assignment. A church setting its Facebook URL to a `javascript:` URI gets a link that runs script when a visitor clicks it. Those two anchors also lack `rel="noopener"` despite `target="_blank"`, unlike the website link beside them.

The website link is safe, but by accident rather than design: `/^https?:\/\//.test(c.website) ? c.website : 'https://' + c.website` turns `javascript:alert(1)` into the harmless, broken `https://javascript:alert(1)`. Worth making deliberate rather than leaving as a happy side effect.

---

## javascript: in church-supplied links

Found while auditing the rest of the `innerHTML` sites after the card XSS fix, and the more interesting half of that audit: escaping was never going to catch this one.

`populateChurchPage()` assigned a church's Facebook and Instagram URLs straight to `href` with no scheme check at all. Confirmed on the real element rather than by reading -- after assignment it reported `protocol === 'javascript:'`. A church setting its Facebook URL to a `javascript:` URI got a link that ran script in any visitor's session when clicked. HTML-escaping is no defence: `javascript:alert(1)` contains not one character an escaper touches. This is the standard way an XSS survives an otherwise careful escaping pass.

**The admin screens had it worse.** The platform-admin church panel and the verification queue interpolated `c.website`, `c.facebook_url` and `c.instagram_url` raw into `href="..."` inside `innerHTML` -- both the scheme hole *and* an attribute breakout, aimed at the one session that can approve church claims. A church supplies the string; the admin reviewing it clicks. `adminSafeLinkHtml()` now handles those, and the two protections are deliberately separate because neither substitutes for the other: `safeLinkUrl` vets the scheme, `escapeHtml` stops a `"` closing the href and opening an `onclick=`.

**Why `safeLinkUrl` parses instead of pattern-matching.** The browser is what will ultimately interpret the URL, and it doesn't read one the way a regex does -- it strips tabs and newlines before working out the scheme, so `java\tscript:alert(1)` genuinely is `javascript:` and a hand-rolled `/^javascript:/` walks straight past it. Parsing with `new URL()` and then asking what protocol came out is the check that can't be smuggled past. Verified against tab- and newline-smuggled variants, mixed case, leading whitespace, `vbscript:`, `data:text/html` and `file:`.

The church page's website link was already safe, but **by accident**: the old `/^https?:\/\//.test(c.website) ? c.website : 'https://' + c.website` turned `javascript:alert(1)` into the broken-but-harmless `https://javascript:alert(1)`. A fallback that happens to neutralise an attack isn't a defence, it's a coincidence the next edit could remove without anyone noticing. Now deliberate.

One false negative found and fixed while testing: `gracechurch.org:8080/a` was rejected, because the colon made `gracechurch.org:` look like a scheme -- silently hiding a legitimate website. The host:port carve-out is safe precisely because everything matching it is forced through `'https://' + raw`, and a forced `https://` can never come back out as a dangerous scheme; `javascript:80/x` just becomes the harmless `https://javascript:80/x`, which the test suite checks explicitly.

Also added `rel="noopener noreferrer"` to the two social anchors, which had `target="_blank"` without it -- unlike the website link beside them.

Build `2026-09-17-v80`. No migration.

---

## The rest of the unescaped sites -- including the one the first fix missed

Follow-up to the card XSS fix, working through the audit list.

**churchRow() had the identical bug and was missed.** It is the Directory's List view -- the same church data, the same public exposure, a different template sitting forty lines below `churchCard()`. The original probe happened to land on the card builder, the fix followed the probe, and the sibling went untouched. That is the whole argument for grepping the *pattern* (user data concatenated into HTML) rather than fixing the function a test happened to find. Now escaped throughout and verified with the same probe: `injectsLiveElement: false`, and a name of `" onmouseover="..." y="` yields a row with exactly five attributes and no handler.

Also escaped: `myChurch.name` in five report headers, `r.church_name` as link text in two admin panels (the *attribute* beside it was already escaped, the text next to it wasn't -- easy to look at and think it was handled), `c.name` in the admin church link, and the owned-church name in the delete-account warning.

**What was deliberately left alone, and why.** Roughly 17 sites use a hand-rolled `.replace(/"/g, '&quot;')` for a double-quoted attribute. These are **not** vulnerabilities: HTML entity decoding happens *after* the parser has delimited the attribute, so a `&quot;` inside the value is data, not a closing quote, and escaping the real quote character is sufficient there. A `<` inside an attribute value is likewise inert. The same goes for the several `.replace(/</g, '&lt;')` calls in text contexts -- an injected tag needs a `<`, so escaping it is enough to stop one. Changing these would be churn dressed up as security, and would bury the real fixes in the diff.

That distinction is the point of auditing rather than blanket-escaping: 313 `innerHTML` sites, 152 of them static, and the genuine holes were a small, specific set.

`escapeHtml` call sites went from 7 to 49.

Build `2026-09-17-v81`. No migration.

---

## Escaping the error.message sinks

All 38 places that rendered a raw `error.message` into `innerHTML` now go through `escapeHtml`. Postgres quotes the offending input back in its errors -- `Key (name)=(...)` -- so a message is attacker-influenceable even though the reader is usually whoever caused it. Verified with a realistic hostile message (`duplicate key value violates unique constraint "x" Key (name)=(<img src=x onerror=alert(1)>)`), which now renders as text and produces no `<img>`.

Scoped by line, not globally, and that mattered: `.message` also appears in dozens of i18n keys (`'dash.messages'`, `'contactChurch.message'`) and in `console.error` / `queueOrSendError` calls where an HTML-escaped string would be wrong. Only lines containing BOTH `innerHTML` and `.message` were touched -- 38 of them, against ~10 distinct error variables. The alternation puts `regRes.error` before `error` deliberately, since matching the shorter one first would have produced `regRes.escapeHtml(error.message)` -- a method call on the response object rather than an escape.

**What this does not fix, on purpose.** The bigger problem with these sinks isn't injection, it's disclosure: a raw Postgres error hands the reader your table names, column names and constraint names. *"new row violates row-level security policy for table church_memberships"* is a free map of the schema. The right end state is logging the raw error and showing something generic -- but those messages are exactly what has made this month's bugs diagnosable, including `PGRST202`, `42601` and `42P13`. That's a pre-launch change, not a today change, and it should be made deliberately rather than smuggled in under "escaping".

Build `2026-09-17-v82`. No migration.

---

## Bounding client_error_logs

The Supabase linter flagged `client_error_logs` for an `INSERT ... WITH CHECK (true)` policy. That permissiveness is deliberate and stays: the table exists to catch errors that happen *before* a session exists -- a failure during signup, a script error on the homepage -- so requiring auth would blind it exactly where it matters most.

What was missing is a ceiling. The anon key is printed in the page source by design, so anyone can POST to `/rest/v1/client_error_logs` in a loop with megabyte-sized `stack` values and grow the table without limit. The client de-dupes identical errors for 60 seconds, but that's browser-side politeness, skipped entirely by anyone calling the API directly -- the same "UI hiding it isn't enforcement" reasoning behind the members-only trigger in 037.

Migration 041 adds a `BEFORE INSERT` trigger, not a stricter policy, for the reason established in 035: permissive policies OR together, so a new restrictive policy can't take away what the existing one already grants, and this table's original policy isn't in the repo to edit safely.

Three decisions in it worth keeping:

- **Truncate, don't reject.** A length `CHECK` would throw away an entire error report because its stack trace was long. The first 10k of a stack is where the cause lives; bounding the size is the goal, losing the error is not.
- **Two separate rate ceilings**, anonymous and per-user. One shared counter would let a flood of anonymous junk silence error reports from signed-in users -- fill the counter with garbage and every real report is refused too.
- **`user_id` is taken from `auth.uid()`, not the client.** The browser sets it from its own `getUser()` call, so it can be forged to any uuid. Not severe -- it pollutes someone else's log rather than reading anything -- but there's no reason to take the caller's word for it when the database already knows.

A refused insert is silent: `sendErrorLog` already wraps the insert in `.catch()`, because logging an error must never itself throw.

### Also from the same Advisor run

**Storage bucket listing.** Three public buckets carried a broad SELECT policy on `storage.objects`, letting anyone with the anon key enumerate every uploaded logo, event image and profile photo -- including those belonging to churches that aren't publicly listed. Public object URLs don't go through RLS at all, so the policy isn't needed for them. Confirmed safe before recommending removal by grepping the client: all three buckets are only ever used with `upload` and `getPublicUrl`, never `.list()`.

**Leaked password protection is Pro-plan only**, so it's parked rather than done.

**The ~150 "anon/authenticated can execute SECURITY DEFINER function" rows are mostly noise** -- that is how PostgREST works, and every RPC the browser calls must be executable by one of those roles. They each re-check authorization internally. Two are worth real scrutiny rather than dismissal: `get_user_id_by_email` (a potential unauthenticated email-enumeration oracle) and `get_waitlist_signups` (if it doesn't check `is_platform_admin()` internally, the whole waitlist is downloadable). Both pending their definitions.

No build stamp: server-side only.

---

## get_user_id_by_email was an open email-enumeration oracle

The most serious thing the Advisor sweep turned up, and it was hiding in a list of ~150 near-identical warnings that are mostly noise.

Its entire body was `select id from auth.users where email = lookup_email limit 1;` -- `SECURITY DEFINER`, no authorization check of any kind, `EXECUTE` granted to `anon`. Confirmed live from a signed-out session: an address with no account returns null, a real one returns a uuid. Anyone holding the public anon key (printed in the page source by design) could test whether any email address has a FaithDock account, and harvest the uuid when it does.

Two harms, and the second is the one that's easy to miss. The obvious one is membership disclosure -- "does this person have an account on a church platform" is not a neutral fact about someone. The less obvious one is that the returned uuid is the id this app keys everything on: `event_registrations.user_id`, `church_memberships.user_id`, `profiles.id`. Handing a real one to an unauthenticated caller supplies the exact value any further probing needs.

**The fix is not deletion** -- both callers are real (add a group member by email, invite a staff member by email), both already behind a signed-in dashboard. Migration 042 restricts it to church owners, staff and group leaders.

Requiring merely `auth.uid() is not null` was the tempting one-liner and would have been a weak fix: it converts an open oracle into a free one, since anyone can sign up and keep probing. Scoping to the population that actually reaches either call site costs nothing extra and is a genuinely smaller, accountable set. Signature and return type are unchanged, so no client code moves and `CREATE OR REPLACE` is safe -- contrast 039, which added a parameter and therefore could not use REPLACE.

The group-leader test goes through the existing `is_group_leader()` helper rather than reading a role column directly, so it keeps agreeing with however leadership is defined elsewhere instead of becoming a second, drifting definition of the same idea.

**`get_waitlist_signups`, flagged in the same category, is fine** -- it raises unless `is_platform_admin()`. Checked rather than assumed, and reported as clean rather than padded into a finding.

No build stamp: server-side only.

---

## Pinning search_path, and why only half the warnings get cleared

Migration 043 answers the Advisor's ~35 "Function Search Path Mutable" warnings -- and deliberately clears only some of them.

The risk is specific to `SECURITY DEFINER`. Such a function runs with its owner's privileges, and if its `search_path` isn't pinned it resolves unqualified names against whatever schemas the *caller* has set. Anyone who can create an object in a schema that lands earlier in that path can shadow a table the function trusts and have their version run with the owner's rights. Pinning removes the caller's influence.

Written as a catalog-driven loop rather than ~35 hand-written `ALTER FUNCTION` statements, because ALTER needs exact argument types and some of these signatures are long -- `update_staff_abilities` takes ten parameters. Transcribing those by hand is one typo away from silently altering nothing and looking like it worked.

`pg_temp` goes **last** in the pinned path, which is the part that's easy to get backwards: left implicit it is searched *first*, and a temp table shadowing a real one is itself the attack.

Extension-owned functions are excluded via `pg_depend ... deptype = 'e'`. This matters here specifically because the same Advisor run flagged `pg_net` and `pg_trgm` as installed in `public` -- their functions are not ours to alter, and a sweep that didn't exclude them would either fail on ownership or succeed and change how the extension resolves its own internals.

**SECURITY INVOKER functions are left alone on purpose**, including `search_events` and `search_churches`, which the linter also flags:

1. The escalation argument doesn't apply -- an INVOKER function already runs as the caller, so hijacking its `search_path` gains an attacker nothing they couldn't get by writing the query themselves. There it's hygiene, not a vulnerability.
2. **Adding a `SET` clause to a `LANGUAGE sql` function blocks inlining.** The planner can't inline a SQL function carrying a `SET`, so `search_events` -- a multi-join query with a LIMIT, run on every Events page load -- would stop being folded into the calling query and could get materially slower.

Trading real query performance for a warning that carries no privilege risk is a bad trade. Worth recording because the obvious move is to clear every warning the linter raises, and "the linter is satisfied" is not the same as "the system is better". The migration says how to sweep them too, for anyone who decides the clean dashboard is worth benchmarking for.

No build stamp: server-side only.

---

## The storage-bucket listing warning -- and a wrong conclusion about it

The Advisor's `public_bucket_allows_listing` flagged all three public buckets (`church-logos`, `event-images`, `profile-photos`) as letting any client enumerate every uploaded file. The warning was **real**, the fix was applied, and it worked -- but the conclusion recorded here first was that it had been a false positive. That was wrong, and how it went wrong is the useful part.

**What the fix was.** Public buckets serve objects through the public object endpoint, which bypasses RLS entirely, so a broad SELECT policy on `storage.objects` isn't needed for image URLs to work -- it only enables listing. Dropping the three read policies removes enumeration while leaving everything the app does intact. Confirmed safe beforehand by grepping the client: all three buckets are used only with `upload` and `getPublicUrl`, never `.list()`.

**Confirmed working afterwards:** `list('')` returns `[]`, `list('<known folder uuid>')` returns `[]` even though that folder demonstrably holds a real logo, and a `HEAD` on the public object URL returns 200. Uploads are unaffected -- the INSERT policies are untouched (their `null` qual in `pg_policies` is normal; INSERT policies carry `with_check`, not `qual`).

**The mistake.** Asked to "do the buckets", the behaviour was probed first -- listing enumerated nothing, so it was recorded as a lint false positive with a recommendation to leave the policies alone. But the drop had *already been run*. The post-fix state was being measured and mistaken for the original one. The evidence that settled it was `pg_policies`, which showed the three SELECT policies the Advisor had named by name were simply gone -- and the Advisor reads names from the catalog, so they had certainly existed when it ran.

**The lesson, which generalises past this one warning:** behaviour alone cannot tell you whether a control was never needed or is already in place. Both look identical from outside. Establishing that files existed turned an ambiguous empty listing into evidence about enumeration -- but it said nothing about *why* enumeration was blocked, and that was the question actually being answered. Reading the policy would have settled it in one query; inferring from behaviour produced a confident, wrong, and nearly-published recommendation to undo a working fix.

**Perspective on the run as a whole.** Of roughly 200 Advisor warnings: one was a genuine vulnerability (`get_user_id_by_email`), a handful were real hardening (`search_path` pinning, the `client_error_logs` ceiling), this one was real and already fixed, and ~150 are noise inherent to how PostgREST exposes RPCs. A linter finding is a hypothesis; so is a behavioural probe.

No migration, no build stamp -- the change itself was three `drop policy` statements, run by hand.

---

## getUser() is a network call, and this file made 62 of them

Reported as "refreshing the member directory took over 10 seconds". The investigation is worth recording as much as the fix, because the first two hypotheses were both wrong.

**Wrong hypothesis 1: the RPC.** `get_directory_people` drives off `profiles` and filters with an `OR` across four outer joins, which can't use an index -- textbook slow. Then the table counts came back: **5 profiles, 5 users, 1 event registration, 4 events**. At that size the query is microseconds. Asking for row counts before writing the rewrite is the only reason a pointless optimisation didn't get shipped.

**Wrong hypothesis 2: the payload.** index.html is 1.7MB with ~1.3MB of inline JS, which looks like an obvious culprit. Measured: it parses and executes in **77ms**. Not it either.

**What it actually is.** A real dashboard reload fires **128 Supabase requests**, 40 seconds of cumulative request time, finishing at 3.2s wall clock. Three separate causes, of which this fixes one:

1. `auth.getUser()` called from **62 call sites** (against 2 for `getSession()`), ~18 firing per load. It is not a local read -- it round-trips to `/auth/v1/user` to re-validate the token every time, and in the trace those were the slowest requests present: 792, 878, 897, 902, 839 ms.
2. All **27 dashboard panel loaders run at module level**, so opening the Directory loads groups, donations, rooms, ministries, households, saved reports and the rest too.
3. An N+1 tail: the last six requests are sequential `event_registrations` calls ~90ms apart.

**The fix wraps `supabase.auth.getUser` at the client**, not the 62 call sites. Semantics are unchanged -- it still performs a real getUser and still returns whatever the server says -- it just stops asking the same question eighteen times per second. Editing 62 sites to use `getSession()` was the tempting alternative and would have been riskier: this file already documents a live bug where `getUser` vs `getSession` mattered during a signup race, so changing what is being asked is a different and more dangerous change than changing how often.

Design notes:
- **Sharing the in-flight promise does the real work.** Those ~18 calls start within a millisecond of each other, so handing every concurrent caller the same promise collapses them with no staleness window at all. The TTL is a backstop for sequential callers, not the main mechanism.
- **Errors are cached for 2s, successes for 30s.** An error is the *normal* answer for an anonymous visitor, so a short cache still collapses the load-time burst -- but a transient network failure must not be able to convince a signed-in person they're signed out for half a minute.
- **Invalidated first thing in `onAuthStateChange`**, before `updateAuthUI()` and routing run, since those call `getUser()` themselves and must see the new state. That event covers sign-in, sign-out, token refresh, user updates and cross-tab session sync.
- An explicit JWT argument bypasses the cache -- it asks about a different token than the current session.

**Verification, and a measurement trap worth remembering.** The obvious check -- count `/auth/v1/user` requests before and after a burst -- returned **zero for everything, including after a deliberate invalidation**. Signed out, supabase-js short-circuits `getUser()` locally and never touches the network, so request counts couldn't distinguish "coalesced" from "nothing happened". Same shape of error as the storage-bucket probe earlier: behaviour that looks identical for two opposite reasons. Verified instead by promise identity, which holds regardless: 18 concurrent callers receive the same promise object, a later call within the TTL reuses it, invalidation produces a fresh one, an explicit JWT bypasses, and every caller gets a consistent result.

The signed-in saving (~17 fewer round trips at ~900ms each) can only be measured with a real session, so it is claimed as verified-in-mechanism, not verified-in-effect.

Build `2026-09-17-v83`. No migration.

---

## Dashboard panels load when the dashboard opens, not on every page

Second of the three causes behind the 128-request dashboard load (the first was `getUser()`).

24 panel loaders -- team, rooms, ministries, funds, giving, attendance, groups, directory, households, involvement, scheduled messages, message history and the rest -- ran at module top level, so they ran on **every** page load: the homepage, a church profile, the public Events page. They now register with `dashPanel()` and flush when the dashboard actually becomes the active route.

**Deferred to route, not to tab.** Lazy-loading each panel on its own tab click would cut more, but several of these feed counts and badges that are meant to be visible on tabs you haven't opened -- the pending-requests count, the duplicates warning. Deferring to "the dashboard is open" keeps every one of those behaviours identical while removing the cost from the rest of the site.

Every target element was confirmed to sit inside `#page-dashboard` before its loader was moved, by resolving each loader's first `getElementById` and asking the live DOM which `.page` it belonged to. `loadRealChurches`/`loadRealEvents` stayed exactly where they were, because they don't.

**The half that actually mattered.** Deferring the module-level calls alone would have achieved almost nothing for signed-in users, because a separate auth-refresh path called nine of these loaders **unconditionally on every auth settle, on whatever page you were on**. Its comment explains why, and the reasoning is sound: after switching accounts the dashboard must not still show the previous account's data.

That intent is kept, at a fraction of the cost. If the dashboard is on screen, the nine still reload immediately -- someone watching it while their account changes underneath them is exactly the case that rule exists for. If it isn't, the panels are marked stale instead, which gets the same guarantee for free: nothing is on screen to be wrong, and they load fresh the moment the dashboard opens. That required the registry to be permanent rather than a drained queue, so it can be re-run after an account switch.

This one was only found because the first verification looked wrong: after deferring the module-level calls, `directory-tbody` on the homepage still read "Register a church first" -- text only that loader writes. Chasing that string is what surfaced the second call path. Had the check been "did requests drop", it would have passed (signed out, every panel bails cheaply before querying) and the real problem would have shipped untouched.

**Verified:** the homepage now leaves `directory-tbody` as its untouched static placeholder; the first flush runs the panels; a second flush is a no-op; `resetDashboardPanels()` marks stale without loading anything; and a flush after a reset runs them again.

**Not verified:** the actual request reduction, which needs a signed-in session. Expect roughly 128 down toward 40 on a dashboard load, and a much larger drop on every non-dashboard page while signed in.

Build `2026-09-17-v84`. No migration.

---

## In-flight request coalescing

Third and largest of the causes behind the slow dashboard. A measured load made 113 requests including `search_events` **13 times**, `churches` **17 times**, `event_registrations` **17 times** and `search_churches` **6 times** -- the same query, issued simultaneously by components with no knowledge of each other.

**The cost is not additive, which is the part worth understanding.** With that many requests in flight at once they contend for the connection: queries measured at ~900ms in an earlier, lighter trace showed up at **4-6 seconds** in the busy one. Removing duplicates therefore speeds up everything that remains, rather than just subtracting its own time. That also explains why the page felt like ten seconds while `get_directory_people` itself returned in 400ms.

**Why this is safe, stated precisely:** it merges only requests **already in flight together**, and the entry is dropped the instant one settles. It is not a cache. Two identical requests overlapping in time would have returned the same bytes anyway, so sharing one response cannot serve anything staler than the caller would otherwise have received. A TTL cache *would* be able to -- register for an event, re-query the count, see the old number -- which is exactly why there isn't one, and why two *sequential* identical reads still make two requests.

Installed as the client's `fetch` rather than by wrapping `supabase.rpc()`, because the worst offenders (`churches`, `event_registrations`) are ordinary `.from()` selects that never pass through `rpc()`. One wrapper covers every path.

**GET is coalesced unconditionally; POST is allowlisted.** POST is also how every write and every side-effecting RPC travels, so merging it blindly could silently turn two people's submissions into one. The allowlist names read-only functions only. Forgetting to add a new read-only RPC costs a duplicate request; wrongly adding a writer would lose data -- so the failure modes are deliberately lopsided.

Two details that would bite anyone reimplementing this: a `Response` body can only be read once, so **every** consumer including the first gets a `.clone()` and the stored master is never consumed; and the key includes the `Authorization` header, because two concurrent requests to the same URL under different credentials are not the same request -- RLS can legitimately return different rows.

**Verified:** 10 concurrent identical selects produce 1 network request and 10 correct results; a different query is fetched separately with its own correct row count; two sequential identical reads produce two requests; **three concurrent identical writes produce three requests** (RLS-rejected, nothing written); and a non-allowlisted RPC passes through as two. Rendering is unaffected -- Events still reports "1 event found", Directory still "799 churches found" with 24 cards.

**Effect:** the homepage went from 27 requests to 9. Events plus Directory together now cost 13, less than the homepage alone did before.

Build `2026-09-17-v85`. No migration.

---

## Six dashboard panels went blank instead of loading

Asked whether the dashboard renders progressively or sits blank, the answer turned out to be "progressively, but unevenly".

Only **1 of 24** panel loaders paints a loading state before its first `await`. That sounds bad, but it isn't the whole picture: **15 of 21** panel containers ship with static placeholder markup in the HTML, which paints with the document at ~527ms regardless of any query -- "Loading your events...", "Loading directory...", an em dash in each stat tile, and the Directory sub-panel headings. So the shell and its structure are visible early and content fills in over the next ~2.5s, which is the right pattern.

Six containers had neither: `team-list`, `rooms-list`, `ministries-list`, `funds-list`, `giving-status`, `households-list` shipped empty *and* wrote nothing before awaiting, leaving blank gaps under their headings for a couple of seconds.

That's worse than slow, it's ambiguous. An empty list is also a legitimate real state for most of these, so "still loading" and "you have no staff yet" looked identical. Fixed by giving them the same static `common.loading` placeholder the other fifteen already use -- no logic change, no new strings, and it inherits Spanish for free.

Worth separating from the performance work that surfaced it: this doesn't make anything faster, it makes the same 3 seconds legible. The two are independent, and the perception fix was cheaper than any remaining query optimisation.

Verified: all six show "Loading..." / "Cargando..." before data, the loaders still overwrite rather than append, and no placeholder is duplicated.

Build `2026-09-17-v86`. No migration.

---

## Check-in could fail silently at the door

Found while planning the check-in redesign, and it changed the order of that work: fix the write before building anything on top of it.

The toggle did an optimistic paint and then:

```
var { error } = await supabase.from('event_registrations')
  .update({ checked_in_at: newValue }).eq('id', regId);
if (error) { /* roll back */ }
```

No `.select()`. This is the **fourth** appearance of the same pattern in this project -- the Give/Message toggles, unregistering (migration 033), removing a member, and now this -- and it is at its most damaging here. Because the tick is painted before the write (correct: a door needs to feel instant), a refused write never rolls back. The volunteer sees a green tick and nothing is recorded. A check-in desk that fails silently is worse than one that refuses, because nobody discovers it until someone asks who was actually present.

**Confirmed live rather than argued.** The same refused update, run twice against the real database from a signed-out session:

| | error | result |
|---|---|---|
| without `.select()` | `null` | `data: null` -- indistinguishable from success |
| with `.select('id')` | `null` | `rows: 0` -- detectable |

**The risk is not hypothetical.** Migration 033's UPDATE policy on `event_registrations` is scoped to `user_id = auth.uid()`. On its own that means a staff member checking in *anyone else* matches zero rows. Whether another policy also permits staff isn't visible from this repo -- `event_registrations` predates migration tracking. So this check is what turns an unknown into a visible one either way, and the outstanding question is worth settling directly:

```
select policyname, cmd, qual, with_check from pg_policies where tablename = 'event_registrations';
```

The optimistic paint stays -- it's right for a busy door. What changed is that the rollback now triggers on "nothing was written", not only on an error object, with a message that says the change was refused rather than interpolating a null.

Checked the other `event_registrations` writes while here: the unregister paths already carry `.select()` from the 033 work, and an INSERT refused by RLS returns 42501 rather than failing silently, so this was the only one.

Build `2026-09-17-v87`. No migration.
