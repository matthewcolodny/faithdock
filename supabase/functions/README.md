# Edge Functions

## Backed up here

- **`smooth-action.ts`** — the one consolidated email-sending
  function. Dispatches on `body.type`. Confirmed deployed and working
  as of 2026-09-09; this file is the exact live source.

## NOT backed up (source not available)

These functions exist and are referenced in GOTCHAS.md and the
client code, but their current source has never been captured in a
form that survived to this backup. **Do not guess at or recreate
their implementation** — ask the user to paste the current source
from the Edge Functions dashboard the next time one of these needs a
change, then add the real file here.

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
