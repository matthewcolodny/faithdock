-- Run in Supabase SQL Editor.
--
-- Every `revoke ... on function` written in 044, 049, 052 and 053 was
-- half a revoke, and the functions stayed callable by anon.
--
-- === Why ===
-- There are TWO independent grants of EXECUTE on a function here:
--   1. Postgres grants EXECUTE to PUBLIC on every new function, by
--      default and without being asked.
--   2. This project separately grants it to anon and authenticated,
--      the same default-privileges behaviour that made 049's column
--      grants a no-op.
-- Revoking from PUBLIC leaves grant 2. Revoking from anon leaves
-- grant 1, which anon inherits by being a role. Both have to go.
--
-- 044 revoked from anon only. 049, 052 and 053 revoked from public
-- only. Neither shape worked, and both looked like they had.
--
-- === Confirmed by calling them, not by reading the catalog ===
--   checkin_link_event_id('x')   -> 200 null   (granted to NOBODY)
--   can_run_event_checkin(...)   -> 200 false  (authenticated only)
--   can_read_contact_messages()  -> 200 false  (authenticated only)
--   set_registration_checked_in  -> executed, raised 'Not authenticated.'
-- all as anon, holding only the public publishable key.
--
-- === What was actually at risk: nothing, and that is the point ===
-- Every one of these guards itself. can_run_event_checkin and
-- can_read_contact_messages report on the CALLER, so for anon they
-- return false and cannot be used as an oracle about anyone else.
-- create_event_checkin_link and set_registration_checked_in raise
-- 'Not authenticated.' before doing anything. checkin_link_event_id
-- resolves a token the caller already holds, which checkin_link_open
-- would tell them anyway.
--
-- So this changes no behaviour. It is worth doing because the defence
-- everywhere was the function's own first line, while the migrations
-- claimed it was the grant -- and a defence that is believed to be in
-- two places but is really in one is how the second one gets removed
-- as redundant.

-- Internal helper: resolves a token to an event. Called only from
-- inside the two SECURITY DEFINER functions below, which run as their
-- owner, so nothing legitimate needs to call it directly.
revoke all on function checkin_link_event_id(text) from public, anon;

-- Caller-scoped predicates, used in policies that are already scoped
-- `to authenticated`.
revoke all on function can_run_event_checkin(uuid) from public, anon;
revoke all on function can_read_contact_messages(uuid) from public, anon;
grant execute on function can_run_event_checkin(uuid) to authenticated;
grant execute on function can_read_contact_messages(uuid) to authenticated;

-- Staff actions.
revoke all on function create_event_checkin_link(uuid, text, timestamptz) from public, anon;
grant execute on function create_event_checkin_link(uuid, text, timestamptz) to authenticated;

revoke all on function set_registration_checked_in(uuid, boolean) from public, anon;
grant execute on function set_registration_checked_in(uuid, boolean) to authenticated;

-- === Deliberately still callable by anon ===
-- checkin_link_open and checkin_link_mark ARE the account-less
-- check-in feature; a door volunteer has no session by design.
-- church_accepts_contact_messages is evaluated inside the anonymous
-- INSERT policy on contact_messages, and an RLS predicate runs as the
-- CALLING role -- revoke it from anon and every visitor message stops
-- being stored. Named here so a later pass does not "finish the job"
-- and break both features.

-- === Verify, from the catalog ===
-- has_function_privilege answers the question the migrations kept
-- getting wrong, and answers it about the role that actually matters
-- rather than about PUBLIC. Baked in because four migrations in a row
-- asserted this without checking it.
do $verify$
declare
  v_should_be_closed text[] := array[
    'checkin_link_event_id(text)',
    'can_run_event_checkin(uuid)',
    'can_read_contact_messages(uuid)',
    'create_event_checkin_link(uuid, text, timestamptz)',
    'set_registration_checked_in(uuid, boolean)'
  ];
  v_should_be_open text[] := array[
    'checkin_link_open(text)',
    'checkin_link_mark(text, uuid, boolean)',
    'church_accepts_contact_messages(uuid)'
  ];
  v_sig text;
  v_oid oid;
begin
  foreach v_sig in array v_should_be_closed loop
    v_oid := to_regprocedure(v_sig);
    if v_oid is null then
      raise exception 'VERIFY: % does not exist -- run its own migration first.', v_sig;
    end if;
    if has_function_privilege('anon', v_oid, 'EXECUTE') then
      raise exception 'VERIFY FAILED: anon can still execute %.', v_sig;
    end if;
  end loop;

  -- The other half of the assertion, and the one that keeps this from
  -- passing vacuously: if the revokes had gone too far, these three
  -- would be closed too and check-in links plus visitor messages
  -- would both be broken with nothing here complaining.
  foreach v_sig in array v_should_be_open loop
    v_oid := to_regprocedure(v_sig);
    if v_oid is null then
      raise exception 'VERIFY: % does not exist.', v_sig;
    end if;
    if not has_function_privilege('anon', v_oid, 'EXECUTE') then
      raise exception 'VERIFY FAILED: anon can NO LONGER execute %, which it needs.', v_sig;
    end if;
  end loop;

  raise notice 'OK: 5 functions closed to anon, 3 deliberately still open.';
end
$verify$;

notify pgrst, 'reload schema';
