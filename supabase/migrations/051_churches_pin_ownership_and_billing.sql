-- Run in Supabase SQL Editor.
--
-- Closes a privilege escalation on churches found while auditing the
-- column grants 049 got wrong.
--
-- === The hole ===
-- The policy "owner and permitted staff can update their church" is:
--     USING      can_edit_church_profile(id)
--     WITH CHECK can_edit_church_profile(id)
-- and `authenticated` holds TABLE-WIDE update on churches, so no
-- column privilege narrows it. Nothing in that WITH CHECK pins
-- owner_id, so a staff member granted "Edit church profile" could
--     PATCH /rest/v1/churches?id=eq.<id>  {"owner_id": "<themselves>"}
-- and the check still passes -- they remain a permitted editor of the
-- row, now as its owner. plan_type and the Stripe/subscription
-- columns are open the same way: a free church could put itself on a
-- paid tier without a payment.
--
-- Confirmed structurally from pg_policies and
-- information_schema.table_privileges. NOT confirmed by performing
-- the escalation, which would have meant taking over a real church.
--
-- === Why a trigger rather than tightening the policy ===
-- RLS chooses ROWS, not COLUMNS -- the same limit that made 049's
-- grants a no-op. A WITH CHECK can compare against the new row but
-- cannot see the old one, so "owner_id must not change" is not
-- expressible there. This codebase already settled the question:
-- prevent_self_verification() is a BEFORE UPDATE trigger guarding
-- verification_status on this exact table, for this exact reason.
--
-- === Why the pin is scoped to non-owner callers ===
-- stripe-subscription writes plan_type, subscription_status and
-- current_period_end, and its source is NOT in this repo (see
-- supabase/functions/README.md, which says not to guess at it). So
-- this deliberately does not pin those columns against every caller:
--   * no auth.uid() at all -> service role or a webhook, left alone,
--     which is how Stripe state is expected to arrive
--   * the row's own owner -> left alone, so an owner-initiated
--     billing action cannot break on a function nobody here can read
--   * old.owner_id is null -> an unclaimed church, left alone so
--     review_church_claim() (007) can still assign an owner. Such a
--     church has no owner and therefore no staff, so nothing can
--     reach this branch to abuse it.
-- Everything else is a permitted STAFF editor, which is exactly the
-- case that was exposed.
create or replace function pin_church_ownership_and_billing()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $fn$
begin
  if auth.uid() is null then return new; end if;
  if old.owner_id is null then return new; end if;
  if auth.uid() = old.owner_id then return new; end if;

  -- Silent restore rather than an exception. The UI never sends these
  -- columns, so anything arriving here is either a bug or somebody
  -- probing the API, and neither is owed an error message naming the
  -- field that almost worked.
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

  -- Import bookkeeping: how a directory row got here is a fact about
  -- the import, not something a church edits about itself.
  new.dedupe_key                 := old.dedupe_key;
  new.import_batch_id            := old.import_batch_id;
  new.import_source_filename     := old.import_source_filename;

  return new;
end;
$fn$;

-- Named so it sorts beside enforce_verification_review, which guards
-- the other set of columns on this table that staff must not set.
drop trigger if exists churches_pin_ownership_billing on churches;
create trigger churches_pin_ownership_billing
  before update on churches
  for each row execute function pin_church_ownership_and_billing();

notify pgrst, 'reload schema';

-- === Left alone on purpose, so the next reader does not assume it
-- was missed ===
-- is_hidden stays editable by a permitted staff editor. Hiding a
-- church from the directory is disruptive but reversible and
-- immediately visible to the owner, unlike a silent change of
-- ownership or billing tier. Widening this trigger to cover it is a
-- separate decision about what "Edit church profile" should mean,
-- not part of closing an escalation.
