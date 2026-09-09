-- Run in Supabase SQL Editor before deploying the edge functions.
--
-- Deliberately a SEPARATE table from `churches`, not two new columns
-- on it. `churches` is read with select('*') from several places the
-- public can reach (e.g. findOrFetchChurchByName() on the church
-- detail page) -- putting Stripe customer/subscription ids directly
-- on that table would leak them to anyone viewing a church's page.
-- plan_type / subscription_status / current_period_end are NOT
-- touched here -- they already exist on `churches` and are already
-- intentionally public (loadBillingPanel() and the giving-fee check
-- both already depend on that).

create table if not exists church_billing (
  church_id uuid primary key references churches(id) on delete cascade,
  stripe_customer_id text,
  stripe_subscription_id text,
  updated_at timestamptz not null default now()
);

alter table church_billing enable row level security;

-- Only a church's own owner may ever read its billing row from the
-- client. There is deliberately no insert/update/delete policy for
-- anon or authenticated -- every write happens through
-- stripe-subscription / stripe-webhook, both of which use the
-- service-role key and so bypass RLS entirely.
create policy "Church owner can read own billing row"
  on church_billing for select
  to authenticated
  using (
    exists (
      select 1 from churches
      where churches.id = church_billing.church_id
        and churches.owner_id = auth.uid()
    )
  );

-- Keeps updated_at honest on every service-role upsert.
create or replace function church_billing_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_church_billing_updated_at on church_billing;
create trigger trg_church_billing_updated_at
  before update on church_billing
  for each row execute function church_billing_set_updated_at();
