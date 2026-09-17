-- Run in Supabase SQL Editor.
--
-- Saved drafts for the Messages composer.
--
-- === Why a new table rather than a status on scheduled_messages ===
-- That table has nearly the right shape (church_id, subject, body_html,
-- audience_json, created_by) and reusing it was the first instinct --
-- it already carries a `status` column with 'pending' and 'canceled'.
--
-- Two things argue against it. Its `send_at` is almost certainly NOT
-- NULL, and a draft has no send time, so reusing it means dropping a
-- constraint on a table a working feature depends on -- while unable to
-- see that table's definition from this repo, which is the exact
-- situation that has caused trouble repeatedly here. And the lifecycles
-- genuinely differ: a scheduled message is a commitment with a delivery
-- time and a worker that acts on it, while a draft is unfinished work
-- that may never be sent. Sharing a table would mean every query
-- against scheduled sends growing a `status <> 'draft'` filter, and the
-- first one that forgets ships somebody's half-written message.
--
-- A separate table costs one CREATE and cannot break what already works.

create table if not exists message_drafts (
  id uuid primary key default gen_random_uuid(),
  church_id uuid not null references churches(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete cascade,
  subject text,
  body_html text,
  -- Same shape the composer already builds for a send, so loading a
  -- draft back into the form is a straight assignment rather than a
  -- translation that could drift from the sender's own format.
  audience_json jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists message_drafts_church_author_idx
  on message_drafts (church_id, created_by, updated_at desc);

alter table message_drafts enable row level security;

-- === Author-only, deliberately ===
-- A draft is unfinished work. Making every staff member's half-written
-- messages visible to every other one invites somebody sending a
-- colleague's unfinished thought, and there is no way to tell from a
-- row whether it was meant to be shared. Scoped to the author, which
-- can be widened later if churches actually ask for shared drafts --
-- widening a permission is easy, narrowing one after people rely on it
-- is not.
--
-- church_id is still checked on write: it stops a draft being filed
-- against a church the author has nothing to do with, which would then
-- surface in that church's composer.
drop policy if exists "Authors can read their own drafts" on message_drafts;
create policy "Authors can read their own drafts"
  on message_drafts for select to authenticated
  using (created_by = auth.uid());

drop policy if exists "Authors can create their own drafts" on message_drafts;
create policy "Authors can create their own drafts"
  on message_drafts for insert to authenticated
  with check (
    created_by = auth.uid()
    and (
      exists (select 1 from churches c where c.id = church_id and c.owner_id = auth.uid())
      or exists (select 1 from church_staff cs where cs.church_id = message_drafts.church_id and cs.user_id = auth.uid())
    )
  );

drop policy if exists "Authors can update their own drafts" on message_drafts;
create policy "Authors can update their own drafts"
  on message_drafts for update to authenticated
  using (created_by = auth.uid())
  with check (created_by = auth.uid());

drop policy if exists "Authors can delete their own drafts" on message_drafts;
create policy "Authors can delete their own drafts"
  on message_drafts for delete to authenticated
  using (created_by = auth.uid());

grant select, insert, update, delete on message_drafts to authenticated;

notify pgrst, 'reload schema';
