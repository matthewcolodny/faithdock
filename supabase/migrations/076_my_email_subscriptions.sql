-- Run in Supabase SQL Editor.
--
-- The whole picture of who may email you, not just who may not.
--
-- Migration 074 gave people a way to undo an opt-out, which fixed the
-- broken promise on the unsubscribe page. But it only ever listed the
-- churches somebody had ALREADY left, so the page answered "what have I
-- turned off" and never "what is turned on". Somebody wondering why they
-- get mail from a church, or wanting to stop before the next send rather
-- than after it, had nowhere to go: unsubscribing still required waiting
-- for an email and clicking the link in it.
--
-- So this lists every church that can currently reach you, whether each
-- one is on or off, and why it can reach you at all -- and adds the
-- matching "turn it off" function so both directions live in one place.

-- ---------------------------------------------------------------------
-- Who can email me, and why.
--
-- The four audiences mirror get_mass_email_recipients (migration 072)
-- exactly: members, staff (including the owner), group members, event
-- registrants. They have to agree -- a list that claims a church cannot
-- reach you when it can is worse than no list, because it is a specific
-- false assurance rather than an absence.
--
-- Churches with only an opt-out row are included too, with a null
-- reason. Somebody who left a church and unsubscribed still needs the
-- row there to turn it back on, and dropping it the moment the
-- membership ended would strand them.
-- ---------------------------------------------------------------------
create or replace function my_email_subscriptions()
returns table (church_id uuid, church_name text, reason text, opted_out boolean)
language sql
security definer
set search_path = public
stable
as $fn$
  with me as (
    select auth.uid() as uid, auth.email() as em
  ),
  -- Every route by which a church's mailing list can include this
  -- person. Deliberately `union all` plus a rank below rather than
  -- `union`: somebody is often both a member and a group member, and we
  -- want the most explanatory reason, not an arbitrary one.
  sources as (
    select c.id as church_id, 'staff'::text as reason
      from churches c cross join me
      where me.uid is not null and c.owner_id = me.uid
    union all
    select s.church_id, 'staff'::text
      from church_staff s cross join me
      where me.uid is not null and s.user_id = me.uid
    union all
    select cm.church_id, 'member'::text
      from church_memberships cm cross join me
      where me.uid is not null and cm.user_id = me.uid
        and cm.is_permanent = true and cm.status = 'approved'
    union all
    select g.church_id, 'group'::text
      from group_members gm
      join groups g on g.id = gm.group_id
      cross join me
      where me.uid is not null and gm.user_id = me.uid and gm.status = 'active'
    union all
    select e.church_id, 'event'::text
      from event_registrations er
      join events e on e.id = er.event_id
      cross join me
      where me.uid is not null and er.user_id = me.uid and er.status = 'confirmed'
    union all
    select o.church_id, null::text
      from church_email_optouts o cross join me
      where o.user_id = me.uid
         or (o.email is not null and me.em is not null and lower(o.email) = lower(me.em))
  ),
  ranked as (
    select s.church_id,
           min(case s.reason
                 when 'staff'  then 1
                 when 'member' then 2
                 when 'group'  then 3
                 when 'event'  then 4
                 else 9
               end) as rank
    from sources s
    group by s.church_id
  )
  select r.church_id,
         c.name,
         case r.rank
           when 1 then 'staff'
           when 2 then 'member'
           when 3 then 'group'
           when 4 then 'event'
           else null
         end,
         exists (
           select 1 from church_email_optouts o cross join me
           where o.church_id = r.church_id
             and (o.user_id = me.uid
                  or (o.email is not null and me.em is not null and lower(o.email) = lower(me.em)))
         )
  from ranked r
  join churches c on c.id = r.church_id
  order by c.name;
$fn$;

-- ---------------------------------------------------------------------
-- Turn it off, from the account page.
--
-- There is already an RLS policy letting somebody insert their own
-- opt-out row, so the client could do this directly. It goes through a
-- function anyway, for one reason: the policy can only ever write the
-- account row, and the unsubscribe link writes BOTH the account row and
-- the address row. Two routes that leave the table in different states
-- is how the next bug gets written. This makes the page and the link do
-- the same thing.
--
-- Idempotent: unsubscribing twice is not an error, it is the same
-- outcome, and the conflict targets match the partial unique indexes
-- from migration 069.
-- ---------------------------------------------------------------------
create or replace function unsubscribe_from_church(p_church_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_email text := auth.email();
begin
  if v_uid is null then
    raise exception 'Not signed in.' using errcode = '42501';
  end if;

  -- Refuse a church id that is not a church. Without this, a typo or a
  -- crafted call would insert a row pointing at nothing, which the
  -- foreign key would reject anyway -- but with a message about a
  -- constraint rather than about the thing that was wrong.
  if not exists (select 1 from churches where id = p_church_id) then
    raise exception 'No such church.' using errcode = '22023';
  end if;

  insert into church_email_optouts (church_id, user_id, source)
  values (p_church_id, v_uid, 'account')
  on conflict (church_id, user_id) where user_id is not null do nothing;

  if v_email is not null then
    insert into church_email_optouts (church_id, email, source)
    values (p_church_id, lower(v_email), 'account')
    on conflict (church_id, lower(email)) where email is not null do nothing;
  end if;

  return true;
end
$fn$;

revoke all on function my_email_subscriptions() from public;
revoke all on function my_email_subscriptions() from anon;
grant execute on function my_email_subscriptions() to authenticated;

revoke all on function unsubscribe_from_church(uuid) from public;
revoke all on function unsubscribe_from_church(uuid) from anon;
grant execute on function unsubscribe_from_church(uuid) to authenticated;

-- my_email_optouts() from migration 074 is superseded by the function
-- above and is intentionally left in place rather than dropped: a browser
-- still holding the previous build calls it, and breaking that tab to
-- tidy the schema is a bad trade for a function that costs nothing.

notify pgrst, 'reload schema';

do $verify$
begin
  if has_function_privilege('anon', 'my_email_subscriptions()', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon can execute my_email_subscriptions.';
  end if;
  if has_function_privilege('anon', 'unsubscribe_from_church(uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon can execute unsubscribe_from_church.';
  end if;
  if not has_function_privilege('authenticated', 'my_email_subscriptions()', 'EXECUTE') then
    raise exception 'VERIFY FAILED: a signed-in person cannot list their subscriptions.';
  end if;
  if not has_function_privilege('authenticated', 'unsubscribe_from_church(uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: a signed-in person cannot unsubscribe themselves.';
  end if;

  if (select count(*) from pg_proc where proname = 'my_email_subscriptions') <> 1 then
    raise exception 'VERIFY FAILED: my_email_subscriptions is overloaded.';
  end if;
  if (select count(*) from pg_proc where proname = 'unsubscribe_from_church') <> 1 then
    raise exception 'VERIFY FAILED: unsubscribe_from_church is overloaded.';
  end if;

  -- Still true, and still the thing that matters most in this table.
  if has_table_privilege('authenticated', 'church_email_optouts', 'UPDATE') then
    raise exception 'VERIFY FAILED: opt-outs are editable, they should not be.';
  end if;

  raise notice 'OK: people can see and change every church email subscription they have.';
end
$verify$;
