-- Run in Supabase SQL Editor. This fixes the live "Could not find the
-- 'suggested_donation_cents' column of 'events' in the schema cache"
-- error when publishing/saving an event.
--
-- Root cause: two client-side features shipped with a "requires a
-- one-time SQL migration" note in GOTCHAS.md, but the SQL was never
-- actually run against the live database and never captured here:
--   * "Suggested donations for free events" -> events.suggested_donation_cents
--   * "New pricing model / pass-absorb fee choice" -> events.fee_mode
-- The create/edit-event form now always sends both columns in its
-- insert/update payload, so every publish attempt fails at PostgREST
-- before it reaches the table.
--
-- Written idempotently (add column if not exists + guarded
-- constraints) so it's safe to run even if one of the two columns
-- was partially applied at some point.

alter table events
  add column if not exists suggested_donation_cents integer,
  add column if not exists fee_mode text not null default 'pass';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'events_suggested_donation_cents_check'
  ) then
    alter table events add constraint events_suggested_donation_cents_check
      check (suggested_donation_cents is null or suggested_donation_cents > 0);
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'events_fee_mode_check'
  ) then
    alter table events add constraint events_fee_mode_check
      check (fee_mode in ('pass', 'absorb'));
  end if;
end $$;

-- Force PostgREST to pick up the new columns immediately rather than
-- waiting for its periodic schema-cache refresh.
notify pgrst, 'reload schema';
