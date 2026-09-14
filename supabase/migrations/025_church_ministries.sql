-- Run in Supabase SQL Editor.
--
-- Adds church-owned "Ministries" — the food pantry, youth group,
-- prison ministry, recovery program, etc. that a single church runs as
-- part of itself. This is deliberately NOT a new top-level directory
-- entity: an independent parachurch nonprofit still isn't listed on
-- FaithDock on its own (see the churches.name hygiene pass below, which
-- goes the other direction — hiding those). A ministry only exists here
-- because a real, already-registered, already-verified church chose to
-- add it to their own profile — same trust model as everything else a
-- church owner manages (rooms, giving funds, groups), not a new
-- self-serve signup path with its own verification story to build.
--
-- Schema mirrors church_rooms/event_rooms exactly (see GOTCHAS.md's
-- note that those were created directly in the Supabase dashboard and
-- never captured in a migration file — this repo has no file to copy
-- from, so this migration is the first one for either):
--   church_ministries(id, church_id, name, description, is_active) —
--     the church's own list, soft-deleted (is_active=false) so a past
--     event's reference to a since-removed ministry survives.
--   event_ministries(event_id, ministry_id, is_primary) — join table,
--     same delete-then-reinsert-on-save shape as event_rooms.
--
-- Deliberate difference from rooms: rooms are purely operational and
-- are never shown on any public page (only the create/edit form and an
-- internal printable schedule read church_rooms/event_rooms). Ministries
-- are the opposite — the entire point is public discoverability — so
-- both church_ministries and event_ministries get an explicit public
-- SELECT policy (rooms have no public-read policy to replicate; this
-- one is new, not copied).

create table if not exists church_ministries (
  id uuid primary key default gen_random_uuid(),
  church_id uuid not null references churches(id) on delete cascade,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists idx_church_ministries_church_id on church_ministries(church_id);

alter table church_ministries enable row level security;

drop policy if exists "Anyone can read active ministries" on church_ministries;
create policy "Anyone can read active ministries"
  on church_ministries for select
  to anon, authenticated
  using (is_active = true);

-- Owner-scoped management, same idiom as church_billing's RLS
-- (migration 001) — the closest documented analog in this repo, since
-- church_rooms itself has no migration-file RLS to copy from. If staff
-- (not just the owner) should manage ministries too, extend this with
-- the "owner-or-staff" pattern noted in GOTCHAS.md
-- (is_church_staff_member(...)) — not added here to keep this pass
-- narrow; not knowing whether staff need this yet.
drop policy if exists "Church owner can manage own ministries" on church_ministries;
create policy "Church owner can manage own ministries"
  on church_ministries for all
  to authenticated
  using (exists (select 1 from churches where churches.id = church_ministries.church_id and churches.owner_id = auth.uid()))
  with check (exists (select 1 from churches where churches.id = church_ministries.church_id and churches.owner_id = auth.uid()));

grant select on church_ministries to anon, authenticated;
grant insert, update, delete on church_ministries to authenticated;

create table if not exists event_ministries (
  event_id uuid not null references events(id) on delete cascade,
  ministry_id uuid not null references church_ministries(id) on delete cascade,
  is_primary boolean not null default false,
  primary key (event_id, ministry_id)
);

alter table event_ministries enable row level security;

drop policy if exists "Anyone can read event ministries" on event_ministries;
create policy "Anyone can read event ministries"
  on event_ministries for select
  to anon, authenticated
  using (true);

drop policy if exists "Church owner can manage own event ministries" on event_ministries;
create policy "Church owner can manage own event ministries"
  on event_ministries for all
  to authenticated
  using (exists (
    select 1 from events e join churches c on c.id = e.church_id
    where e.id = event_ministries.event_id and c.owner_id = auth.uid()
  ))
  with check (exists (
    select 1 from events e join churches c on c.id = e.church_id
    where e.id = event_ministries.event_id and c.owner_id = auth.uid()
  ));

grant select on event_ministries to anon, authenticated;
grant insert, update, delete on event_ministries to authenticated;

-- ---------------------------------------------------------------------
-- Data hygiene: standalone organizations whose NAME says "ministry" /
-- "ministries" don't belong in the churches directory at all — per
-- product decision, a ministry is only ever findable as something a
-- real registered church added to its own profile (the tables above),
-- never as its own independent directory listing. Most rows matching
-- this pattern came in through the bulk IRS-extract import
-- (filter-churches.js's own Stage-1 candidate check treats "ministry"
-- as a religious-org keyword, which is right for catching candidates
-- but wrong for assuming every match is a single congregation) and are
-- actually parachurch/program orgs, not a congregation.
--
-- Same reversible HIDE approach as the earlier nonprofit-name hygiene
-- pass (is_hidden = true, not a delete) — and the same word-boundary
-- discipline as every keyword check elsewhere in this repo (\m...\M are
-- Postgres's own regex word-boundary anchors), which is specifically
-- why this does NOT false-positive on a name like "Resurrection
-- Cemetery Administry" (no word boundary between "Ad" and "ministry").
--
-- KNOWN TRADE-OFF, flagged rather than hidden: some real single
-- congregations formally call themselves "___ Ministries" (e.g. "New
-- Life Ministries") and this hides those too — an explicit, accepted
-- product decision here, not an oversight. Review the list this
-- produces before assuming it's all correct.
update churches
set is_hidden = true
where is_hidden = false
  and name ~* '\mministr(y|ies)\M';

notify pgrst, 'reload schema';
