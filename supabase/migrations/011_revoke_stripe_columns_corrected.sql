-- Run in Supabase SQL Editor.
--
-- The previous migration (revoke select (col1, col2) on churches ...)
-- did NOT actually work -- verified live, stripe_customer_id and
-- stripe_subscription_id are still fully readable anonymously after
-- running it. Reason: Supabase grants blanket table-level SELECT to
-- anon/authenticated by default on every table (relying on RLS for
-- row-level restriction, not columns). A narrower column-level REVOKE
-- doesn't override an existing table-level GRANT -- Postgres checks
-- "does this role have table-wide SELECT?" first, and that wins
-- regardless of what's revoked at the column level underneath it.
--
-- Correct fix: revoke the table-wide SELECT entirely, then grant
-- SELECT back only on the explicit list of columns that should stay
-- public (everything except the two Stripe subscription-billing
-- ids). This does NOT touch INSERT/UPDATE/DELETE privileges (those
-- are separate privilege types) -- the register-church form's direct
-- insert/update calls are unaffected.

revoke select on churches from anon, authenticated;

grant select (
  id, owner_id, name, description, address, city, state, created_at,
  denomination, website, logo_url, lat, lng, phone, facebook_url,
  instagram_url, stripe_account_id, stripe_onboarding_complete,
  verification_status, verification_requested_at, verification_reviewed_at,
  plan_type, subscription_status, current_period_end, dedupe_key,
  service_times, cancel_at_period_end
) on churches to anon, authenticated;
