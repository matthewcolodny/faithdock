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
