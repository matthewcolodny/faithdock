-- Run in Supabase SQL Editor.
--
-- Adds fee tracking to both revenue tables so the dashboard's new
-- Revenue page (giving + ticket sales combined) can eventually show
-- net income, not just gross. NULL on existing/older rows is
-- expected and fine -- the dashboard treats NULL as "fee data not
-- captured for this transaction" and excludes it from net-income
-- sums rather than treating it as zero.

alter table donations
  add column if not exists stripe_fee_cents integer,
  add column if not exists application_fee_cents integer,
  add column if not exists net_amount_cents integer;

alter table event_registrations
  add column if not exists stripe_fee_cents integer,
  add column if not exists application_fee_cents integer,
  add column if not exists net_amount_cents integer;
