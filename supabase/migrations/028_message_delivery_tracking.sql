-- Run in Supabase SQL Editor.
--
-- Adds delivery/open/click/bounce tracking for outbound church-owner
-- messages (mass announcements + individual directory messages, both of
-- which already flow through the same smooth-action "mass_email" path).
-- Two new tables:
--   message_batches -- one row per "send" action (one compose+send click),
--     whether it went to 40 people or 1.
--   message_log -- one row per individual recipient within a batch,
--     correlated back to Resend via resend_email_id (the id Resend's
--     send/batch-send API returns per email, same order as the request
--     array) so the resend-webhook edge function can update it later.
--
-- Status ladder on message_log.status: sent -> delivered -> opened ->
-- clicked. bounced_at / complained_at are separate terminal markers layered
-- on top rather than replacing status, since a bounce happens INSTEAD of
-- delivery (no forced "downgrade" of status needed -- a bounce just never
-- advances status past 'sent').
--
-- Renumbered from the requested 027 -- that number was already taken by
-- 027_denomination_pattern_gaps.sql, committed earlier today in this same
-- local session (the same disconnected-scratch-clone numbering collision
-- as that migration's own predecessor). This one is 028.

create table if not exists message_batches (
  id uuid primary key default gen_random_uuid(),
  church_id uuid not null references churches(id) on delete cascade,
  message_type text not null, -- 'mass_email' | 'individual'
  subject text,
  audience_label text,        -- human-readable snapshot, e.g. "All members (42)" or a person's name
  recipient_count int not null default 0,
  created_by uuid,            -- auth.uid() of the sending church owner; no FK (see churches.owner_id precedent)
  created_at timestamptz not null default now()
);

create table if not exists message_log (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references message_batches(id) on delete cascade,
  church_id uuid not null references churches(id) on delete cascade,
  resend_email_id text unique,
  recipient_email text not null,
  status text not null default 'sent',
  sent_at timestamptz not null default now(),
  resend_confirmed_at timestamptz, -- set from Resend's own email.sent webhook event, distinct from sent_at (which is just when OUR insert happened) -- confirms Resend's side actually accepted it into its send pipeline, not just that our HTTP call to them returned 200
  delivered_at timestamptz,
  first_opened_at timestamptz,
  last_opened_at timestamptz,
  open_count int not null default 0,
  clicked_at timestamptz,
  click_count int not null default 0,
  bounced_at timestamptz,
  bounce_reason text,
  complained_at timestamptz,
  updated_at timestamptz not null default now()
);

create index if not exists message_log_resend_email_id_idx on message_log (resend_email_id);
create index if not exists message_log_batch_id_idx on message_log (batch_id);
create index if not exists message_batches_church_id_idx on message_batches (church_id, created_at desc);

alter table message_batches enable row level security;
alter table message_log enable row level security;

-- Church owners AND staff can read their own church's send history --
-- same owner-or-staff idiom used consistently everywhere else in this
-- codebase (get_mass_email_recipients, get_directory_people, etc. --
-- see GOTCHAS.md), via the existing is_church_staff_member() helper.
-- Inserts/updates happen only from edge functions (service role), which
-- bypasses RLS entirely -- so no write policies are needed here.
create policy "Owner or staff can view their church's message batches"
  on message_batches for select
  using (
    exists (
      select 1 from churches
      where churches.id = message_batches.church_id
      and churches.owner_id = auth.uid()
    )
    or is_church_staff_member(message_batches.church_id)
  );

create policy "Owner or staff can view their church's message log"
  on message_log for select
  using (
    exists (
      select 1 from churches
      where churches.id = message_log.church_id
      and churches.owner_id = auth.uid()
    )
    or is_church_staff_member(message_log.church_id)
  );

-- Advances a message_log row's status/timestamps for one Resend webhook
-- event. Called by the resend-webhook edge function with the service role
-- key (bypasses RLS). Idempotent and safe against out-of-order delivery:
-- status only ever moves forward along sent -> delivered -> opened ->
-- clicked; open_count/click_count always accumulate regardless of order.
create or replace function apply_resend_webhook_event(
  p_resend_email_id text,
  p_event_type text,       -- 'email.sent' | 'email.delivered' | 'email.opened' | 'email.clicked' | 'email.bounced' | 'email.complained'
  p_event_at timestamptz
) returns boolean
language plpgsql
as $$
declare
  v_status_rank jsonb := '{"sent":0,"delivered":1,"opened":2,"clicked":3}'::jsonb;
begin
  if p_event_type = 'email.sent' then
    -- Doesn't move status (it's already 'sent' by default from the moment
    -- we insert the row) -- just records that Resend itself confirmed
    -- accepting this specific email into its pipeline.
    update message_log set
      resend_confirmed_at = coalesce(resend_confirmed_at, p_event_at),
      updated_at = now()
    where resend_email_id = p_resend_email_id;
  elsif p_event_type = 'email.delivered' then
    update message_log set
      status = case when (v_status_rank->>status)::int < (v_status_rank->>'delivered')::int then 'delivered' else status end,
      delivered_at = coalesce(delivered_at, p_event_at),
      updated_at = now()
    where resend_email_id = p_resend_email_id;
  elsif p_event_type = 'email.opened' then
    update message_log set
      status = case when (v_status_rank->>status)::int < (v_status_rank->>'opened')::int then 'opened' else status end,
      first_opened_at = coalesce(first_opened_at, p_event_at),
      last_opened_at = p_event_at,
      open_count = open_count + 1,
      updated_at = now()
    where resend_email_id = p_resend_email_id;
  elsif p_event_type = 'email.clicked' then
    update message_log set
      status = case when (v_status_rank->>status)::int < (v_status_rank->>'clicked')::int then 'clicked' else status end,
      clicked_at = coalesce(clicked_at, p_event_at),
      click_count = click_count + 1,
      updated_at = now()
    where resend_email_id = p_resend_email_id;
  elsif p_event_type = 'email.bounced' then
    update message_log set
      bounced_at = coalesce(bounced_at, p_event_at),
      updated_at = now()
    where resend_email_id = p_resend_email_id;
  elsif p_event_type = 'email.complained' then
    update message_log set
      complained_at = coalesce(complained_at, p_event_at),
      updated_at = now()
    where resend_email_id = p_resend_email_id;
  end if;

  return found;
end;
$$;

notify pgrst, 'reload schema';
