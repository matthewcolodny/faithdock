# scripts/

One-off helper scripts. Not part of the deployed site (`index.html` /
`pure-logic.js`) and not run automatically.

## filter-churches.js

Splits a raw nonprofit-org extract (e.g. an IRS EO Business Master File
pull for a metro area or the whole state — columns: `name`,
`denomination`, `address`; `denomination` may be blank) into three files
using name-keyword rules, **before** `enrich-churches.js` ever runs:

```
node scripts/filter-churches.js input.csv [outputPrefix]
```

- `outputPrefix` defaults to `input.csv` without its extension, so
  `input.csv` → `input.clean.csv` / `input.excluded.csv` / `input.review.csv`.
- **Stage 1 (candidate?):** a row is a religious-org candidate if its name
  contains a religion keyword (`church`, `ministry`, `iglesia`, `baptist`,
  ...) or it already has a non-blank `denomination`. Everything else is
  **dropped** — not written to any file, since for a metro/statewide pull
  the overwhelming majority of rows have nothing to do with churches.
- **Stage 2 (what kind of candidate?):** `excluded.csv` for a confident
  non-congregation match (`school`, `foundation`, `endowment`, `trust`,
  `diocese`/`archdiocese`, `cemetery`, `insurance`, `credit union`,
  `seminary`, `booster club`, `alumni association`, `charities`/
  `charitable`, `capital campaign` — checked first, so it wins over
  review); `review.csv` for ambiguous entity-type words (`association`,
  `council`, `society`) that might be a single congregation or might be a
  denominational/parachurch body; everything else → `clean.csv`.
- **Every keyword check is word-boundary** (`\bministry\b`), never a
  plain substring check — the first, ad hoc San Antonio pass used
  substring matching and let "Resurrection Cemetery Administry Of The
  Cordi-Marian Sisters" in as a candidate because "Administry" contains
  "ministry". Re-validating the word-boundary version against San
  Antonio's actual triaged output turned up 2 more real instances of the
  same bug the old pass had gotten wrong silently ("Churchill" ≠
  `\bchurch\b`, "Templeton" ≠ `\btemple\b` — see the file's own header
  comment for the full story). Known trade-off in the other direction: a
  real church name that mashes the keyword into another word with no
  separator (`Rechurch210`, `...Familychurch`) won't match either, and
  gets dropped instead of landing in `clean.csv` — spot-check the dropped
  count on a new region rather than assuming 0 false negatives.
- `--selftest` (offline checks, including the Administry/Churchill/
  Templeton cases above).

## enrich-churches.js

Adds `phone` + `website` to a church CSV using the Google Places API,
with a `matched` flag, a `match_detail` note, and a `place_types` column
(Google's own category tags for the matched place, e.g. `church;
place_of_worship; point_of_interest`) for manual follow-up.

```
GOOGLE_PLACES_API_KEY=xxxxx  node scripts/enrich-churches.js input.csv [output.csv]
```

- Input CSV needs at least `name` and `address` columns (`denomination`
  and anything else is passed through). Output defaults to
  `input.enriched.csv`.
- Per row: parses a `City, ST` out of the address (the street / PO Box
  part is ignored), does a Places **Text Search** for `"{name}, {city},
  {state}"`, and only accepts the top result if the name is a close
  match *and* it's in the same state — then a Places **Details** call
  for `formatted_phone_number` / `website`. No confident match ⇒
  `phone`/`website` left blank, `matched = no`. It never guesses.
- `matched` values:
  - `yes` — confident match, place is operational
  - `closed` — confident match, but Places reports it `CLOSED_PERMANENTLY`.
    `phone`/`website` are still filled from the listing; review these
    before importing. (A *temporary* closure stays `yes`, noted in
    `match_detail`.) With `--drop-closed`, these rows are kept OUT of the
    main output and written to `<output>.closed.csv` for review instead.
  - `no` — no confident match; `phone`/`website` blank; `match_detail`
    says why (no state parsed / no results / low confidence + the
    rejected top result)
  - `skipped` — the row already had both `phone` and `website` (use
    `--force` to re-query)
- `place_types` — the matched place's Google types (e.g. `church`,
  `place_of_worship`), from the same Places Details call as `phone`/
  `website` (no extra API cost). Blank when `matched` is `no`/`skipped`.
  Use it to confirm a match is actually a church/place of worship, not
  just some business that happened to share a name.
