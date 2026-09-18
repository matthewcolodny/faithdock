-- Run in Supabase SQL Editor.
--
-- Columns behind the new per-section Settings pages.
--
-- === Defaults are chosen so that running this changes nothing ===
-- Every existing church keeps behaving exactly as it does today: the
-- two visibility switches default to the more private option, and
-- events stay shown because they are shown now. A migration that
-- silently alters what the public sees would be a bad trade for a
-- tidier default.

-- Events -> Settings: hide the Events section from the public page.
-- Mirrors groups_enabled / ministries_enabled from 046 exactly --
-- same shape, same default, same grant treatment -- because it is the
-- same kind of switch and a third spelling would be gratuitous.
alter table churches add column if not exists events_enabled boolean not null default true;

-- Events -> Settings: the church's own tag vocabulary.
-- An array on churches rather than a table: these are a handful of
-- short strings with no attributes of their own, nothing references
-- them by id, and the event form already stores tags as text on the
-- event. A table would add a join to every read for nothing.
alter table churches add column if not exists event_tags text[] not null default '{}';

-- Directory -> Settings.
-- Text rather than boolean because "staff only" and "all approved
-- members" are unlikely to stay the only two answers -- group leaders
-- are the obvious third -- and widening a boolean later means a
-- migration plus every read site. Defaults to the current behaviour.
alter table churches add column if not exists directory_visibility text not null default 'staff';
alter table churches drop constraint if exists churches_directory_visibility_check;
alter table churches add constraint churches_directory_visibility_check
  check (directory_visibility in ('staff', 'members'));

-- Whether members can see each other's phone and email. Separate from
-- the switch above on purpose: "members can see the list" and "members
-- can see how to contact each other" are different decisions, and a
-- church may well want the first without the second.
alter table churches add column if not exists members_see_contact_details boolean not null default false;

-- Revenue -> Settings: text appended to giving receipts.
alter table churches add column if not exists receipt_footer_text text;

-- Revenue -> Settings: which funds a visitor can choose.
-- Defaults true so no church's giving page loses an option the moment
-- this runs. is_active already exists and means something different --
-- retired versus hidden-from-the-public -- and conflating them would
-- make "stop offering this publicly" also mean "stop recording it".
alter table giving_funds add column if not exists is_public boolean not null default true;

-- === Grants: only where they are actually needed ===
-- churches is on a PER-COLUMN model for SELECT (verified live: anon
-- gets 42501 on stripe_customer_id but reads name fine), so a new
-- column is unreadable until it is granted. That is the one thing a
-- GRANT genuinely does here.
--
-- events_enabled drives the public church page, so anon needs it.
grant select (events_enabled) on churches to anon, authenticated;
-- The rest are read by the dashboard only. Granting them to anon
-- would publish how a church has configured its own privacy.
grant select (event_tags) on churches to authenticated;
grant select (directory_visibility) on churches to authenticated;
grant select (members_see_contact_details) on churches to authenticated;
grant select (receipt_footer_text) on churches to authenticated;

-- No UPDATE grants, and no grant at all on giving_funds.is_public.
-- Both tables already carry table-wide privileges for the roles that
-- use them, so those statements would add nothing while reading as
-- though they narrowed something -- the mistake 049 made. What governs
-- writes here is unchanged: the RLS policies on each table, and the
-- 051 trigger, which pins ownership and billing columns and none of
-- these.

notify pgrst, 'reload schema';

-- Confirm, rather than trusting that the statements ran.
do $verify$
declare
  v_missing text := '';
begin
  if not exists (select 1 from information_schema.columns where table_name='churches' and column_name='events_enabled') then v_missing := v_missing || ' events_enabled'; end if;
  if not exists (select 1 from information_schema.columns where table_name='churches' and column_name='event_tags') then v_missing := v_missing || ' event_tags'; end if;
  if not exists (select 1 from information_schema.columns where table_name='churches' and column_name='directory_visibility') then v_missing := v_missing || ' directory_visibility'; end if;
  if not exists (select 1 from information_schema.columns where table_name='churches' and column_name='members_see_contact_details') then v_missing := v_missing || ' members_see_contact_details'; end if;
  if not exists (select 1 from information_schema.columns where table_name='churches' and column_name='receipt_footer_text') then v_missing := v_missing || ' receipt_footer_text'; end if;
  if not exists (select 1 from information_schema.columns where table_name='giving_funds' and column_name='is_public') then v_missing := v_missing || ' giving_funds.is_public'; end if;
  if v_missing <> '' then
    raise exception 'VERIFY FAILED: missing%', v_missing;
  end if;
  if not has_column_privilege('anon', 'churches', 'events_enabled', 'SELECT') then
    raise exception 'VERIFY FAILED: anon cannot read events_enabled, so the public page would not see it.';
  end if;
  raise notice 'OK: six columns added and readable.';
end
$verify$;
