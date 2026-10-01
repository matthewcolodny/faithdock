# Handoff — importing scraped church data

For a session picking up the **data pipeline** on FaithDock: turning a
scrape into churches in the directory. It does not cover the app's UI;
that work stays with whoever has the full conversation and the local
memory for it.

Written 2026-10-01. If something here disagrees with the code, the code
is right — check the date and fix this file.

---

## The one thing to read first

**Every tool in `tools/` documents itself in its own header**, and those
headers carry real measurements, not descriptions. `prep-faithstreet.js`
opens with the actual coverage of the source (18,822 unique profiles,
96% with a street number, 84% with a denomination) and then explains the
two ways its denomination column lies. `enrich-batch.js` explains why it
runs before import rather than after.

Read the header of the tool you are about to run. It will usually
answer the question you were about to ask, and it reflects what the data
actually turned out to be rather than what anyone expected.

---

## The pipeline

```
scrape (CSVs)  ->  prep  ->  enrich  ->  import  ->  geocode (admin UI)
```

1. **Prep** — `tools/prep-texas.js`, `prep-churchfinder.js`,
   `prep-faithstreet.js`. One per source; all three emit the same batch
   shape so everything downstream is shared. Texas and ChurchFinder
   batch by ZIP3; FaithStreet has no ZIP, so it batches by city and
   splits the large ones.

2. **Enrich** — `tools/enrich-batch.js`. Looks each row up against
   Google Places and splits the batch four ways: `.yes.csv` (import
   this), `.no.csv`, `.type-mismatch.csv` (Google found something but
   does not call it a place of worship — **read these, do not import
   blind**), and `.enriched.csv` (everything, with the evidence).

   ```bash
   node tools/enrich-batch.js --file faithstreet-batches/<batch>.csv --limit 5
   ```

   **Always `--limit 5` first on a new batch.** `--dry-run` exercises
   the whole path with no network and no spend.

3. **Import** — the `.yes.csv` goes in through the admin UI, which
   records it as a named batch so it can be hidden or rolled back as a
   unit.

4. **Dedupe** — `tools/dedupe-against-live.js` before importing, so a
   second source does not re-add churches the first one already placed.

---

## Things that will cost money or time if you do not know them

**Geocoding is admin-triggered, not automatic.** Hiding churches saves
nothing; the per-visitor cost is map loads, not geocodes. Do not assume
hiding a batch reduces spend.

**`GOOGLE_PLACES_KEY` is a server key** and must stay out of the repo.
Set it in the environment for the run:

```bash
node tools/enrich-batch.js --file <batch> --limit 5
```

**The repo is public and Cloudflare Pages serves the root.** Every
generated data directory is gitignored for that reason — committing
`texas-batches/` would publish ~15,000 church records as downloadable
files on faithdock.com. The list is in `.gitignore`; do not add to it
without reading the comment above it.

**Never commit credentials.** The database password goes in the GitHub
secret box and nowhere else — not a file, not a commit, not a message.
`tools/check.js` fails the build if migration 097 contains a password
literal.

---

## Working with Supabase

**`supabase/migrations/` holds the SQL**, newest last. Run them by hand
in the Supabase SQL Editor.

**Probe before writing a migration.** Several tables predate this
folder and are undocumented, so the repo does not describe them
accurately. Migration 089 guessed and got five rules wrong; migration
118 nearly dropped the wrong function because the repo held *two*
definitions of `search_groups` and could not say which was live. Write a
read-only probe, run it, then write the migration against what came
back.

**The SQL Editor returns only the LAST statement's result.** A probe
written as several `select`s comes back answering only its final query,
silently discarding the rest. This cost three round trips on 2026-09-30.
Write a probe as **one** union-all'd select with a `section` text
column, casting every branch to text.

**`auth.uid()` is null in the SQL Editor**, so `is_platform_admin()` is
always false there and admin RPCs cannot be called. A verify block that
calls one proves nothing. Use catalog reads, or `set local role anon`
inside a `do $$` block to test what an anonymous visitor really sees.

**Give SQL in ```sql blocks, never ```bash.** A bash block renders with
a Run button and gets pasted straight into the SQL Editor, where `cat`
and `echo` are syntax errors.

---

## Conventions worth keeping

**Measure before naming a cause.** This is the single most useful habit
in this codebase. A long run of bugs here looked obvious and were not —
the cause was never where the code suggested. Get a number first.

**Take the removal, not the match.** When asked for one of something
that currently exists twice, delete the other rather than making the two
agree.

**Editing files with throwaway Node scripts:** write the script with the
file tools, not `node -e` inside a shell string. Backticks get
command-substituted and silently blank out part of the text; `\b` and
`\n` collapse to real control characters. Both fail quietly and look
like a bad anchor.

**Commit messages carry the reasoning.** `git log` is the most reliable
context transfer in this project — better than any summary, because it
is tied to the code and cannot drift. Keep writing the *why*, especially
when the cause was not where it looked.

---

## Where things live

| | |
|---|---|
| `index.html` | the whole app, ~50,000 lines — **do not edit from two sessions at once** |
| `pure-logic.js` | logic extracted for testing |
| `tools/` | the data pipeline, each file self-documenting |
| `supabase/migrations/` | SQL, run by hand, newest last |
| `tools/check.js` | run before every commit; also guards the password literal |

```bash
node tools/check.js
```

---

## Open, for whoever has the UI context

Not for a data session, listed so nothing looks forgotten: a set of
filter controls for the Events and Groups tabs, a followed-only filter,
and a user dashboard. Two reported issues are unreproduced locally — a
map flash on card tap, and a slow profile render — both needing a real
device, since Google Maps will not load on localhost.
