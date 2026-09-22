-- Run in Supabase SQL Editor. URGENT: fixes a live regression.
--
-- Public event browsing is broken, and I broke it.
--
-- faithdock.com/#events shows nothing to a signed-out visitor. The
-- console says:
--
--   permission denied for function staff_beyond_checkin
--   permission denied for table event_registrations
--
-- Two separate mistakes, from two migrations, with the same shape: I
-- revoked something from `anon` without checking what anon was using it
-- for.
--
-- ONE: migration 081 revoked EXECUTE on staff_beyond_checkin from anon,
-- then wrote it into the events SELECT policy. A policy is evaluated as
-- the caller, so a caller who cannot execute the function cannot read
-- the table at all -- not "sees fewer rows", but an error on every
-- query. The revoke looked obviously right (why would a signed-out
-- visitor need a staff helper?) and was obviously wrong for the reason
-- that matters: the function does not grant access, it ANSWERS A
-- QUESTION, and the question gets asked on behalf of everybody.
--
-- The answer for anon is false either way: auth.uid() is null, so no
-- church_staff row matches and the EXISTS is false. Granting execute
-- therefore gives away nothing. It only lets the policy finish.
--
-- TWO: migration 083 revoked SELECT on event_registrations from anon
-- while re-granting it column by column to `authenticated` -- and did
-- not re-grant anything to anon. search_events reads that table to
-- count spaces left, so the public events list died with it. anon had
-- table-level SELECT before 083, so this restores what it had, minus
-- the money columns, which is where it should have been all along.
--
-- THE LESSON, for the next revoke: `authenticated` and `anon` are two
-- roles, and a migration that carefully re-grants one of them has done
-- half a job. Nothing in 081 or 083 tested a signed-out page, which is
-- why both shipped.

-- ---------------------------------------------------------------------
-- One: let anon evaluate the staff helpers.
--
-- Not "let anon be staff". These return false for a caller with no
-- session, and are SECURITY DEFINER so they can read church_staff to
-- say so. Without EXECUTE the policy errors instead of answering.
-- ---------------------------------------------------------------------
grant execute on function staff_beyond_checkin(uuid) to anon;
grant execute on function is_checkin_only_staff(uuid) to anon;

-- ---------------------------------------------------------------------
-- Two: give anon back the registration columns it had, minus the money.
--
-- Same list as authenticated (migration 083). search_events counts
-- confirmed registrations to work out remaining capacity, which is a
-- public fact about a public event.
-- ---------------------------------------------------------------------
grant select (
  id,
  event_id,
  user_id,
  status,
  created_at,
  role,
  checked_in_at,
  guest_name,
  guest_email,
  guest_count,
  payment_status,
  stripe_checkout_session_id,
  discount_code_id
) on event_registrations to anon;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Verify. These assert the FIX, not the absence of the symptom -- the
-- symptom needs a signed-out browser, which SQL cannot be.
-- ---------------------------------------------------------------------
do $verify$
declare
  n_money int;
begin
  if not has_function_privilege('anon', 'staff_beyond_checkin(uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon still cannot evaluate staff_beyond_checkin, so the events policy still errors.';
  end if;
  if not has_function_privilege('anon', 'is_checkin_only_staff(uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon still cannot evaluate is_checkin_only_staff.';
  end if;

  -- The money must NOT have come back with the rest.
  select count(*) into n_money
  from information_schema.column_privileges
  where table_name = 'event_registrations'
    and grantee in ('anon', 'authenticated')
    and privilege_type = 'SELECT'
    and column_name in ('amount_paid_cents','discount_amount_cents',
                        'stripe_fee_cents','application_fee_cents','net_amount_cents');
  if n_money > 0 then
    raise exception 'VERIFY FAILED: % money column grant(s) present. 083 is undone.', n_money;
  end if;

  if not exists (
    select 1 from information_schema.column_privileges
    where table_name = 'event_registrations' and grantee = 'anon'
      and privilege_type = 'SELECT' and column_name = 'status'
  ) then
    raise exception 'VERIFY FAILED: anon cannot read registration status, so search_events still fails.';
  end if;

  raise notice 'OK: anon can evaluate the policy and count registrations, and still cannot read amounts.';
end
$verify$;
