-- Run in Supabase SQL Editor.
--
-- Fixes: a Premium church owner still gets sent to /pricing when they
-- click "Add a church", instead of being allowed up to 5.
--
-- Root cause was two layers of design drift:
--
--   1. get_my_plan_and_usage() resolved the caller's plan from
--      profiles.plan_type -- but nothing maintains that column. The
--      whole Stripe subscription system (stripe-subscription-webhook)
--      treats churches.plan_type as the source of truth, and it is
--      correct (the owner's church is 'premium'); their profile row
--      is still 'free' and always would be.
--
--   2. plan_tiers had drifted to an older tier naming
--      (free/starter/growth/multi_church/enterprise) with no row for
--      'standard' or 'premium' at all -- the names the live
--      churches.plan_type CHECK constraint and the client actually use
--      (free/starter/standard/premium/multi_church). So the "5
--      churches" entitlement had nowhere to live.
--
-- Fix, no Edge Function change needed (churches.plan_type is already
-- right):
--
--   * Add the missing 'standard' / 'premium' rows to plan_tiers, with
--     premium.max_churches = 5. Purely additive -- the legacy
--     'growth'/'enterprise' rows are left untouched in case anything
--     still references them.
--   * Multi-Church becomes truly unlimited (max_churches NULL) per
--     product decision.
--   * Rewrite get_my_plan_and_usage() to derive the caller's plan from
--     the churches they OWN (highest tier among them -- churches.plan_type,
--     the real source of truth), dropping the profiles.plan_type +
--     stale-plan_tiers-name dependency entirely. This matches how the
--     rest of the app already reasons about plan (myChurch.planType ->
--     the client's hardcoded planLimits) and correctly handles an owner
--     of several churches. Only max_churches / churches_owned are
--     actually consumed by callers; the other returned columns are
--     kept in the signature for compatibility but are cosmetic.
--
-- Not addressed here (separate, non-blocking drift): plan_tiers'
-- per-tier event/group/staff numbers and monthly_price_cents don't all
-- match the client's own pricing copy ($19 vs 1500, etc). Nothing
-- reads those fields from this RPC, so reconciling them is left for a
-- deliberate pricing pass rather than rushed in here.

insert into plan_tiers
  (plan_type, display_name, max_churches, max_events_per_month, max_groups,
   max_staff, has_full_analytics, has_ai_copy_help, monthly_price_cents, sort_order)
values
  ('standard', 'Standard', 1, 50, 12, 8,   true, true, 3900, 6),
  ('premium',  'Premium',  5, 75, 30, null, true, true, 7900, 7)
on conflict (plan_type) do update set
  display_name        = excluded.display_name,
  max_churches        = excluded.max_churches,
  max_events_per_month = excluded.max_events_per_month,
  max_groups          = excluded.max_groups,
  max_staff           = excluded.max_staff,
  has_full_analytics  = excluded.has_full_analytics,
  has_ai_copy_help    = excluded.has_ai_copy_help;

-- Multi-Church: unlimited churches (was a hard 10).
update plan_tiers set max_churches = null where plan_type = 'multi_church';

create or replace function public.get_my_plan_and_usage()
 returns table(plan_type text, display_name text, max_churches integer,
   max_events_per_month integer, max_groups integer, max_staff integer,
   has_full_analytics boolean, has_ai_copy_help boolean, churches_owned bigint)
 language sql
 security definer
as $function$
  with owned as (
    select c.plan_type,
           case c.plan_type
             when 'multi_church' then 5
             when 'premium'      then 4
             when 'standard'     then 3
             when 'starter'      then 2
             else 1
           end as rank
    from churches c
    where c.owner_id = auth.uid()
  ),
  effective as (
    select coalesce(
      (select o.plan_type from owned o order by o.rank desc limit 1),
      'free'
    ) as plan_type
  )
  select
    pt.plan_type, pt.display_name, pt.max_churches, pt.max_events_per_month,
    pt.max_groups, pt.max_staff, pt.has_full_analytics, pt.has_ai_copy_help,
    (select count(*) from churches c where c.owner_id = auth.uid()) as churches_owned
  from effective e
  join plan_tiers pt on pt.plan_type = e.plan_type;
$function$;

notify pgrst, 'reload schema';
