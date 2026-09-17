-- Run in Supabase SQL Editor.
--
-- Stores the messages visitors send from a church's public page, so a
-- church has an inbox instead of only an email that can be deleted,
-- filtered, or sent to whoever happened to hold the ability last year.
--
-- Today contact_church (smooth-action.ts) emails the owner plus any
-- staff with receives_contact_messages and keeps NOTHING. If Resend
-- drops one, or the recipient's spam filter does, the message is gone
-- and nobody knows it existed.
--
-- === Why the client inserts this rather than the edge function ===
-- The edge function would be the tidier home -- it already holds a
-- service-role client and already re-checks messaging_enabled. Two
-- things argue against putting it there FIRST: the function is
-- deployed by hand through the dashboard, which this repo cannot do
-- and which its own header warns never to guess the current source of;
-- and the trust level is identical either way, because the function is
-- invoked by the same anonymous browser holding the same public anon
-- key. Moving the insert server-side later changes nothing about who
-- can write here.
--
-- What the database must therefore enforce itself, since an anonymous
-- caller can skip the form entirely and POST straight to the REST
-- endpoint:
--   * messaging_enabled -- a church that turned messaging off must not
--     collect messages anyway
--   * a ceiling, so the inbox cannot be flooded
--   * sender_user_id, which the client must not be able to forge

create table if not exists contact_messages (
  id uuid primary key default gen_random_uuid(),
  church_id uuid not null references churches(id) on delete cascade,
  sender_name text,
  sender_email text not null,
  -- Set from auth.uid() by the trigger, never from the request. Null
  -- for a genuine visitor; present when a signed-in member wrote it,
  -- which tells staff they are answering someone they already know.
  sender_user_id uuid references auth.users(id) on delete set null,
  subject text not null,
  -- PLAIN TEXT, deliberately -- never HTML.
  --
  -- The sender is an anonymous stranger, and this is rendered in staff
  -- browsers. Storing their markup would be handing an unauthenticated
  -- party a path into the dashboard's DOM, which is the textbook shape
  -- of stored XSS and the exact bug already found twice in this app.
  -- The client escapes it and preserves line breaks with CSS instead,
  -- so there is no sanitiser to get wrong and no rich text to lose.
  body text not null,
  -- Read state is per CHURCH, not per person. This is a shared inbox:
  -- a message answered by one staff member is handled, and showing it
  -- as unread to everyone else invites three people replying to the
  -- same visitor. Per-person state would need its own join table and
  -- would model a mailbox nobody asked for.
  read_at timestamptz,
  read_by uuid references auth.users(id) on delete set null,
  archived_at timestamptz,
  created_at timestamptz not null default now()
);

-- The inbox lists one church's messages newest first, and filters
-- archived out; without this that is a sequential scan that gets
-- slower for every church as any other church receives mail.
create index if not exists contact_messages_church_created_idx
  on contact_messages (church_id, created_at desc);
-- Used by the rate ceiling below, which runs on every insert.
create index if not exists contact_messages_rate_idx
  on contact_messages (church_id, sender_email, created_at desc);

alter table contact_messages enable row level security;

