-- Run in Supabase SQL Editor.
--
-- churches.plan_type has a check constraint that was never updated
-- when the Starter tier was added -- every write of plan_type =
-- 'starter' has been silently rejected by Postgres ever since (both
-- stripe-subscription's confirm_subscription and
-- stripe-subscription-webhook's syncFromSubscription call
-- supabaseAdmin.from('churches').update(...) without checking the
-- returned `error`, so the rejection never surfaced anywhere -- the
-- functions kept reporting success regardless).
--
-- First, confirm this is really the constraint and see its current
-- definition (informational only, not required to fix anything):
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--   where conrelid = 'churches'::regclass and conname = 'churches_plan_type_check';

alter table churches drop constraint if exists churches_plan_type_check;
alter table churches add constraint churches_plan_type_check
  check (plan_type in ('free', 'starter', 'standard', 'premium', 'multi_church'));

-- Fixes the specific test row from this conversation, since its
-- webhook update already fired and was silently rejected -- it won't
-- retry on its own now that the constraint is fixed.
update churches
set plan_type = 'starter', subscription_status = 'active'
where id = '3ebef06e-eb4a-4674-a232-6c80abfa5683';
