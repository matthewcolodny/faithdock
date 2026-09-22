-- Run in Supabase SQL Editor. Requires 069 (church_email_optouts).
--
-- Opted-out people stop being recipients.
--
-- Filtered HERE rather than in each of the four audience branches. All
-- four converge on one array, so one subtraction at the end covers
-- members, staff, a group and an event alike -- and covers whatever
-- audience gets added next without anybody having to remember. Four
-- copies of the same NOT EXISTS is the shape this file keeps paying
-- for.
--
-- This is not the only place it has to hold. The client hands the send
-- function a list of addresses, so a tampered client could pass
-- anything; the Edge Function re-checks against the same table before
-- sending. That is the enforceable one. This one exists so the count a
-- person is shown before pressing send is honest -- "247 will receive
-- this" must not quietly mean 190.
--
-- Body is 064's, unchanged except for the final filter.

CREATE OR REPLACE FUNCTION public.get_mass_email_recipients(
  target_church_id uuid,
  audience_type text,
  audience_ref_id uuid DEFAULT NULL::uuid
)
RETURNS text[]
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  recipient_emails text[];
begin
  if not (
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or is_church_staff_member(target_church_id)
  ) then
    return array[]::text[];
  end if;

  if audience_type = 'members' then
    select array_agg(distinct u.email) into recipient_emails
    from church_memberships cm
    join auth.users u on u.id = cm.user_id
    where cm.church_id = target_church_id
      and cm.is_permanent = true
      and cm.status = 'approved';

  elsif audience_type = 'staff' then
    select array_agg(distinct u.email) into recipient_emails
    from (
      select user_id from church_staff where church_id = target_church_id
      union
      select owner_id as user_id from churches where id = target_church_id
    ) people
    join auth.users u on u.id = people.user_id;

  elsif audience_type = 'group' then
    select array_agg(distinct u.email) into recipient_emails
    from group_members gm
    join groups g on g.id = gm.group_id
    join auth.users u on u.id = gm.user_id
    where g.id = audience_ref_id and g.church_id = target_church_id and gm.status = 'active';

  elsif audience_type = 'event' then
    select array_agg(distinct u.email) into recipient_emails
    from event_registrations er
    join events e on e.id = er.event_id
    join auth.users u on u.id = er.user_id
    where e.id = audience_ref_id and e.church_id = target_church_id and er.status = 'confirmed';
  end if;

  -- === The opt-out subtraction ===
  --
  -- Matched on BOTH identifiers. A row can carry a user_id (somebody
  -- signed in and opted out) or a bare email (somebody clicked the link
  -- in a message without signing in), and the same person can be one
  -- today and the other tomorrow. Checking only one would let an
  -- opt-out recorded by the other route be ignored, which is the one
  -- mistake this table exists to prevent.
  --
  -- lower() on both sides: addresses are compared case-insensitively,
  -- and the unique index on this table is on lower(email) too, so the
  -- two agree about what counts as the same address.
  select array_agg(e) into recipient_emails
  from unnest(coalesce(recipient_emails, array[]::text[])) as e
  where not exists (
    select 1 from church_email_optouts o
    where o.church_id = target_church_id
      and (
        lower(o.email) = lower(e)
        or o.user_id in (select id from auth.users au where lower(au.email) = lower(e))
      )
  );

  return coalesce(recipient_emails, array[]::text[]);
end;
$function$;

-- === Who a church may see has opted out ===
--
-- The messages area needs to say "3 of these have unsubscribed", which
-- means naming them. Reading church_email_optouts directly would work
-- for staff (069's select policy allows it) but returns only the rows,
-- not the addresses behind a user_id -- auth.users is not readable from
-- the client. This returns the addresses, for this church only.
create or replace function get_church_optout_emails(target_church_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  result text[];
begin
  if not (
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or is_church_staff_member(target_church_id)
  ) then
    return array[]::text[];
  end if;

  select array_agg(distinct lower(addr)) into result
  from (
    select o.email as addr
      from church_email_optouts o
     where o.church_id = target_church_id and o.email is not null
    union
    select u.email as addr
      from church_email_optouts o
      join auth.users u on u.id = o.user_id
     where o.church_id = target_church_id and o.user_id is not null
  ) all_addrs
  where addr is not null;

  return coalesce(result, array[]::text[]);
end;
$fn$;

revoke all on function get_church_optout_emails(uuid) from public;
revoke all on function get_church_optout_emails(uuid) from anon;
grant execute on function get_church_optout_emails(uuid) to authenticated;

notify pgrst, 'reload schema';

do $verify$
begin
  if not exists (select 1 from pg_proc where proname = 'get_church_optout_emails') then
    raise exception 'VERIFY FAILED: get_church_optout_emails was not created.';
  end if;
  if has_function_privilege('anon', 'get_church_optout_emails(uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon can read a church''s opt-out list.';
  end if;
  if not has_function_privilege('authenticated', 'get_church_optout_emails(uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: staff cannot read their own opt-out list.';
  end if;

  -- The recipients function must still exist as exactly one version:
  -- CREATE OR REPLACE above keeps the signature, so a second copy here
  -- would mean the signature drifted and calls will start failing.
  if (select count(*) from pg_proc where proname = 'get_mass_email_recipients') <> 1 then
    raise exception 'VERIFY FAILED: get_mass_email_recipients is not a single function.';
  end if;

  raise notice 'OK: mass email now skips opted-out recipients, and staff can see who.';
end
$verify$;
