# Supabase backup

FaithDock's live database (Postgres/RLS/RPCs) and Edge Functions live
entirely in the Supabase dashboard — this project has no
`supabase` CLI project, no migration runner, and no deploy pipeline
connecting this repo to Supabase. Nothing here runs automatically;
it's a **reference backup** so a fix doesn't require re-pasting
source from scratch, and so history (including superseded/failed
attempts) survives between chat sessions.

For the narrative behind every change — what was broken, how it was
found, why the fix looks the way it does — see [`GOTCHAS.md`](../GOTCHAS.md)
in the repo root. This folder holds the verbatim SQL/TypeScript;
GOTCHAS.md holds the reasoning.

## Layout

- `migrations/` — every SQL statement run against the database this
  project has a saved copy of, numbered roughly in the order it was
  run. Some are marked `SUPERSEDED`/`FAILED_ATTEMPT` — they're real
  history (what actually shipped first, including a couple of
  fixes-that-didn't-work), not dead weight to delete. When a table or
  function was touched more than once, the **highest-numbered** file
  covering it is the current live definition.
- `functions/` — Edge Function source. Only functions whose current
  source has actually been pasted into a chat session and read are
  backed up here; see `functions/README.md` for what's covered and
  what isn't.

## Keeping this in sync

There is no automation enforcing this — it relies on discipline each
session:

1. **Never guess at a Supabase-side object's current implementation.**
   If a function isn't backed up here (or might have drifted from
   what's here), ask for its current source from the dashboard before
   editing it.
2. After changing anything Supabase-side (a new RPC, an edited Edge
   Function, an RLS policy), add or update the matching file here in
   the same commit as the client-side change, numbered after the
   last migration.
3. If a fix supersedes an earlier file, mark the earlier one
   `SUPERSEDED` in its own header comment (don't delete it) and say
   so in the new file, the way `011_revoke_stripe_columns_corrected.sql`
   documents superseding `010_..._FAILED_ATTEMPT.sql`.

## Known gaps (source not available as of 2026-09-09)

These Supabase-side objects are referenced in GOTCHAS.md and/or the
client code but their current source has never been pasted into a
chat session in a way that's still available — do **not** assume
their behavior or recreate them from memory. Ask the user to paste
current source from the dashboard before touching any of these:

- Edge Function `stripe-subscription`
- Edge Function `stripe-subscription-webhook`
- Edge Function `stripe-connect-onboarding`
- Edge Function `stripe-create-checkout`
- Edge Function `stripe-event-checkout`
- Edge Function `delete-account`
- Edge Function `ai-writing-assist`
- RPC `is_platform_admin()` (behavior is well understood and relied
  upon throughout `migrations/`, but its own body was never pasted —
  every migration here treats it as an existing black box)
- RPC `update_profile_name()` (referenced in
  `012b_harden_profiles_table.sql` as already existing and unaffected
  by that migration, but its body isn't backed up here)
- RPC `get_directory_people()` / `find_church_people_by_email()` /
  `get_mass_email_recipients()` / `is_church_staff_member()` —
  referenced by name in `migrations/` as existing, already-audited
  helpers; none of their bodies are backed up here
