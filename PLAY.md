# Shipping FaithDock on Google Play

The route is a **Trusted Web Activity**: an Android package that opens
faithdock.com in full-screen Chrome with no browser UI. It is Google's
own supported path for a PWA, not a webview wrapper — it is real Chrome,
so it shares sessions with the browser and has every capability Chrome
has.

**The content is the website.** Push to `main` and the app changes with
it, immediately, with no review. Only the shell — name, icon, target SDK
— needs a Play release. The ship-fast workflow survives.

---

## Already done

- Manifest complete: `name`, `short_name`, `id`, `start_url`, `scope`,
  `display: standalone`, `theme_color`, `background_color`
- Icons: 1024 and 512 PNG, plus a maskable PNG (`tools/make-icon.js`)
- HTTPS, a service worker, and installability proven on a real phone
- **Play billing compliance** — see below; this is already in the code

## Not done

1. Play Console account
2. The built package
3. `/.well-known/assetlinks.json` — needs a signing fingerprint that
   does not exist yet
4. Store listing assets
5. Data safety declaration

---

## 1. Play Console account — register as the LLC

$25, one-time.

**Register as an organisation, not an individual.** Individual accounts
created since late 2023 must run a closed test with 12 testers opted in
for 14 continuous days before they can apply for production. Organisation
accounts are exempt. FaithDock is an LLC, so this is simply a matter of
choosing the right account type at signup — and it is painful to change
afterwards.

(Google revises this. Confirm the current terms in Play Console rather
than trusting this paragraph.)

## 2. Build the package

Either works.

**PWABuilder** (pwabuilder.com) — paste the URL, download the Android
package. No toolchain. Easiest for a first submission.

**Bubblewrap** (Google's own CLI) — `npm i -g @bubblewrap/cli`, needs
JDK 17 and the Android SDK. More control, reproducible, and the config
could live in this repo.

**Set the launch URL to `/?shell=android`.** Not the manifest's
`start_url` — that is shared with the ordinary installed PWA, which is
not distributed through Play and must not be affected. Only the TWA's
own launch URL. See "Billing" below for what the flag does.

## 3. Digital Asset Links — the step people get wrong

`https://faithdock.com/.well-known/assetlinks.json` must contain the
SHA-256 fingerprint of the key the app is **actually signed with**.

**With Play App Signing — mandatory for new apps — Google re-signs your
app.** The fingerprint therefore comes from
**Play Console → Setup → App signing → App signing key certificate**,
*not* from your local keystore. Use the local one and the app opens with
a browser address bar across the top: working, but visibly not an app.

```json
[{
  "relation": ["delegate_permission/common.handle_all_urls"],
  "target": {
    "namespace": "android_app",
    "package_name": "com.faithdock.app",
    "sha256_cert_fingerprints": ["<from Play Console, colon-separated hex>"]
  }
}]
```

**Cloudflare Pages does serve dot-directories.** Measured, not assumed —
an empty `[]` placeholder was deployed and fetched back as
`content-type: application/json`, 3 bytes. That risk is closed.

**But do not check it by status code.** This site answers **200 to every
missing path**, because the SPA fallback returns `index.html` for
anything it does not recognise. A missing `assetlinks.json` therefore
comes back as 200 with 2.5MB of HTML, which every naive check passes and
Android's verifier quietly fails. Confirmed: a nonsense path returns
status 200 with `text/html`.

So verify the **content type**, never the status:

```bash
curl -s -o /dev/null -w 'status=%{http_code} type=%{content_type} bytes=%{size_download}\n' \
  https://faithdock.com/.well-known/assetlinks.json
```

`application/json` and a small byte count means it is really there.
`text/html` and a large one means it is not, whatever the status says.
The same trap applies to any "is this file deployed?" check on this
site.

## 4. Store listing

- Icon 512×512 — `icons/icon-512.png` already qualifies
- Feature graphic 1024×500 — **needs making**
- At least two phone screenshots
- Short and full description
- Privacy policy URL — the site already has one
- Content rating questionnaire
- Target audience and content

## 5. Data safety

Declare accurately: names, email addresses, approximate location, and
payment information are all collected. Giving and ticketing go through
Stripe. The privacy policy on the site is the reference; the form must
agree with it.

---

## Billing — what the code already does

Google requires **Play Billing** for digital subscriptions bought inside
an app, and takes 15–30%. The categories split:

| What | Play Billing? | FaithDock |
|---|---|---|
| Real-world event tickets | Not permitted | Stripe — unchanged |
| Donations | Exempt | Stripe — unchanged |
| **Church plan subscriptions** | **Required** | **Not sold in the app** |

`window.isAndroidAppShell()` detects the TWA — by an
`android-app://` referrer, by the `?shell=android` launch flag, and by a
`sessionStorage` note so a reload inside the app does not lose it.

When it is true:

- `html.fd-app-shell` is set, and CSS hides the three paid-plan buttons.
  A **class**, not JS setting `display` — `populatePricingPage()` re-runs
  on every route change, auth settle and language switch and relabels
  those same buttons each time.
- The plan cards themselves stay visible. A church should still be able
  to see what exists; only the buy action goes.
- `startPlanCheckout()` refuses before it can reach Stripe. The check is
  in that one function rather than on each button, because there are
  seven call sites including a resume-after-login path that fires with
  no click at all.

Verified in the browser: with the flag set, all three buttons are
`display:none`, the note appears, `startPlanCheckout('premium')` is
refused, and the Stripe function is never invoked.

**The wording is deliberately conservative.** "Plans are managed on the
FaithDock website" is a statement of fact, not an instruction to go and
pay elsewhere. Play's rules on steering users to outside payment have
been in flux — US courts have forced them open considerably — so this
may be relaxable later. It is not worth a rejection to find out.

---

## Updating, afterwards

- **Website change** → push to `main`. Live in the app immediately. No
  review, no release.
- **Shell change** (name, icon, package, target SDK) → new release
  through Play Console, with review.
- **Google raises the required target SDK annually.** An app that falls
  behind stops being distributable to new devices. This is the one piece
  of recurring maintenance a TWA adds, roughly once a year.

## Apple, for contrast

There is no TWA equivalent. Apple routinely rejects thin web wrappers
under guideline 4.2 (Minimum Functionality), and expects real native
integration. A separate and considerably harder project — and Apple's
billing rules for subscriptions are stricter, not looser.
