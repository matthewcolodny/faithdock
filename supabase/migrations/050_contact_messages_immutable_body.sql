-- Run in Supabase SQL Editor.
--
-- Corrects a wrong assumption in 049.
--
-- 049 wrote `grant insert (church_id, ...)` and `grant update
-- (read_at, read_by, archived_at)` as though naming columns would
-- NARROW what the roles could touch. It does not. A GRANT only ever
-- adds, and this project hands anon and authenticated privileges on
-- new public tables by default -- so contact_messages was created
-- already carrying SELECT, INSERT and UPDATE on every column, and
-- 049's grants were a no-op re-statement of a subset of that.
--
-- Confirmed from information_schema.column_privileges, not assumed:
-- both roles hold UPDATE on body, subject and sender_email.
--
-- What was NEVER actually exposed, despite 049 crediting the wrong
-- mechanism: an anonymous caller cannot post a message pre-marked as
-- read, because the BEFORE INSERT trigger nulls read_at, read_by and
-- archived_at and sets sender_user_id from auth.uid() regardless of
-- what the request contains. Also unaffected: anon still cannot read,
-- update or delete anything, because no anon policy exists for those
-- commands and RLS is what refuses them.
--
-- What WAS exposed: a staff recipient could rewrite the body, subject
-- or sender address of a message sent to their own church. Not a
-- cross-tenant hole, but the wrong property to lose -- a contact
-- message can be a complaint or a safeguarding concern, and one that
-- is silently editable by the person it concerns is worth less than
-- no record at all.

-- === 1. Actually narrow the privileges ===
-- REVOKE first. This is the step 049 was missing, and the reason
-- naming columns in a GRANT looked like it had worked.
revoke insert, update on contact_messages from anon;
revoke insert, update on contact_messages from authenticated;
revoke select, delete on contact_messages from anon;

grant insert (church_id, sender_name, sender_email, subject, body)
  on contact_messages to anon, authenticated;
grant update (read_at, read_by, archived_at)
  on contact_messages to authenticated;

-- Anon loses SELECT entirely, so "a visitor cannot read the inbox" is
-- a privilege, not merely the absence of a policy someone could add
-- later by accident. The client's insert does not read anything back
-- (no .select() on that call), so nothing needs it.

-- === 2. A trigger, because grants on this project are not where the
-- enforcement should live ===
-- The revoke above is correct and should stay. But the whole reason
-- this migration exists is that a privilege on this table did not
-- behave the way the person writing it expected, and the same default
-- grant that caused it will apply to the next table too. 041 settled
-- this argument already: a trigger runs regardless of which policy or
-- privilege allowed the statement.
--
-- So what a visitor actually wrote is pinned here as well. Silently,
-- by restoring the old values rather than raising: the UI never tries
-- to change these columns, so anything reaching this branch is either
-- a bug or someone poking at the API, and neither deserves an error
-- message explaining which field to try next.
create or replace function pin_contact_message_content()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  new.id             := old.id;
  new.church_id      := old.church_id;
  new.sender_name    := old.sender_name;
  new.sender_email   := old.sender_email;
  new.sender_user_id := old.sender_user_id;
  new.subject        := old.subject;
  new.body           := old.body;
  new.created_at     := old.created_at;

  -- read_by is not free-form either: it records WHO read it, so
  -- taking the caller's word for it would let one person's name be
  -- written against another's action. Same reasoning as
  -- sender_user_id on insert.
  if new.read_at is distinct from old.read_at and new.read_at is not null then
    new.read_by := auth.uid();
  elsif new.read_at is null then
    new.read_by := null;
  else
    new.read_by := old.read_by;
  end if;

  return new;
end;
$fn$;

drop trigger if exists contact_messages_pin_content on contact_messages;
create trigger contact_messages_pin_content
  before update on contact_messages
  for each row execute function pin_contact_message_content();

notify pgrst, 'reload schema';
