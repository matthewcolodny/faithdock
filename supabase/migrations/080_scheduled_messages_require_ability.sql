-- Run in Supabase SQL Editor.
--
-- Sending to the congregation requires the messaging ability.
--
-- The policy on scheduled_messages was ALL, membership only:
--
--     <church owner> OR is_church_staff_member(church_id)
--
-- So any staff member could schedule mail to the whole congregation
-- regardless of can_manage_messages. The client hides the Messages page
-- without that ability, which made it look governed; it governed a nav
-- link.
--
-- This is the worst of the write gaps found in the audit
-- (docs/staff-permission-audit.md) for reasons that have nothing to do
-- with how easy it is to exploit. It is outward-facing: the result is
-- mail arriving in members' inboxes with the church's name on it. It is
-- effectively irreversible once sent. And the people it reaches have no
-- way to tell it was not authorised.
--
-- can_manage_messages is the same ability the client already uses to
-- decide whether to show the Messages page at all, so nobody who could
-- legitimately reach this feature loses anything.

do $preflight$
declare
  n_affected int;
begin
  select count(*) into n_affected
  from church_staff s
  where coalesce(s.can_manage_messages, false) = false;

  raise notice 'Staff without can_manage_messages, who lose scheduled-message access: %', n_affected;
end
$preflight$;

drop policy if exists "owner or staff can manage their church's scheduled messages" on scheduled_messages;

create policy "owner or staff can manage their church's scheduled messages"
  on scheduled_messages for all
  using (
    exists (
      select 1 from churches c
      where c.id = scheduled_messages.church_id and c.owner_id = auth.uid()
    )
    or exists (
      select 1 from church_staff s
      where s.church_id = scheduled_messages.church_id
        and s.user_id = auth.uid()
        and coalesce(s.can_manage_messages, false)
    )
  )
  -- WITH CHECK as well as USING, and they must match. USING decides
  -- which rows you may see and modify; WITH CHECK decides what a row is
  -- allowed to look like afterwards. A FOR ALL policy with only USING
  -- lets somebody insert a row for a church they have no rights to,
  -- because there is no existing row for USING to test.
  with check (
    exists (
      select 1 from churches c
      where c.id = scheduled_messages.church_id and c.owner_id = auth.uid()
    )
    or exists (
      select 1 from church_staff s
      where s.church_id = scheduled_messages.church_id
        and s.user_id = auth.uid()
        and coalesce(s.can_manage_messages, false)
    )
  );

do $verify$
declare
  n_policies int;
  src_using  text;
  src_check  text;
begin
  select count(*) into n_policies
  from pg_policy where polrelid = 'scheduled_messages'::regclass;
  if n_policies <> 1 then
    raise exception 'VERIFY FAILED: scheduled_messages has % policies; expected 1. Extra policies are OR-ed and would re-open this.', n_policies;
  end if;

  select pg_get_expr(polqual, polrelid), pg_get_expr(polwithcheck, polrelid)
  into src_using, src_check
  from pg_policy where polrelid = 'scheduled_messages'::regclass;

  if src_using not like '%can_manage_messages%' then
    raise exception 'VERIFY FAILED: USING does not check can_manage_messages.';
  end if;
  if src_check is null then
    raise exception 'VERIFY FAILED: no WITH CHECK -- inserts would be unguarded.';
  end if;
  if src_check not like '%can_manage_messages%' then
    raise exception 'VERIFY FAILED: WITH CHECK does not check can_manage_messages.';
  end if;

  raise notice 'OK: scheduling a message to a church now requires owning it or holding can_manage_messages.';
end
$verify$;
