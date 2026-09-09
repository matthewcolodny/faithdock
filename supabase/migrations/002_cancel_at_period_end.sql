-- Run in Supabase SQL Editor before deploying the updated
-- stripe-subscription / stripe-subscription-webhook functions.
--
-- Lets the Billing panel show "your plan ends on <date>, then moves
-- to Free" for a church that requested the downgrade-to-Free flow,
-- rather than looking identical to a normal active paid plan until
-- the moment it actually lapses.

alter table churches add column if not exists cancel_at_period_end boolean not null default false;
