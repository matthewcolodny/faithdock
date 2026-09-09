-- Run in Supabase SQL Editor.
--
-- New "coming soon" waitlist: a closable site-wide banner links to a
-- standalone promotional page (also meant to be linked directly, not
-- just reached through the banner) with an email signup form. This
-- creates the table it writes to, locks it down the same way every
-- other table this session was hardened (anyone can add themselves,
-- nobody can read the raw table -- only a platform-admin-gated RPC
-- can), and adds that RPC for the new "Waitlist signups" section on
-- the Admin page.

create table waitlist_signups (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  created_at timestamptz not null default now(),
  source text
);

-- Case-insensitive uniqueness -- the client already asks the user to
-- confirm they're new before treating a duplicate as an error, but a
-- unique index is the actual backstop against real duplicates (two
-- signups differing only in email case, a resubmitted form, etc).
create unique index waitlist_signups_email_unique on waitlist_signups (lower(email));

alter table waitlist_signups enable row level security;

-- Anyone -- including a signed-out visitor, which is the whole point
-- of a public signup page -- can add themselves. Column-scoped to
-- (email, source) only: id and created_at both have server-side
-- defaults and were never meant to be client-settable, so this also
-- means a crafted request can't backdate a signup or pick its own id.
create policy waitlist_signups_insert_anyone
  on waitlist_signups for insert
  to anon, authenticated
  with check (true);
revoke all on waitlist_signups from anon, authenticated;
grant insert (email, source) on waitlist_signups to anon, authenticated;

-- No SELECT grant at all for anon/authenticated -- same reasoning as
-- profiles/churches earlier this session: the raw table should never
-- be directly readable, even to a signed-in non-admin. The only way
-- to see the actual list of emails is this RPC, gated on
-- is_platform_admin() exactly like every other admin-only RPC in
-- this codebase.
create or replace function get_waitlist_signups()
returns table(email text, created_at timestamptz, source text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_platform_admin() then
    raise exception 'permission denied';
  end if;
  return query select w.email, w.created_at, w.source from waitlist_signups w order by w.created_at desc;
end;
$$;
grant execute on function get_waitlist_signups() to authenticated;
