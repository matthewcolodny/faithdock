-- Run in Supabase SQL Editor.
--
-- Fixes a regression introduced by 051.
--
-- === What broke ===
-- accept_church_ownership_handoff() does exactly one thing to the
-- church row:
--     update churches set owner_id = auth.uid() where id = h.church_id;
-- and auth.uid() there is the RECIPIENT. SECURITY DEFINER changes the
-- privileges a function runs with; it does NOT change auth.uid(), which
-- still reads the caller's JWT.
--
-- 051's trigger then asks:
--     auth.uid() is null?          no  -- a real signed-in recipient
--     old.owner_id is null?        no  -- the church has an owner
--     auth.uid() = old.owner_id?   no  -- the recipient is not the old owner
-- and falls through to `new.owner_id := old.owner_id`.
--
-- So the transfer is silently reverted, the function then marks the
-- handoff 'accepted' and (with keep_as_staff) inserts the OLD owner into
-- church_staff. The church still belongs to whoever owned it, who is now
-- also listed as their own staff, and the handoff row is consumed so it
-- cannot be retried. Nothing raises.
--
-- 051 was right about the hole it closed -- a permitted staff editor
-- really could PATCH owner_id onto themselves. It was wrong to assume
-- that every owner_id change by a non-owner is an attack. Exactly one
-- is not: the handoff the current owner started on purpose.
--
-- === Why the exemption is checked here rather than trusted ===
-- accept_church_ownership_handoff() already verifies the handoff is
-- pending and addressed to the caller's email. This re-derives the same
-- facts instead of taking the function's word for it, because the
-- trigger also fires for ordinary client PATCHes, where there is no
-- function to have checked anything. The exemption has to hold up on
-- its own or it is just a hole with extra steps:
--   * a handoff row for THIS church
--   * still 'pending' (accept marks it accepted afterwards, so it is
--     still pending while this trigger runs)
--   * addressed to the email of the user the row is being handed TO
--   * and that user is the caller
-- Miss the email check and a staff member could hijack any transfer in
-- flight by PATCHing owner_id onto themselves during the pending window.

-- SECURITY DEFINER is new here, and it is what makes the email check
-- possible: auth.users is not readable by `authenticated`, and this
-- trigger fires on every client update to churches. Without it the
-- lookup below would raise permission denied and take down every
-- ordinary church edit. The body only reads and assigns -- it performs
-- no privileged write -- and search_path stays pinned.
create or replace function pin_church_ownership_and_billing()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_handoff_ok boolean := false;
begin
  if auth.uid() is null then return new; end if;
  if old.owner_id is null then return new; end if;
  if auth.uid() = old.owner_id then return new; end if;

  -- The one legitimate reason a non-owner changes owner_id.
  if new.owner_id is distinct from old.owner_id and new.owner_id = auth.uid() then
    select exists (
      select 1
        from church_ownership_handoffs h
        join auth.users u on lower(u.email) = lower(h.to_email)
       where h.church_id = old.id
         and h.status = 'pending'
         and u.id = auth.uid()
    ) into v_handoff_ok;
  end if;

  if v_handoff_ok then
    -- Ownership passes. Billing does NOT: the Stripe ids on this row
    -- still point at the previous owner's customer and subscription,
    -- and an accept must not be a way to rewrite them. Whether a
    -- transfer should also move billing is a real question, and it is
    -- not answered by letting the recipient set those columns freely.
    new.id                         := old.id;
    new.created_at                 := old.created_at;
    new.plan_type                  := old.plan_type;
    new.subscription_status        := old.subscription_status;
    new.current_period_end         := old.current_period_end;
    new.cancel_at_period_end       := old.cancel_at_period_end;
    new.stripe_customer_id         := old.stripe_customer_id;
    new.stripe_subscription_id     := old.stripe_subscription_id;
    new.stripe_account_id          := old.stripe_account_id;
    new.stripe_onboarding_complete := old.stripe_onboarding_complete;
    new.dedupe_key                 := old.dedupe_key;
    new.import_batch_id            := old.import_batch_id;
    new.import_source_filename     := old.import_source_filename;
    return new;
  end if;

  -- Unchanged from 051 for every other caller. Silent restore rather
  -- than an exception: the UI never sends these columns, so anything
  -- arriving here is either a bug or somebody probing the API, and
  -- neither is owed an error naming the field that almost worked.
  new.id                         := old.id;
  new.owner_id                   := old.owner_id;
  new.created_at                 := old.created_at;

  new.plan_type                  := old.plan_type;
  new.subscription_status        := old.subscription_status;
  new.current_period_end         := old.current_period_end;
  new.cancel_at_period_end       := old.cancel_at_period_end;
  new.stripe_customer_id         := old.stripe_customer_id;
  new.stripe_subscription_id     := old.stripe_subscription_id;
  new.stripe_account_id          := old.stripe_account_id;
  new.stripe_onboarding_complete := old.stripe_onboarding_complete;

  new.dedupe_key                 := old.dedupe_key;
  new.import_batch_id            := old.import_batch_id;
  new.import_source_filename     := old.import_source_filename;

  return new;
end;
$fn$;

-- The trigger itself is unchanged; recreated so this migration is
-- complete on its own rather than depending on 051 having run.
drop trigger if exists churches_pin_ownership_billing on churches;
create trigger churches_pin_ownership_billing
  before update on churches
  for each row execute function pin_church_ownership_and_billing();

notify pgrst, 'reload schema';

do $verify$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'pin_church_ownership_and_billing'
       and p.prosecdef
  ) then
    raise exception 'VERIFY FAILED: the trigger function is not SECURITY DEFINER, so the auth.users lookup would fail for ordinary client updates.';
  end if;

  if not exists (
    select 1 from pg_trigger
     where tgname = 'churches_pin_ownership_billing' and not tgisinternal
  ) then
    raise exception 'VERIFY FAILED: the trigger is missing, so ownership and billing are unguarded.';
  end if;

  raise notice 'OK: ownership stays pinned, except for a pending handoff addressed to the caller.';
end
$verify$;

-- === Did any transfer already fail this way? ===
-- A handoff marked accepted whose church did NOT end up owned by the
-- recipient. Every row this returns is a church somebody believes they
-- handed over and still owns.
--
-- Read-only. It changes nothing.
select h.id            as handoff_id,
       c.name          as church,
       h.to_email      as intended_new_owner,
       c.owner_id      as actual_owner_id,
       u.id            as intended_owner_id,
       h.responded_at
  from church_ownership_handoffs h
  join churches c on c.id = h.church_id
  left join auth.users u on lower(u.email) = lower(h.to_email)
 where h.status = 'accepted'
   and (u.id is null or c.owner_id is distinct from u.id)
 order by h.responded_at desc;

-- If that returned rows, each one needs a decision rather than a bulk
-- UPDATE: the intended recipient may no longer want it, and the row's
-- keep_as_staff insert already happened. To complete one deliberately,
-- after checking the church and the person are still the right ones:
--
--   update churches c
--      set owner_id = u.id
--     from church_ownership_handoffs h
--     join auth.users u on lower(u.email) = lower(h.to_email)
--    where h.id = '<handoff_id from the list above>'
--      and c.id = h.church_id;
--
-- Run as the table owner in the SQL editor, where auth.uid() is null
-- and the trigger returns early. Check afterwards that the previous
-- owner's church_staff row is what you want -- accept() inserted one
-- when keep_as_staff was set, and it survived even though the
-- ownership change did not.
