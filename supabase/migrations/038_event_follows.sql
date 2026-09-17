-- Run in Supabase SQL Editor.
--
-- Following an event, mirroring the existing follow-a-church heart.
--
-- church_follows (the thing this is modelled on) predates migration
-- tracking and isn't in this repo, so its policies can't be copied --
-- which is a small silver lining here: this table gets defined properly
-- from the start instead of inheriting whatever is already there.
--
-- Scope note: this is deliberately only "I want to keep an eye on this
-- event." It is NOT a registration, does not hold a spot, and does not
-- interact with capacity -- an event can be Full and still followable,
-- which is arguably when following matters most (a spot may open up).

create table if not exists event_follows (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  event_id uuid not null references events(id) on delete cascade,
  created_at timestamptz not null default now(),
  -- The natural key. Also what lets the client upsert on
  -- (user_id, event_id) without inventing a second way to say the
  -- same thing, the way church follows already do.
  unique (user_id, event_id)
);

-- Deleting an event should take its follows with it rather than leaving
-- rows pointing at nothing -- hence on delete cascade above. Same for a
-- deleted account.

create index if not exists event_follows_user_idx on event_follows (user_id);
create index if not exists event_follows_event_idx on event_follows (event_id);

alter table event_follows enable row level security;

-- Your follows are yours: you can see, add and remove your own rows and
-- nobody else's. Written as three explicit policies rather than one
-- FOR ALL, so that widening any single verb later (say, letting a
-- church see who follows its own events) is a change to one policy
-- instead of a rewrite of the whole rule.
drop policy if exists "Users can see their own event follows" on event_follows;
create policy "Users can see their own event follows"
  on event_follows for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists "Users can follow events" on event_follows;
create policy "Users can follow events"
  on event_follows for insert
  to authenticated
  with check (user_id = auth.uid());

drop policy if exists "Users can unfollow events" on event_follows;
create policy "Users can unfollow events"
  on event_follows for delete
  to authenticated
  using (user_id = auth.uid());

grant select, insert, delete on event_follows to authenticated;

notify pgrst, 'reload schema';
