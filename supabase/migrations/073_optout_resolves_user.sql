-- Run in Supabase SQL Editor. Requires 069.
--
-- record_email_optout resolves the account itself.
--
-- 069 took p_user_id from the caller, which meant the unsubscribe Edge
-- Function had to look the address up first -- and it cannot: auth.users
-- is not reachable from a supabase-js client, service role or not,
-- without a function like this one. So the lookup moves in here, where
-- auth.users IS readable, and the caller passes only what it actually
-- knows: a church and an address.
--
-- Why record both when an account exists: an opt-out tied only to an
-- address lapses the moment that person changes their email, and one
-- tied only to a user id misses the imported address that has no
-- account. Recording whichever apply is what makes the check in
-- get_mass_email_recipients, which tests both, able to find it.

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
declare
  resolved_user_id uuid;
begin
  if p_church_id is null or (p_email is null and p_user_id is null) then
    raise exception 'record_email_optout needs a church and either an email or a user';
  end if;

  -- Caller's value wins when given; otherwise look it up. Case-folded,
  -- because an address typed into a form and one stored at signup
  -- differ in case more often than anyone expects.
  resolved_user_id := p_user_id;
  if resolved_user_id is null and p_email is not null then
    select u.id into resolved_user_id
      from auth.users u
     where lower(u.email) = lower(p_email)
     limit 1;
  end if;

  -- The address row: recorded whenever we have an address at all, even
  -- if an account was also found. It is what a future re-import or a
  -- change of address still matches on.
  if p_email is not null then
    insert into church_email_optouts (church_id, email, source)
    values (p_church_id, lower(p_email), p_source)
    on conflict (church_id, lower(email)) where email is not null do nothing;
  end if;

  -- And the account row, so the opt-out survives them changing address.
  if resolved_user_id is not null then
    insert into church_email_optouts (church_id, user_id, source)
    values (p_church_id, resolved_user_id, p_source)
    on conflict (church_id, user_id) where user_id is not null do nothing;
  end if;
end
$fn$;

revoke all on function record_email_optout(uuid, text, uuid, text) from public;
revoke all on function record_email_optout(uuid, text, uuid, text) from anon;
revoke all on function record_email_optout(uuid, text, uuid, text) from authenticated;
grant execute on function record_email_optout(uuid, text, uuid, text) to service_role;

notify pgrst, 'reload schema';

do $verify$
begin
  if has_function_privilege('anon', 'record_email_optout(uuid, text, uuid, text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'record_email_optout(uuid, text, uuid, text)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: record_email_optout is callable from the browser.';
  end if;

  if (select count(*) from pg_proc where proname = 'record_email_optout') <> 1 then
    raise exception 'VERIFY FAILED: record_email_optout is not a single function.';
  end if;

  raise notice 'OK: record_email_optout now resolves the account from the address.';
end
$verify$;
