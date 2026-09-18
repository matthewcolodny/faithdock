# Edge Functions

## Backed up here

- **`smooth-action.ts`** — the one consolidated email-sending
  function. Dispatches on `body.type`. Confirmed deployed and working
  as of 2026-09-09; this file is the exact live source.

**Added 2026-09-18** (pasted from the dashboard by the user):

- **`stripe-subscription.ts`** — checkout, billing portal, cancel, and
  the redirect-back confirmation for FaithDock own plans.
- **`stripe-subscription-webhook.ts`** — the authoritative sync from
  Stripe into `churches`. This is the file that answers "what happens
  when a church stops paying": `past_due` counts as ACTIVE, so the paid
  plan is kept until Stripe itself cancels the subscription. FaithDock
  has no grace period of its own; it inherits Stripe retry schedule.

`stripe-create-checkout.ts` and `stripe-event-checkout.ts` were checked
against what is deployed on the same date and still match.

- **`delete-account.ts`** — added 2026-09-18. Deletes the calling
  user via the admin API. Its header records a gap it does NOT fix:
  the owns-a-church check exists only in the browser.

## NOT backed up (source not available)

These functions exist and are referenced in GOTCHAS.md and the
client code, but their current source has never been captured in a
form that survived to this backup. **Do not guess at or recreate
their implementation** — ask the user to paste the current source
from the Edge Functions dashboard the next time one of these needs a
change, then add the real file here.

**Standing, low-priority intent (confirmed with the user 2026-09-09):**
don't wait for a change to force this — if the user happens to have
any of these open in the Supabase dashboard for an unrelated reason,
it's worth asking them to paste it in so the backup can be completed
opportunistically, even though the pasted copy may drift from live
after the fact (better a possibly-slightly-stale copy than nothing).
Not urgent enough to interrupt other work for.

- `stripe-subscription` — creates/confirms platform subscriptions;
  writes `churches.plan_type`/`subscription_status`/
  `current_period_end` and (post `001_church_billing_table.sql`)
  should also write `church_billing`.
- `stripe-subscription-webhook` — Stripe webhook handler; syncs
  subscription state via `syncFromSubscription`, same tables as
  above.
- `stripe-connect-onboarding` — Stripe Connect onboarding for a
  church's own giving/ticketing payouts.
- `stripe-create-checkout` — creates a Stripe Checkout session
  (donations/ticketed events).
- `stripe-event-checkout` — event-ticket-specific checkout variant.
- `delete-account` — account deletion flow.
- `ai-writing-assist` — AI writing-assistance feature (used
  somewhere in the rich-text/description-writing flow).
