-- Run in Supabase SQL Editor.
--
-- An email address for someone added at the check-in desk.
--
-- A walk-in is currently stored as a name and nothing else, so the
-- person who showed up on a Sunday is a row nobody can ever follow up
-- with -- which is the opposite of why a church runs a check-in desk.
--
-- === No grant statement here, deliberately ===
-- Every reflex from 049-054 says to write one. It would do nothing.
-- event_registrations already carries table-wide privileges for the
-- roles that use it, so a new column is reachable by exactly whoever
-- could already reach guest_name, and a GRANT naming this column
-- would add nothing while implying a narrowing that is not happening.
-- Writing a privilege statement that reads as protection but isn't is
-- the specific mistake 049 made; not writing one is the fix.
--
-- What actually governs this column is unchanged and already correct:
-- the RLS policies on event_registrations, and the fact that the
-- account-less check-in roster (checkin_link_open, migration 052)
-- selects an explicit column list that does not and must not include
-- it. A door volunteer holding a shared link sees names; a signed-in
-- staff member sees the contact details. That distinction is the
-- whole point of 052 and this column must not quietly undo it.

alter table event_registrations add column if not exists guest_email text;

comment on column event_registrations.guest_email is
  'Optional contact address for a walk-in added at the check-in desk. Never returned by checkin_link_open() -- see migration 052.';

notify pgrst, 'reload schema';
