-- Run in Supabase SQL Editor.
--
-- One room name per church.
--
-- Two rooms called "Room 300" are indistinguishable everywhere they
-- appear: the schedule's picker, the event form's room checkboxes, the
-- colour legend. Somebody books the wrong one and the grid cheerfully
-- shows both as free.
--
-- The client refuses a duplicate before asking, which is where the
-- useful message lives. This is the part that is actually true: a
-- second tab holding a stale room list, or anything talking to the API
-- directly, gets past a check that only exists in a browser.
--
-- CASE- AND SPACE-INSENSITIVE. "Room 300", "room 300" and "Room 300 "
-- are the same room to everybody except a byte comparison, so the index
-- is on lower(trim(name)) and the client folds the same way. If the two
-- disagreed, the client would accept a name the database then refused,
-- which is the worst of both.
--
-- ONLY ACTIVE ROOMS. Removing a room sets is_active = false rather than
-- deleting it, because past events still point at it. A retired
-- "Room 300" must not stop a church creating a new one with that name
-- years later.

-- ---------------------------------------------------------------------
-- Existing duplicates would make the index impossible to build. Report
-- them by name rather than failing on a constraint violation that says
-- only that one exists.
-- ---------------------------------------------------------------------
do $preflight$
declare
  r record;
  n int := 0;
begin
  for r in
    select c.name as church, lower(trim(cr.name)) as room_name, count(*) as copies
    from church_rooms cr
    join churches c on c.id = cr.church_id
    where cr.is_active
    group by c.name, lower(trim(cr.name))
    having count(*) > 1
    order by c.name, room_name
  loop
    n := n + 1;
    raise warning 'Duplicate room: % has % rooms called "%"', r.church, r.copies, r.room_name;
  end loop;

  if n > 0 then
    raise exception 'VERIFY FAILED: % duplicate room name(s) already exist. Rename or retire them first -- the warnings above name each one.', n;
  end if;
  raise notice 'No existing duplicates. Safe to add the index.';
end
$preflight$;

create unique index if not exists church_rooms_unique_active_name
  on church_rooms (church_id, lower(trim(name)))
  where is_active;

do $verify$
begin
  if not exists (
    select 1 from pg_indexes
    where tablename = 'church_rooms' and indexname = 'church_rooms_unique_active_name'
  ) then
    raise exception 'VERIFY FAILED: the unique index was not created.';
  end if;
  raise notice 'OK: a church cannot have two active rooms with the same name.';
end
$verify$;
