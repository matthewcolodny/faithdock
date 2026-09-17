-- Run in Supabase SQL Editor.
--
-- Fixes a real, repeatedly-reported bug that took many rounds to pin
-- down: unregistering from an event silently did nothing. The button
-- flipped to "Register", the status message said "You've been
-- unregistered", and then a refresh showed the person still registered
-- -- because the registration row was never actually deleted, on any
-- attempt.
--
-- HOW THIS WAS NARROWED DOWN TO RLS SPECIFICALLY (not guessed):
--
-- 1. checkEventRegistrationStatus() runs
--      select status, role from event_registrations
--      where event_id = X and user_id = <me> limit 1
--    and FINDS the row -- that is the only reason the button ever says
--    "Registered" in the first place. So SELECT can see this row.
--
-- 2. The unregister handler runs
--      delete from event_registrations
--      where event_id = X and user_id = <me>
--    with the IDENTICAL where clause, and affects ZERO rows.
--
-- 3. It returns NO error. A missing table-level DELETE grant would
--    raise 42501 "permission denied for table event_registrations"
--    instead -- confirmed absent: the client fell through to its own
--    generic fallback message, which only happens when Postgres
--    returned no error at all.
--
-- Same row, same filters, visible to SELECT, silently not deletable,
-- no error raised. RLS is the only mechanism in Postgres that behaves
-- exactly that way -- it filters rows out of a statement's scope
-- rather than failing loudly. So event_registrations has RLS enabled
-- with working SELECT/INSERT policies but no matching DELETE policy
-- (and, by the same reasoning, very likely no UPDATE policy either --
-- see below). This table's original policies aren't in this repo (it
-- predates migration tracking, same gap as churches), so they can't be
-- read from here -- but a policy that doesn't exist can't conflict
-- with one that does, and Postgres OR's permissive policies together,
-- so adding these can only ever ADD the intended access, never narrow
-- whatever is already there. Same additive-policy reasoning migration
-- 029 already established for church_staff.
--
-- Client-side, the silent failure is now also caught properly (both
-- unregister paths check the row count returned by .select() rather
-- than assuming success) -- but that only makes the failure visible,
-- it can't grant the access. This migration is what actually fixes it.

-- === Unregistering: delete your own registration ===
-- Scoped to the row's own user_id, so this only ever lets someone
-- remove their OWN registration -- never anyone else's, and never
-- anything about an event they don't have a registration for.

drop policy if exists "Users can delete their own event registrations" on event_registrations;
create policy "Users can delete their own event registrations"
  on event_registrations for delete
  to authenticated
  using (user_id = auth.uid());

-- === Cancelling a PAID registration: update your own row ===
-- The paid path deliberately never deletes (that would erase the
-- payment record while the church keeps the money, with no trace) --
-- it sets status = 'cancelled' instead, which is an UPDATE and needs
-- its own policy. Both USING and WITH CHECK are scoped to user_id =
-- auth.uid(): USING controls which rows can be targeted, WITH CHECK
-- controls what they're allowed to become, so this also prevents
-- reassigning a registration to somebody else's user_id on the way
-- through.

drop policy if exists "Users can update their own event registrations" on event_registrations;
create policy "Users can update their own event registrations"
  on event_registrations for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- === Grants ===
-- Almost certainly already present (a missing grant would have raised
-- 42501 rather than silently affecting zero rows -- see the reasoning
-- above), but granted explicitly here so this migration doesn't depend
-- on that inference being right. Grants and RLS are separate gates:
-- both have to allow a statement, so stating both leaves nothing
-- assumed. Harmless to re-grant something already granted.

grant delete on event_registrations to authenticated;
grant update on event_registrations to authenticated;

notify pgrst, 'reload schema';
