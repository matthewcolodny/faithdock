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
