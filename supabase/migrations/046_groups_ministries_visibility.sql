-- Run in Supabase SQL Editor.
--
-- Lets a church hide the Groups and Ministries sections from its public
-- profile, for the very ordinary case of a church that simply doesn't
-- run either. Today those sections render regardless and show an empty
-- state, which reads as "this church is incomplete" rather than "this
-- church doesn't do that".
--
-- Mirrors migration 032's giving_enabled / messaging_enabled exactly --
-- same shape, same default, same grant pattern -- because it is the
-- same idea applied to two more sections, and a second way of
-- expressing "show this part of the profile" would be a needless
-- divergence.
--
-- Defaults to TRUE, so every existing church keeps showing what it
-- shows today. A visibility feature whose migration hides things is a
-- migration that silently changes 799 public profiles.

alter table churches add column if not exists groups_enabled boolean not null default true;
alter table churches add column if not exists ministries_enabled boolean not null default true;

-- The grants are the part that is easy to miss and hard to debug.
-- `churches` uses per-COLUMN grants rather than a table-level one, so a
-- new column is invisible and unwritable until named here. The failure
-- modes look nothing alike and that is the useful tell: a missing
-- SELECT grant surfaces as 42501 (permission denied), while a column
-- that genuinely doesn't exist gives 42703 -- so 42501 on a column you
-- just added means the ALTER worked and this line is what's missing.
grant select (groups_enabled) on churches to anon, authenticated;
grant select (ministries_enabled) on churches to anon, authenticated;
grant update (groups_enabled) on churches to authenticated;
grant update (ministries_enabled) on churches to authenticated;

notify pgrst, 'reload schema';

-- Verify both are readable and the defaults took:
--   select id, name, groups_enabled, ministries_enabled from churches limit 5;
