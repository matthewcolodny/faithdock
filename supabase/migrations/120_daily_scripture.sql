-- Run in Supabase SQL Editor.
--
-- Daily scripture: one verse a day, the same verse for everyone, for
-- the user dashboard.
--
-- ---------------------------------------------------------------------
-- WHAT WAS MEASURED
--
-- From daily_scripture.probe.sql, run 2026-10-03:
--
--   A. no table, view or matview in public matches
--      scriptur|verse|devotion|daily|bible|psalm. The names are free.
--   B. service_role BYPASSES RLS. anon, authenticated and
--      authenticator do not.
--   C. pg_cron 1.6.4 and pg_net 0.20.4 are BOTH already installed.
--   D. plan_tiers is the house pattern for a world-readable table:
--      one SELECT policy, role public, using (true), and no other
--      policy at all.
--   E. is_platform_admin() exists (security definer, boolean).
--      updated_at triggers are per-table -- account_settings_touch_
--      updated_at, church_billing_set_updated_at -- there is no shared
--      helper to call.
--   F. 45 tables in public, 45 with RLS on. No table here is without
--      it, so neither of these may be.
--
-- Every design decision below is one of those six, not a guess. 089
-- guessed five rules wrong; 118 nearly dropped the wrong function.
--
-- ---------------------------------------------------------------------
-- WHY TWO TABLES
--
-- scripture_pool is a vetted list of verses. daily_scripture is one row
-- per calendar day naming the verse for that day.
--
-- The split is the whole safety argument. A language model picking a
-- row from a fixed table cannot misquote scripture -- the worst case is
-- a verse that suits the day less well. A model asked to WRITE the
-- verse can produce a reference and words that do not match, and a
-- church directory that misquotes the Bible loses the trust it exists
-- to hold. So the model never generates scripture text; it chooses a
-- pool row and writes the reflection around it.
--
-- It also removes any dependency on a Bible API at request time, and
-- makes every possible output auditable before it is ever served:
-- whatever appears on the dashboard is a row someone already read.
--
-- ---------------------------------------------------------------------
-- WHY THE TEXT IS COPIED, NOT JOINED
--
-- daily_scripture carries its own reference and verse_text rather than
-- only a pool id. Editing or deactivating a pool row later must not
-- silently rewrite what the site showed last March. pool_id is kept
-- alongside for provenance, and is deliberately ON DELETE SET NULL --
-- removing a verse from the pool must not delete history.
--
-- ---------------------------------------------------------------------
-- TRANSLATION
--
-- WEB (World English Bible) is public domain and reads in modern
-- English. KJV and ASV are the other public-domain options. NIV, ESV
-- and NLT are licensed and must not be loaded into the pool -- the
-- translation column records which one a row is, so a licensed verse
-- cannot get in unlabelled.
--
-- ---------------------------------------------------------------------
-- WHO CAN WRITE
--
-- Neither table has an INSERT, UPDATE or DELETE policy, and that is a
-- decision rather than an omission. Because RLS is on, a missing write
-- policy denies the write outright, whatever the table grants say --
-- and measurement B says service_role bypasses RLS entirely, so the
-- Edge Function still writes normally. The browser roles cannot, by
-- construction, with nothing to revoke and nothing to keep in sync.
--
-- scripture_pool goes further and has NO policy at all. 117 noted that
-- RLS on with zero policies "is usually an accident rather than a
-- decision" -- here it is the decision: the pool is editorial working
-- material, not something the site renders, so no browser role has any
-- reason to read it. Only daily_scripture is public.

begin;

-- ---------------------------------------------------------------- pool
create table if not exists public.scripture_pool (
  id          uuid primary key default gen_random_uuid(),
  reference   text        not null,
  verse_text  text        not null,
  translation text        not null default 'WEB',
  themes      text[]      not null default '{}',
  active      boolean     not null default true,
  created_at  timestamptz not null default now(),
  constraint scripture_pool_reference_translation_key
    unique (reference, translation)
);

alter table public.scripture_pool enable row level security;
-- No policy, on purpose. See WHO CAN WRITE above.

-- --------------------------------------------------------------- daily
-- for_date is the primary key: one verse per calendar day, and an
-- upsert on it makes the job idempotent. A retry, a double-fire from
-- cron, or a manual re-run replaces the day's row instead of adding a
-- second one.
create table if not exists public.daily_scripture (
  for_date    date        primary key,
  reference   text        not null,
  verse_text  text        not null,
  translation text        not null default 'WEB',
  reflection  text,
  pool_id     uuid        references public.scripture_pool(id) on delete set null,
  created_at  timestamptz not null default now()
);

alter table public.daily_scripture enable row level security;

-- Modelled on plan_tiers / "Anyone can view plan tiers" (measurement
-- D): one SELECT policy, role public, using (true). Signed out and
-- signed in both read it; nobody writes it.
drop policy if exists "Anyone can view the daily scripture" on public.daily_scripture;
create policy "Anyone can view the daily scripture"
  on public.daily_scripture
  for select
  to public
  using (true);

commit;

-- ---------------------------------------------------------------------
-- NOT IN THIS MIGRATION, AND WHY
--
-- The cron job is not here. Scheduling the Edge Function means
-- net.http_post() carrying the service-role key, and that key must not
-- enter this repo in any form -- the repo is public, and tools/check.js
-- already fails the build over a password literal in 097. It gets
-- created by hand, once, with the key pasted in at the SQL Editor and
-- never saved to a file.
--
-- The pool starts empty. Seeding it is editorial work: every row is
-- read before it can ever be served, which is the point of the design.
--
-- READING IT BACK, for whoever builds the dashboard panel: ask for the
-- most recent row at or before today, never for today's row exactly --
--
--   select reference, verse_text, translation, reflection
--     from daily_scripture
--    where for_date <= current_date
--    order by for_date desc
--    limit 1;
--
-- so a failed job yesterday shows the last good verse instead of an
-- empty panel. The primary key index already serves that query.
