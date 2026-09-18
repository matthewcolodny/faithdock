-- Run in Supabase SQL Editor.
--
-- Closes the one remaining user-reference column with no foreign key.
--
-- === How this was found ===
-- An audit of every uuid column in `public` that names a person: 30
-- columns, 29 constrained, one not. `message_batches.created_by` is the
-- exception, and both of its own siblings are constrained --
-- `scheduled_messages.created_by` references profiles ON DELETE SET
-- NULL, `message_drafts.created_by` references auth.users ON DELETE
-- CASCADE.
--
-- So this is an inconsistency rather than a hazard. Nothing is broken
-- today (orphan counts across every user-keyed table came back zero),
-- and the worst case is a sent-message record attributed to an id that
-- no longer resolves. It is worth closing anyway, because exactly one
-- hole in an otherwise uniform rule is the kind of thing that is
-- discovered later by surprise rather than by looking.
--
-- === SET NULL, matching scheduled_messages ===
-- A message batch is a record of something that was SENT. It should
-- outlive the account of whoever sent it, the same way donations and
-- event registrations already do -- the church's record of what went
-- out to its congregation does not stop being true because a staff
-- member closed their account.
--
-- That is why this follows `scheduled_messages.created_by` (profiles,
-- SET NULL) rather than `message_drafts.created_by` (auth.users,
-- CASCADE). A draft nobody can open again is fine to remove; a record
-- of a message that actually reached people is not.
--
-- References `profiles` rather than `auth.users` for the same reason
-- its sibling does: profiles.id already cascades from auth.users, so
-- the cleanup is equivalent, and matching the neighbouring column beats
-- introducing a second convention in one table's worth of code.

-- === Refuse to run rather than paper over damage ===
-- Same shape as 065's pre-check. Adding the constraint would fail on a
-- bad row anyway, but with a message that names a constraint instead of
-- the rows. These are message batches whose sender no longer exists --
-- harmless to null out, but it should be a decision that is seen.
do $precheck$
declare
  v_bad int;
begin
  select count(*) into v_bad
    from message_batches mb
    left join profiles p on p.id = mb.created_by
   where mb.created_by is not null and p.id is null;

  if v_bad > 0 then
    raise exception
      'STOPPED: % message batch(es) have a created_by that no longer exists. '
      'They are safe to clear -- run: update message_batches mb set created_by = null '
      'where mb.created_by is not null and not exists (select 1 from profiles p where p.id = mb.created_by); '
      '-- then re-run this migration.', v_bad;
  end if;

  raise notice 'OK: every message batch has a sender that still exists.';
end
$precheck$;

alter table message_batches drop constraint if exists message_batches_created_by_fkey;
alter table message_batches
  add constraint message_batches_created_by_fkey
  foreign key (created_by) references profiles(id)
  on delete set null;

notify pgrst, 'reload schema';

do $verify$
declare
  v_rule char;
begin
  select con.confdeltype into v_rule
    from pg_constraint con
   where con.conrelid = 'message_batches'::regclass
     and con.confrelid = 'public.profiles'::regclass
     and con.contype = 'f';

  if v_rule is null then
    raise exception 'VERIFY FAILED: the foreign key was not created.';
  end if;
  -- WHICH rule, not merely that one exists: CASCADE here would delete a
  -- church's record of a message it actually sent, which is the outcome
  -- this migration exists to avoid.
  if v_rule <> 'n' then
    raise exception 'VERIFY FAILED: ON DELETE is %, not SET NULL.', v_rule;
  end if;

  raise notice 'OK: message_batches.created_by now detaches instead of dangling.';
end
$verify$;
