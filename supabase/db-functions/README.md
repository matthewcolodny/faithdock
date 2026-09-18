# Database functions captured from the live database

`migrations/` holds SQL this project **wrote and ran**. This folder
holds SQL that was already **deployed** before it was ever tracked —
functions and tables created directly in the SQL editor in earlier
sessions, whose source existed nowhere but in Postgres.

Nothing here is a migration. Re-running these files would redefine
live functions from a snapshot that may be out of date. Read them; do
not paste them back in unless that is specifically the intent.

When a function in here needs to change, the change goes in a numbered
migration like anything else, and the header comment here gets a line
pointing at it.

## Captured

- **`church_ownership_handoff.sql`** — `accept_`/`decline_`/`cancel_church_ownership_handoff`.
  Captured 2026-09-18 via `pg_get_functiondef`. Migration 061 fixes the
  `accept_` path from the trigger side; see that file and GOTCHAS.md.

## Still not captured

Every RPC the client calls that has no definition in `migrations/`
and no file here. As of 2026-09-18 that is:

`compute_involvement_snapshot`, `find_church_people_by_email`,
`find_possible_duplicate_members`, `get_directory_people`,
`get_event_registration_counts`, `get_mass_email_recipients`,
`get_my_plan_and_usage`, `get_pending_verifications`,
`get_person_event_signups`, `get_person_giving_history`,
`get_person_group_signups`, `get_recent_client_errors`,
`get_user_id_by_email`, `is_platform_admin`,
`review_church_verification`, `search_events`, `update_profile_name`.

That list was produced by extracting every `rpc('...')` call from
`index.html` and checking each name against `migrations/`. Same rule as
the Edge Functions README: **do not guess at their bodies.** If one
needs changing, capture it first with

```sql
select pg_get_functiondef(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = '<name>';
```

then add it here before changing anything.
