-- CAPTURED FROM THE LIVE DATABASE, 2026-09-18. Not a migration.
--
-- These three functions and the church_ownership_handoffs table they
-- use were created directly in the SQL editor before this repo started
-- tracking migrations, so nothing in migrations/ creates them. They are
-- recorded verbatim here because a fix to any of them should start from
-- what is actually deployed, not from a reconstruction.
--
-- Verbatim output of:
--   select pg_get_functiondef(p.oid) from pg_proc p
--     join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname in ('accept_church_ownership_handoff',
--                        'decline_church_ownership_handoff',
--                        'cancel_church_ownership_handoff');
--
-- === Known issues in what is deployed ===
--
-- 1. accept() was broken by migration 051 and is repaired by 061 --
--    from the trigger side, not by changing this function. The update
--    below runs as the RECIPIENT (SECURITY DEFINER does not change
--    auth.uid()), and 051's pin trigger silently reverted owner_id
--    while accept() went on to mark the handoff 'accepted'. See 061.
--
-- 2. accept() does not touch billing. plan_type and the Stripe ids stay
--    on the church row pointing at the PREVIOUS owner's customer and
--    subscription, so the old owner keeps paying for a church they gave
--    away. That is an open product question, not a bug this file
--    settles.
--
-- 3. The church_staff insert writes only (church_id, user_id), by the
--    original author's stated choice, so the previous owner is kept on
--    with whatever that table's column defaults are -- not with the
--    abilities an owner had.
--
-- 4. Nothing here expires a pending handoff. A request sits pending
--    until accepted, declined or cancelled.

CREATE OR REPLACE FUNCTION public.accept_church_ownership_handoff(handoff_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  h record;
  my_email text;
begin
  select email into my_email from auth.users where id = auth.uid();
  select * into h from church_ownership_handoffs where id = handoff_id;

  if h is null then
    raise exception 'This transfer request no longer exists.';
  end if;
  if h.status <> 'pending' then
    raise exception 'This transfer request is no longer pending.';
  end if;
  if my_email is null or lower(h.to_email) <> lower(my_email) then
    raise exception 'This transfer request was not addressed to you.';
  end if;

  update churches set owner_id = auth.uid() where id = h.church_id;

  -- Minimal columns only (church_id, user_id) — deliberately not
  -- guessing at church_staff's full permission-flag column set here.
  -- If this table has other required columns without defaults,
  -- this will fail with a clear error naming the missing column
  -- rather than silently inserting wrong data — safer to surface
  -- that than to guess.
  if h.keep_as_staff and not exists (select 1 from church_staff where church_id = h.church_id and user_id = h.from_user_id) then
    insert into church_staff (church_id, user_id) values (h.church_id, h.from_user_id);
  end if;

  update church_ownership_handoffs set status = 'accepted', responded_at = now() where id = handoff_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_church_ownership_handoff(handoff_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  h record;
begin
  select * into h from church_ownership_handoffs where id = handoff_id;
  if h is null then
    raise exception 'This transfer request no longer exists.';
  end if;
  if not exists (select 1 from churches c where c.id = h.church_id and c.owner_id = auth.uid()) then
    raise exception 'Only the current owner can cancel this.';
  end if;
  update church_ownership_handoffs set status = 'cancelled', responded_at = now() where id = handoff_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.decline_church_ownership_handoff(handoff_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  h record;
  my_email text;
begin
  select email into my_email from auth.users where id = auth.uid();
  select * into h from church_ownership_handoffs where id = handoff_id;
  if h is null or h.status <> 'pending' then
    raise exception 'This transfer request is no longer pending.';
  end if;
  if my_email is null or lower(h.to_email) <> lower(my_email) then
    raise exception 'This transfer request was not addressed to you.';
  end if;
  update church_ownership_handoffs set status = 'declined', responded_at = now() where id = handoff_id;
end;
$function$;