-- === Helpers, SECURITY DEFINER on purpose ===
-- These read churches and church_staff from inside a policy. Doing it
-- with an inline subquery instead would put the reading role's own RLS
-- and COLUMN grants in the way -- and churches uses per-column grants,
-- so an anonymous visitor evaluating `messaging_enabled` directly would
-- hit 42501 and every message would be refused. A definer function
-- answers the one question the policy needs without granting the
-- caller anything.
create or replace function church_accepts_contact_messages(p_church_id uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $fn$
  -- Null when the church does not exist, which fails the WITH CHECK
  -- below and so doubles as an existence test. Coalesce covers rows
  -- predating migration 032, whose column default is true.
  select coalesce(c.messaging_enabled, true)
    from churches c
   where c.id = p_church_id;
$fn$;

-- Who may READ the inbox: the owner, plus staff holding the same
-- receives_contact_messages ability that already decides who is emailed
-- a copy. Reusing it keeps one switch meaning one thing.
--
-- The owner is included unconditionally, including when they have
-- turned owner_receives_messages off. That toggle is about their own
-- email, not about access -- an owner who does not want a copy in
-- their inbox still owns the church and can still open its mail.
create or replace function can_read_contact_messages(p_church_id uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $fn$
  select exists (
      select 1 from churches c
       where c.id = p_church_id and c.owner_id = auth.uid()
    ) or exists (
      select 1 from church_staff cs
       where cs.church_id = p_church_id
         and cs.user_id = auth.uid()
         and cs.receives_contact_messages = true
    );
$fn$;

revoke all on function church_accepts_contact_messages(uuid) from public;
revoke all on function can_read_contact_messages(uuid) from public;
grant execute on function church_accepts_contact_messages(uuid) to anon, authenticated;
grant execute on function can_read_contact_messages(uuid) to authenticated;

-- === Policies ===
-- Anonymous insert is intentional and is the whole feature: the people
-- writing to a church are visitors who do not have accounts. What the
-- policy withholds is everything else -- they cannot read a single row
-- back, including their own, so this is a write-only slot rather than
-- a public mailbox.
drop policy if exists "Visitors can send a church a message" on contact_messages;
create policy "Visitors can send a church a message"
  on contact_messages for insert to anon, authenticated
  with check (church_accepts_contact_messages(church_id) = true);

drop policy if exists "Church recipients can read messages" on contact_messages;
create policy "Church recipients can read messages"
  on contact_messages for select to authenticated
  using (can_read_contact_messages(church_id));

drop policy if exists "Church recipients can update messages" on contact_messages;
create policy "Church recipients can update messages"
  on contact_messages for update to authenticated
  using (can_read_contact_messages(church_id))
  with check (can_read_contact_messages(church_id));

drop policy if exists "Church recipients can delete messages" on contact_messages;
create policy "Church recipients can delete messages"
  on contact_messages for delete to authenticated
  using (can_read_contact_messages(church_id));

-- === Grants ===
-- Column-level on purpose, the same technique churches already uses.
-- RLS decides WHICH ROWS a statement may touch; it cannot say which
-- COLUMNS. Without this, the insert policy above would let an
-- anonymous caller post a message pre-marked as read and archived --
-- straight past the inbox, never seen by anyone.
grant insert (church_id, sender_name, sender_email, subject, body)
  on contact_messages to anon, authenticated;
grant select on contact_messages to authenticated;
-- Staff may change only the handled state, never rewrite what a
-- visitor actually said.
grant update (read_at, read_by, archived_at) on contact_messages to authenticated;
grant delete on contact_messages to authenticated;

-- === Ceiling and normalisation ===
-- Same reasoning as 041: the form's own validation is browser-side
-- politeness, skipped entirely by anyone calling the REST endpoint
-- directly with the public anon key, which is printed in the page
-- source by design. A trigger runs whichever policy allowed the row.
create or replace function enforce_contact_message_limits()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_recent integer;
  v_window constant interval := interval '1 hour';
  -- Two ceilings rather than one. A per-church limit alone lets a
  -- single sender exhaust it and silence everyone else writing to that
  -- church; a per-sender limit alone lets a thousand forged addresses
  -- bury the inbox. Each covers the other's blind spot.
  v_church_limit constant integer := 30;
  v_sender_limit constant integer := 5;
begin
  -- Truncate rather than reject, for 041's reason: a message that ran
  -- long is still a message somebody meant to send, and bounding the
  -- size is the goal -- losing it is not. 10k is far past any genuine
  -- note written into a contact form.
  new.sender_name  := left(coalesce(new.sender_name, ''), 120);
  new.sender_email := left(coalesce(new.sender_email, ''), 320);
  new.subject      := left(coalesce(new.subject, ''), 200);
  new.body         := left(coalesce(new.body, ''), 10000);

  if new.sender_email = '' or new.subject = '' or new.body = '' then
    raise exception 'CONTACT_MESSAGE_INCOMPLETE';
  end if;

  -- Never taken from the request. The insert grant does not include
  -- this column, so a caller cannot set it at all; this fills it in
  -- from the session the database already knows about.
  new.sender_user_id := auth.uid();

  -- Set here too, so the column grant does not have to include them
  -- and a caller cannot post a message that arrives pre-handled.
  new.read_at := null;
  new.read_by := null;
  new.archived_at := null;

  select count(*) into v_recent
    from contact_messages
   where church_id = new.church_id
     and created_at > now() - v_window;
  if v_recent >= v_church_limit then
    raise exception 'CONTACT_MESSAGE_RATE_LIMIT';
  end if;

  select count(*) into v_recent
    from contact_messages
   where church_id = new.church_id
     and lower(sender_email) = lower(new.sender_email)
     and created_at > now() - v_window;
  if v_recent >= v_sender_limit then
    raise exception 'CONTACT_MESSAGE_RATE_LIMIT';
  end if;

  return new;
end;
$fn$;

drop trigger if exists contact_messages_limits on contact_messages;
create trigger contact_messages_limits
  before insert on contact_messages
  for each row execute function enforce_contact_message_limits();

notify pgrst, 'reload schema';

-- === Retention ===
-- Deliberately NOT automated here. These rows hold a member of the
-- public's name, email address and free text, so how long they are
-- kept is a decision for the church, not a default this migration
-- should quietly make on their behalf. Staff can delete any message,
-- and archiving keeps the list short without discarding anything.
-- If an automatic purge is wanted later it belongs in its own
-- migration, with the window chosen on purpose.
