# Database functions captured from the live database

`migrations/` holds SQL this project **wrote and ran**. This folder
holds SQL that was already **deployed** before it was ever tracked —
functions created directly in the SQL editor in earlier sessions, whose
source existed nowhere but in Postgres.

Nothing here is a migration. Re-running these files would redefine live
functions from a snapshot that may be out of date. Read them; do not
paste them back in unless that is specifically the intent.

When a function in here needs to change, the change goes in a numbered
migration like anything else, and the header comment here gets a line
pointing at it.

## Captured

- **`church_ownership_handoff.sql`** — `accept_`/`decline_`/`cancel_church_ownership_handoff`.
  Captured 2026-09-18. Migration 061 fixes the `accept_` path from the
  trigger side.
- **`captured_2026-09-18.sql`** — the sixteen other RPCs the client
  calls that had no source in this repo. Its header records six
  findings from reading them; two became migrations (062) or GOTCHAS
  entries.

## Nothing is uncaptured

As of 2026-09-18, every RPC the client invokes and every helper those
RPCs call has its source in this repo -- `captured_2026-09-18.sql`,
`helpers_captured_2026-09-18.sql`, `church_ownership_handoff.sql`, or
a numbered migration.

Table definitions are still untracked for anything created before
migrations started -- `church_ownership_handoffs`, `plan_tiers`,
`involvement_snapshots` and others. Foreign key rules in particular
are not recorded anywhere, and at least one of them matters: see the
header of `../functions/delete-account.ts`.

## How the gap was found

Every `rpc('...')` name was extracted from `index.html` and checked
against `migrations/`. Seventeen had no source; sixteen came back from
`pg_get_functiondef`. The seventeenth, `get_person_group_signups`,
**did not exist at all** — the client had been calling a function that
was never created, swallowing the error and rendering an empty state.
Created by migration 062.

Worth repeating that check after any batch of RPC work: a name the
client calls that the database does not have fails quietly if the call
site tolerates an empty result.
