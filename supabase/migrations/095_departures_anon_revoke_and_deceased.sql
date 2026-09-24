-- Run in the Supabase SQL Editor.
--
-- Two small corrections to migration 094, which has already run.
--
-- 1. TAKE THE TABLE GRANT AWAY FROM anon.
--
-- 094's own verify output reported anon_can_read = true. I had
-- predicted false and had not checked it, which is why it is being
-- fixed here rather than there: 094 granted SELECT to authenticated and
-- never revoked anything, and Supabase's default privileges on the
-- public schema had already given anon SELECT on the new table.
--
-- Measured before changing anything: an anonymous request for
-- church_membership_departures returns 200 and an empty array, not
-- rows. RLS is doing its job -- the only policy is
-- can_manage_church_members(church_id), which is false when auth.uid()
-- is null. So nothing leaked.
--
-- It is still wrong to leave. A table privilege that is harmless only
-- because one policy holds is exactly the arrangement that failed on
-- `events` last week: a second, looser policy arrived later and the
-- permissive policies ORed together. If that ever happens here, the
-- anon grant is the difference between "no rows" and "every departure
-- record in the database". Revoking costs nothing and removes the
-- dependency.
--
-- 2. ALLOW kind = 'deceased'.
--
-- Nothing writes it yet. It is being added now because a CHECK is
-- cheap to widen and tedious to change under load, and because a death
-- ends a membership and so belongs in this log -- as its OWN kind,
-- never folded into 'left' or 'removed'. A church counting deaths as
-- attrition alongside people who walked away would be reading a
-- retention chart that is not true. The client already counts only
-- 'left' and 'removed' for that reason.
--
-- This does NOT deliver the CRM record: a profile kept permanently,
-- marked deceased on a date, titled "Former member". That needs a
-- person record the church owns, and today every person in FaithDock
-- is an auth.users row. See POLICY.md 14.

-- ---------------------------------------------------------------------
-- Preflight.
-- ---------------------------------------------------------------------
do $preflight$
begin
  if not exists (select 1 from information_schema.tables
                 where table_schema='public' and table_name='church_membership_departures') then
    raise exception 'VERIFY FAILED: church_membership_departures does not exist -- run migration 094 first. Nothing was changed.';
  end if;
  raise notice 'Preflight OK.';
end
$preflight$;

-- ---------------------------------------------------------------------
-- 1. anon has no business with this table at all.
-- ---------------------------------------------------------------------
revoke all on church_membership_departures from anon;

-- Belt and braces for the next table added to this schema: without
-- this, the same default privilege hands anon SELECT again. Scoped to
-- the role that owns the migrations, which is what actually creates
-- them.
alter default privileges in schema public revoke select on tables from anon;

-- ---------------------------------------------------------------------
-- 2. kind may be 'deceased'.
-- ---------------------------------------------------------------------
do $kind$
declare
  v_constraint text;
begin
  -- Found by definition rather than by name: 094 let Postgres name it,
  -- and that name is not guaranteed across environments.
  select con.conname into v_constraint
    from pg_constraint con
    join pg_class c on c.oid = con.conrelid
   where c.relname = 'church_membership_departures'
     and con.contype = 'c'
     and pg_get_constraintdef(con.oid) ilike '%kind%';

  if v_constraint is not null then
    execute format('alter table church_membership_departures drop constraint %I', v_constraint);
  end if;

  alter table church_membership_departures
    add constraint church_membership_departures_kind_check
    check (kind in ('left', 'removed', 'deceased'));
end
$kind$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Verify.
-- ---------------------------------------------------------------------
do $verify$
begin
  if has_table_privilege('anon', 'church_membership_departures', 'SELECT') then
    raise exception 'VERIFY FAILED: anon can still select from the departures log.';
  end if;
  if not has_table_privilege('authenticated', 'church_membership_departures', 'SELECT') then
    raise exception 'VERIFY FAILED: authenticated can no longer read the log -- the revoke was too wide and the chart will be empty for everyone.';
  end if;
  if not exists (
    select 1 from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'church_membership_departures'
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ilike '%deceased%'
  ) then
    raise exception 'VERIFY FAILED: kind does not permit deceased.';
  end if;
  raise notice 'OK.';
end
$verify$;

select
  has_table_privilege('anon','church_membership_departures','SELECT')           as anon_can_read,
  has_table_privilege('authenticated','church_membership_departures','SELECT')  as authenticated_can_read,
  (select pg_get_constraintdef(con.oid)
     from pg_constraint con join pg_class c on c.oid = con.conrelid
    where c.relname='church_membership_departures' and con.contype='c'
      and pg_get_constraintdef(con.oid) ilike '%kind%')                         as kind_constraint,
  (select count(*) from pg_policy p join pg_class c on c.oid=p.polrelid
    where c.relname='church_membership_departures')::text                       as policies_on_log;
