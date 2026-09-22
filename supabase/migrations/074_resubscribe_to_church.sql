-- Run in Supabase SQL Editor.
--
-- Letting somebody opt back in.
--
-- The unsubscribe page has been telling people "you can turn it back on
-- from your account settings at any time" since the day it shipped, and
-- there was no way to do that. This is the missing half.
--
-- It cannot be done from the client with a plain delete, which is the
-- whole reason it needs a migration. Migration 073 records an opt-out as
-- TWO rows -- one keyed by address, one by account -- so that it holds
-- whether the person is signed in or not, and survives them changing
-- their email. And get_mass_email_recipients (072) subtracts on BOTH.
--
-- The RLS delete policy from 069 is:
--
--     using (user_id = auth.uid())
--
-- which can never match the address row, because its user_id is NULL and
-- NULL = anything is NULL, not true. A client-side delete would therefore
-- remove the account row, clear the badge, look like it worked, and leave
-- the person silently unmailable forever. That is the same NULL trap as
-- the .neq('visibility','public') bug, in a place where the failure is
-- invisible to everyone involved.
--
-- So: a SECURITY DEFINER function that removes both rows together, and
-- decides which rows are "yours" itself rather than trusting a caller.

-- ---------------------------------------------------------------------
-- What have I unsubscribed from?
--
-- Needed as a function rather than a select, for the same NULL reason:
-- the SELECT policy only shows rows with user_id = auth.uid(), so a
-- person who unsubscribed from a link while signed out cannot see the
-- address row they created and would be told they are subscribed to
-- something they are not.
--
-- Returns one row per church even though two rows may exist for it,
-- because the person made one decision and should see one entry.
-- ---------------------------------------------------------------------
create or replace function my_email_optouts()
returns table (church_id uuid, church_name text, opted_out_at timestamptz)
language sql
security definer
set search_path = public
stable
as $fn$
  select o.church_id,
         c.name,
         min(o.opted_out_at)
  from church_email_optouts o
  join churches c on c.id = o.church_id
  where o.user_id = auth.uid()
     or (o.email is not null
         and auth.email() is not null
         and lower(o.email) = lower(auth.email()))
  group by o.church_id, c.name
  order by c.name;
$fn$;

-- ---------------------------------------------------------------------
-- Opt back in.
--
-- Takes only a church id. It does NOT take an email or a user id, and
-- that is the security design: the caller says which church, the
-- function decides which rows belong to the caller. A version that
-- accepted an address would let anyone resubscribe anyone.
--
-- Returns the number of rows removed, so the client can tell "you were
-- not opted out of this" from "done" without a second query.
-- ---------------------------------------------------------------------
create or replace function resubscribe_to_church(p_church_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_email text := auth.email();
  v_deleted integer;
begin
  -- Fails closed. Without this, a null uid would fall through to the
  -- delete below where every comparison is NULL and nothing matches --
  -- correct by accident, which is not the same as correct.
  if v_uid is null then
    raise exception 'Not signed in.' using errcode = '42501';
  end if;

  -- Both shapes, in one statement, so it is impossible to remove one and
  -- leave the other. An address match is safe because auth.email() is
  -- the confirmed address on the caller's own account: Supabase requires
  -- a clicked confirmation link before an email change takes effect, so
  -- it cannot be claimed by typing it.
  delete from church_email_optouts o
  where o.church_id = p_church_id
    and (
      o.user_id = v_uid
      or (o.email is not null and lower(o.email) = lower(v_email))
    );

  get diagnostics v_deleted = row_count;
  return v_deleted;
end
$fn$;

revoke all on function my_email_optouts() from public;
revoke all on function my_email_optouts() from anon;
grant execute on function my_email_optouts() to authenticated;

revoke all on function resubscribe_to_church(uuid) from public;
revoke all on function resubscribe_to_church(uuid) from anon;
grant execute on function resubscribe_to_church(uuid) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Verify. Raises rather than returning a report, so a half-applied
-- migration cannot be mistaken for a clean one.
-- ---------------------------------------------------------------------
do $verify$
begin
  if has_function_privilege('anon', 'my_email_optouts()', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon can execute my_email_optouts.';
  end if;
  if has_function_privilege('anon', 'resubscribe_to_church(uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon can execute resubscribe_to_church.';
  end if;

  if not has_function_privilege('authenticated', 'my_email_optouts()', 'EXECUTE') then
    raise exception 'VERIFY FAILED: a signed-in person cannot list their opt-outs.';
  end if;
  if not has_function_privilege('authenticated', 'resubscribe_to_church(uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: a signed-in person cannot opt back in.';
  end if;

  -- A second overload would make PostgREST ambiguous and break both
  -- callers at once, which is how the admin_update_church_details
  -- change went wrong in migration 071.
  if (select count(*) from pg_proc where proname = 'resubscribe_to_church') <> 1 then
    raise exception 'VERIFY FAILED: resubscribe_to_church is overloaded.';
  end if;
  if (select count(*) from pg_proc where proname = 'my_email_optouts') <> 1 then
    raise exception 'VERIFY FAILED: my_email_optouts is overloaded.';
  end if;

  -- The church side must still be unable to undo an opt-out. 069 granted
  -- staff SELECT only; if that ever became DELETE, a church could quietly
  -- resubscribe everyone who left.
  if has_table_privilege('authenticated', 'church_email_optouts', 'UPDATE') then
    raise exception 'VERIFY FAILED: opt-outs are editable, they should not be.';
  end if;

  raise notice 'OK: people can see and undo their own church email opt-outs.';
end
$verify$;
