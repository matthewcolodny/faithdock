-- Run in Supabase SQL Editor.
--
-- Unsubscribing from a church's email, one church at a time.
--
-- Per-church rather than global, deliberately. FaithDock is a directory
-- of many churches, and "I left this church's mailing list" is a
-- different statement from "no church may ever email me". A global flag
-- would make leaving one list silently cancel every other, which is the
-- kind of surprise that ends in a spam report rather than a shrug.
--
-- The global case is still reachable: a person who wants nothing from
-- anyone opts out of each church they are on, or deletes their account
-- (see #data-deletion). If a single global switch is wanted later it
-- belongs in profiles as a separate, additional check -- not as a
-- replacement for this table.

create table if not exists church_email_optouts (
  id uuid primary key default gen_random_uuid(),
  church_id uuid not null references churches(id) on delete cascade,

  -- Either a signed-in user, or a bare address. Both exist in practice:
  -- a congregation import can hold an address that has never had an
  -- account, and that person still has to be able to unsubscribe from
  -- the link in the email they just received.
  user_id uuid references auth.users(id) on delete cascade,
  email text,

  -- Kept for the record a compliance question eventually asks: when,
  -- and by what route.
  opted_out_at timestamptz not null default now(),
  source text not null default 'link',

  -- One of the two identifiers must be present, and the pair is what
  -- makes a row meaningful. A row with neither would opt nobody out
  -- while looking like it had.
  constraint church_email_optouts_identifies_somebody
    check (user_id is not null or email is not null)
);

-- The lookups this table exists to serve: "is this person opted out of
-- this church" and "who is opted out of this church". Partial uniques
-- rather than one composite, because one of the two columns is always
-- null and a plain unique(church_id, user_id, email) would let the same
-- person be inserted repeatedly with the other column varying.
create unique index if not exists church_email_optouts_user_uniq
  on church_email_optouts (church_id, user_id) where user_id is not null;
create unique index if not exists church_email_optouts_email_uniq
  on church_email_optouts (church_id, lower(email)) where email is not null;
create index if not exists church_email_optouts_church_idx
  on church_email_optouts (church_id);

alter table church_email_optouts enable row level security;

-- === Policies ===
--
-- Three audiences: the person themselves, the church's own staff, and
-- the send path (which runs as service_role in an Edge Function and
-- bypasses RLS entirely -- it is not addressed here).

drop policy if exists "See your own opt-outs" on church_email_optouts;
create policy "See your own opt-outs"
  on church_email_optouts for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "Opt yourself out" on church_email_optouts;
create policy "Opt yourself out"
  on church_email_optouts for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists "Opt yourself back in" on church_email_optouts;
create policy "Opt yourself back in"
  on church_email_optouts for delete to authenticated
  using (user_id = auth.uid());

-- A church sees who on ITS list has opted out, so the messages area can
-- say so and stop counting them as reachable. Read only: a church must
-- never be able to delete somebody's opt-out and start mailing them
-- again, which is the whole point of the record.
drop policy if exists "Church staff can see their own opt-outs" on church_email_optouts;
create policy "Church staff can see their own opt-outs"
  on church_email_optouts for select to authenticated
  using (
    exists (select 1 from churches c where c.id = church_id and c.owner_id = auth.uid())
    or exists (select 1 from church_staff s where s.church_id = church_email_optouts.church_id and s.user_id = auth.uid())
  );

-- REVOKE FIRST. Default privileges in this project hand anon and
-- authenticated everything on a new public table, so the grants below
-- would otherwise add nothing and narrow nothing (see 049).
revoke all on church_email_optouts from anon;
revoke all on church_email_optouts from authenticated;
grant select, insert, delete on church_email_optouts to authenticated;

-- === The unsubscribe link's own path ===
--
-- Somebody clicking unsubscribe in an email is, more often than not,
-- not signed in -- and requiring a sign-in to stop receiving mail is
-- both hostile and, under CAN-SPAM, not a working opt-out.
--
-- SECURITY DEFINER so it can write a row for an address with no
-- account. It takes the address rather than reading auth.uid(), which
-- means the CALLER must already have proved they hold that address --
-- the Edge Function verifies a signed token from the email before
-- calling this. It is deliberately NOT granted to anon: an endpoint
-- that opts out any address on request is an endpoint for silencing
-- somebody else's mail.
create or replace function record_email_optout(
  p_church_id uuid,
  p_email text,
  p_user_id uuid default null,
  p_source text default 'link'
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if p_church_id is null or (p_email is null and p_user_id is null) then
    raise exception 'record_email_optout needs a church and either an email or a user';
  end if;

  if p_user_id is not null then
    insert into church_email_optouts (church_id, user_id, email, source)
    values (p_church_id, p_user_id, p_email, p_source)
    on conflict (church_id, user_id) where user_id is not null do nothing;
  else
    insert into church_email_optouts (church_id, email, source)
    values (p_church_id, p_email, p_source)
    on conflict (church_id, lower(email)) where email is not null do nothing;
  end if;
end
$fn$;

revoke all on function record_email_optout(uuid, text, uuid, text) from public;
revoke all on function record_email_optout(uuid, text, uuid, text) from anon;
revoke all on function record_email_optout(uuid, text, uuid, text) from authenticated;
-- service_role only: the Edge Function calls it after checking the
-- token. Nothing in the browser may.
grant execute on function record_email_optout(uuid, text, uuid, text) to service_role;

notify pgrst, 'reload schema';

do $verify$
begin
  if not exists (select 1 from information_schema.tables
                  where table_name = 'church_email_optouts') then
    raise exception 'VERIFY FAILED: church_email_optouts was not created.';
  end if;

  if has_table_privilege('anon', 'church_email_optouts', 'SELECT') then
    raise exception 'VERIFY FAILED: anon can read church_email_optouts.';
  end if;

  if not has_table_privilege('authenticated', 'church_email_optouts', 'INSERT') then
    raise exception 'VERIFY FAILED: a signed-in person cannot opt themselves out.';
  end if;

  -- A church reading its own opt-outs is the point; a church DELETING
  -- them is the thing that must not be possible.
  if has_table_privilege('authenticated', 'church_email_optouts', 'UPDATE') then
    raise exception 'VERIFY FAILED: opt-outs are editable, they should not be.';
  end if;

  if has_function_privilege('anon', 'record_email_optout(uuid, text, uuid, text)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon can execute record_email_optout.';
  end if;
  if has_function_privilege('authenticated', 'record_email_optout(uuid, text, uuid, text)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: authenticated can execute record_email_optout.';
  end if;

  raise notice 'OK: per-church email opt-outs are in place.';
end
$verify$;
