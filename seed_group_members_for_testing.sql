-- Run in Supabase SQL Editor. TEST DATA — reversible, see the bottom.
--
-- Members on three of the eight [seed] groups, so migration 119 can
-- actually be tested: it asked for a group member list that still
-- shows names, and for approving and promoting a member to still work.
-- All eight groups had 0 members, so there was nothing to click.
--
-- ---------------------------------------------------------------------
-- WHAT THE SCHEMA ALLOWS (probed, not assumed -- group_members
-- predates supabase/migrations)
--
--   role    NOT NULL default 'member'  CHECK in ('member','leader')
--   status  null     default 'active'  CHECK in ('pending','active')
--   user_id NOT NULL  -> profiles(id)  ON DELETE CASCADE
--   UNIQUE (group_id, user_id)
--
-- user_id points at profiles, not auth.users, and all five accounts
-- have a profile row -- so all five are usable and none had to be
-- invented.
--
-- There is no text column on this table, so rows cannot carry a
-- '[seed]' marker the way the groups do. The cleanup at the bottom
-- keys on the group instead. Deleting the seeded groups already
-- removes these anyway: the group_id foreign key is ON DELETE CASCADE.
--
-- ---------------------------------------------------------------------
-- WHAT EACH ROW IS FOR
--
-- Tuesday Morning Women's Bible Study
--   Isis Colodny        active  leader   a second leader, so demote is testable
--   Isis Diaz Linares   active  member   promote / demote target
--   Matt Colo           PENDING member   approve / deny target
--
-- Men's Prayer Breakfast
--   Robert Budnick2     active  leader   you, so the leader view is yours
--   Matt Colo           active  member
--   DG                  PENDING member   a second approve, on a second group
--
-- Young Families Playgroup
--   DG                  active  member   two plain names, nothing to action
--   Isis Colodny        active  member
--
-- Everything is looked up by email and by group name rather than by
-- pasted uuid, so re-seeding the groups (which gives them new ids)
-- does not turn this into a file full of dead references.
--
-- ON CONFLICT DO UPDATE, not DO NOTHING: re-running this puts the two
-- pending rows back, so the approve test can be taken again without
-- deleting anything first.

do $$
declare
  g_bible  uuid;
  g_prayer uuid;
  g_play   uuid;
  u_robby  uuid;
  u_matt   uuid;
  u_isisc  uuid;
  u_isisd  uuid;
  u_dg     uuid;
  n_before int;
  n_after  int;
begin
  select count(*) into n_before from group_members;

  select id into g_bible  from groups where name = 'Tuesday Morning Women''s Bible Study' and description like '%[seed]%';
  select id into g_prayer from groups where name = 'Men''s Prayer Breakfast'              and description like '%[seed]%';
  select id into g_play   from groups where name = 'Young Families Playgroup'             and description like '%[seed]%';

  if g_bible is null or g_prayer is null or g_play is null then
    raise exception 'ABORT: one of the three [seed] groups is missing. Re-run seed_groups_for_testing.sql first.';
  end if;

  select id into u_robby from auth.users where email = 'robbybudnick@gmail.com';
  select id into u_matt  from auth.users where email = 'matthewcolodny@gmail.com';
  select id into u_isisc from auth.users where email = 'isis.colodny@gmail.com';
  select id into u_isisd from auth.users where email = 'isisdiazlinares@gmail.com';
  select id into u_dg    from auth.users where email = 'filagrey@gmail.com';

  if u_robby is null or u_matt is null or u_isisc is null or u_isisd is null or u_dg is null then
    raise exception 'ABORT: one of the five accounts is missing. Re-run the probe.';
  end if;

  -- profiles(id) is the actual target of the foreign key, and a user
  -- without a profile row would fail the insert with a message about a
  -- constraint rather than about the account.
  if exists (select 1 from unnest(array[u_robby, u_matt, u_isisc, u_isisd, u_dg]) as t(uid)
              where not exists (select 1 from profiles p where p.id = t.uid)) then
    raise exception 'ABORT: one of the accounts has no profiles row, which user_id references.';
  end if;

  insert into group_members (group_id, user_id, role, status) values
    (g_bible,  u_isisc, 'leader', 'active'),
    (g_bible,  u_isisd, 'member', 'active'),
    (g_bible,  u_matt,  'member', 'pending'),
    (g_prayer, u_robby, 'leader', 'active'),
    (g_prayer, u_matt,  'member', 'active'),
    (g_prayer, u_dg,    'member', 'pending'),
    (g_play,   u_dg,    'member', 'active'),
    (g_play,   u_isisc, 'member', 'active')
  on conflict (group_id, user_id) do update
    set role = excluded.role, status = excluded.status;

  select count(*) into n_after from group_members;
  raise notice 'group_members: % rows before, % after.', n_before, n_after;
end $$;

-- ---------------------------------------------------------------------
-- What a member list should now show. Reading it back through the same
-- join the dashboard uses -- group_members to profiles for the name --
-- because "the rows exist" and "the names render" are different
-- claims, and 119 changed the policy that decides the second one.
select g.name                                   as group_name,
       coalesce(p.full_name, '(no name)')       as member,
       m.role,
       m.status
  from group_members m
  join groups g   on g.id = m.group_id
  left join profiles p on p.id = m.user_id
 where g.description like '%[seed]%'
 order by g.name, m.status desc, p.full_name;

-- ---------------------------------------------------------------------
-- TO TEST, signed in as robbybudnick@gmail.com (the church owner, so
-- the UPDATE policy's owner branch is what lets you act):
--
--   1. Open Tuesday Morning Women's Bible Study's member list.
--      Three names, one of them marked pending. If names are missing
--      but rows are there, 119's profiles policy is the cause.
--   2. Approve Matt Colo. That is an UPDATE setting status to active,
--      which is the path 119's WITH CHECK now also tests.
--   3. Promote Isis Diaz Linares to leader, then demote. Same policy,
--      different column.
--   4. Open the Groups tab in the browse sheet. The three cards should
--      read 3, 3 and 2 members instead of 0 -- that is search_groups'
--      member_count, which only counts status = 'active', so the two
--      pending rows should NOT be included until you approve them.
--
-- ---------------------------------------------------------------------
-- UNDO. Members only, leaving the groups in place:
--
--   delete from group_members m using groups g
--    where g.id = m.group_id and g.description like '%[seed]%';
--
-- Or drop the groups and let the cascade take the members with them:
--
--   delete from groups where description like '%[seed]%';
