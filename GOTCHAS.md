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

## Working conventions worth restating

- **Bump the footer build stamp** (`build YYYY-MM-DD-vNNN`) after every round of changes — it's the fastest way to confirm whether what's live actually reflects the latest work, or whether a browser is just caching an old version.
- **Auth-related changes get live-tested with real console/DOM evidence before being trusted.** This file exists specifically because several bugs "looked safe on paper" — three separate wrong theories, in one case — before someone actually inspected the DOM or pasted a real console log and the true cause became obvious. Reasoning from the code alone was not enough for any of the bugs listed above.
- **New user-facing strings** need both English and Spanish dictionary entries plus a `data-i18n` attribute (or `data-i18n-placeholder` / `data-i18n-title` for non-text-content cases). Mixed-content elements — an icon next to text — need the text wrapped in its own `<span data-i18n="...">`, not left as loose text beside the icon.
- **Plan-gated features** follow one pattern: an inline locked/upsell panel in the UI, plus a matching server-side check at save time. Never just hide something in the UI and call it gated.
- **Theming:** `--brand` (fixed navy) for anything that must stay legible against gold; `--ink` (adaptive) for regular body text. Mixing these up is how buttons go invisible in dark mode.