- Needs the **legacy** "Places API" enabled in Google Cloud (not
  "Places API (New)") + billing on. `REQUEST_DENIED` means one of those.
- Node 18+ (uses global `fetch`).
- Flags: `--limit=N` (test on the first N rows), `--force` (re-query
  rows that already have phone + website), `--drop-closed` (divert
  permanently-closed matches to `<output>.closed.csv` so the main
  output is import-ready), `--selftest` (offline checks).
- Env: `NAME_SIM_THRESHOLD` (0–1, default 0.5), `DELAY_MS` (default 200).

## acronym-exceptions.js

A church name that's been title-cased (whatever pipeline does that --
there's no single shared title-caser in this repo today; the one that
originally ran on the San Antonio import was a one-off never committed
here) turns any all-caps acronym into a normal-looking word: `SATX` →
`Satx`, `UMC` → `Umc`. This file fixes that, two ways:

- **As a library** for any future import/cleanup script: `const {
  applyAcronymCasing } = require('./acronym-exceptions'); const fixed =
  applyAcronymCasing(name);`. `ACRONYM_EXCEPTIONS` is a flat array of
  uppercase strings -- add a new region's or denomination's acronym as a
  one-line edit, nothing else to touch. Every match is whole-word
  (`\bSATX\b`), never a substring check, for the same reason
  `filter-churches.js`'s keyword matching is (see that file's own header
  for the "Administry"/"Churchill" story).
- **As a one-off CLI audit** of the live database:
  ```
  node scripts/acronym-exceptions.js [--out=<path>] [--selftest]
  ```
  Fetches every current church name (read-only, via the same
  publishable/anon Supabase key already embedded in `index.html`),
  finds any acronym that isn't already in its canonical all-caps form,
  and writes a ready-to-run `.sql` correction file -- it never writes to
  the database itself. Default output is `acronym_casing_fixes.sql` in
  the current directory. `--selftest` runs the offline checks only, no
  network access.

## church-name-hygiene.js

Four unrelated live-data cleanups bundled into one scan, since they all
read the same live `name` column:

```
node scripts/church-name-hygiene.js [--out=<path>] [--selftest]
```

1. **TX casing** -- "Tx" → "TX". Delegated entirely to
   `acronym-exceptions.js`'s `applyAcronymCasing()` now that `TX` has
   been added to `ACRONYM_EXCEPTIONS` there -- not reimplemented here.
2. **Nonprofit hide** -- a name containing "nonprofit" / "non-profit" /
   "non profit" (e.g. "...a Domestic Nonprofit") is an IRS-extract
   artifact bleeding into the display name, not a real congregation
   name. These get **hidden** (`churches.is_hidden = true`, the same
   column `search_churches`/`search_events` already filter on per
   migrations 018/019) -- not deleted, reversible.
3. **Locator-suffix strip** -- a trailing " - City, TX"-style suffix
   (e.g. "360 Inner City Church - San Antonio Tx") is also
   import-artifact cruft and gets stripped back to the bare church name.
4. **Minor-word casing** -- the same title-casing pass that broke
   acronyms also over-capitalized short connector words that should
   stay lowercase mid-name ("Church Of San Antonio" → "Church of San
   Antonio"), except when the word is the first word of the name (a
   name genuinely starting with "At"/"Of" is left alone).

A name that still ends in "of"/"at" with nothing after it (after the
fixes above) looks like a truncated import missing its trailing city --
that's only flagged in its own section of the generated SQL as a
comment, never auto-fixed, since the script has no way to know what
actually belongs there.

Output is a single review-first `.sql` file in three sections (hides,
name fixes, truncation flags) with a before/after comment on every
line -- same "generate SQL, a human runs it by hand" convention as
every other script in this folder; this never writes to the database
directly. The locator-suffix regex can't always tell a real city from a
ministry descriptor after a dash, so the name-fix section specifically
needs a human read before running. `--selftest` runs the offline checks
only, no network access.
