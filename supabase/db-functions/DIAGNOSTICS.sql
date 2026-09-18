-- Read-only diagnostics. Nothing here changes anything.
--
-- Written 2026-09-18 after finding that churches.owner_id has NO
-- foreign key to auth.users at all, which means deleting a user leaves
-- the church row behind pointing at somebody who no longer exists.

-- === 1. What actually cleans up when a user is deleted? ===
-- Every foreign key in the database that points at auth.users, and what
-- each one does on delete. Anything missing from this list does NOT
-- cascade, is not set to null, and does not block -- it is simply left
-- holding a dead id.
--
--   confdeltype: a = NO ACTION, r = RESTRICT, c = CASCADE,
--                n = SET NULL, d = SET DEFAULT
select con.conrelid::regclass          as referencing_table,
       att.attname                     as column_name,
       con.conname                     as constraint_name,
       case con.confdeltype
         when 'a' then 'NO ACTION' when 'r' then 'RESTRICT'
         when 'c' then 'CASCADE'   when 'n' then 'SET NULL'
         when 'd' then 'SET DEFAULT' else con.confdeltype::text
       end                             as on_delete
  from pg_constraint con
  join unnest(con.conkey) with ordinality as k(attnum, ord) on true
  join pg_attribute att on att.attrelid = con.conrelid and att.attnum = k.attnum
 where con.contype = 'f'
   and con.confrelid = 'auth.users'::regclass
 order by 1, 2;

-- === 2. Are there already churches owned by a deleted user? ===
-- Each row is a church nobody can sign in to manage: not claimable
-- either, since review_church_claim only assigns churches whose
-- owner_id is NULL. If any of these are on a paid plan, a card is being
-- charged for a church its owner can no longer reach.
select c.id, c.name, c.owner_id, c.plan_type, c.subscription_status,
       (c.stripe_subscription_id is not null) as has_live_subscription,
       c.is_hidden
  from churches c
  left join auth.users u on u.id = c.owner_id
 where c.owner_id is not null
   and u.id is null
 order by c.plan_type desc, c.name;

-- === 3. The same question for the other tables that carry a user id ===
-- Rows whose owner no longer exists. A non-zero count is not
-- necessarily a problem -- a donation should outlive the donor's
-- account, for instance -- but it should be a decision rather than a
-- surprise.
select 'church_staff'        as table_name, count(*) as orphaned_rows from church_staff cs        left join auth.users u on u.id = cs.user_id  where cs.user_id  is not null and u.id is null
union all
select 'church_memberships', count(*) from church_memberships cm left join auth.users u on u.id = cm.user_id where cm.user_id is not null and u.id is null
union all
select 'group_members',      count(*) from group_members gm      left join auth.users u on u.id = gm.user_id where gm.user_id is not null and u.id is null
union all
select 'event_registrations',count(*) from event_registrations er left join auth.users u on u.id = er.user_id where er.user_id is not null and u.id is null
union all
select 'donations',          count(*) from donations d           left join auth.users u on u.id = d.donor_id  where d.donor_id  is not null and u.id is null
union all
select 'profiles',           count(*) from profiles p            left join auth.users u on u.id = p.id        where u.id is null
 order by orphaned_rows desc;
