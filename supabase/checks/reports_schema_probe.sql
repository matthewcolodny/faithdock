-- Run in the Supabase SQL Editor. Reads only -- changes nothing.
--
-- WHY: the Reports page needs "when did this person last do anything",
-- which means reading a timestamp off four tables. Two of them
-- (group_members, donations) predate this repo's migrations, so their
-- real column names are not written down anywhere I can check. The
-- last time a migration was written from a remembered schema it got
-- five things wrong, so this asks instead.
--
-- One result set, because the SQL Editor only shows the last one.

with wanted as (
  select * from (values
    ('church_memberships', 'joined_at'),
    ('church_memberships', 'status'),
    ('church_memberships', 'is_permanent'),
    ('event_registrations', 'created_at'),
    ('event_registrations', 'checked_in_at'),
    ('event_registrations', 'status'),
    ('group_members',       'user_id'),
    ('group_members',       'group_id'),
    ('group_members',       'status'),
    ('group_members',       'joined_at'),
    ('group_members',       'created_at'),
    ('donations',           'donor_id'),
    ('donations',           'created_at'),
    ('donations',           'church_id'),
    ('donations',           'amount_cents'),
    ('donations',           'status')
  ) as t(tbl, col)
),
found as (
  select w.tbl, w.col,
         c.data_type,
         (c.column_name is not null) as present
    from wanted w
    left join information_schema.columns c
      on c.table_schema = 'public'
     and c.table_name = w.tbl
     and c.column_name = w.col
)
select 'column' as kind, tbl as name, col as detail,
       coalesce(data_type, '-') as extra,
       present::text as answer
  from found

union all

-- Does the directory function hand back a group-signup flag? The
-- client reads person.has_group_signup and filters on it; if this says
-- false, that filter has always matched nobody.
select 'rpc_column', 'get_directory_people', 'has_group_signup', '-',
       exists (
         select 1 from information_schema.parameters pm
         join information_schema.routines r on r.specific_name = pm.specific_name
         where r.routine_schema = 'public' and r.routine_name = 'get_directory_people'
           and pm.parameter_name = 'has_group_signup'
       )::text

union all

-- And does it include group-only people at all? Counting how many
-- people are in a group of this church but are not a member, staff,
-- owner or confirmed registrant -- i.e. how many the directory is
-- currently leaving out. Across every church, since this is a
-- structural question, not a per-church one.
select 'row_count', 'people_in_a_group_only', 'not member/staff/owner/registrant', '-',
       (
         select count(distinct gm.user_id)::text
           from group_members gm
           join groups g on g.id = gm.group_id
          where not exists (
                  select 1 from church_memberships cm
                   where cm.user_id = gm.user_id and cm.church_id = g.church_id
                     and cm.is_permanent = true and cm.status = 'approved')
            and not exists (
                  select 1 from church_staff cs
                   where cs.user_id = gm.user_id and cs.church_id = g.church_id)
            and not exists (
                  select 1 from churches c
                   where c.id = g.church_id and c.owner_id = gm.user_id)
            and not exists (
                  select 1 from event_registrations er
                   join events e on e.id = er.event_id
                  where er.user_id = gm.user_id and e.church_id = g.church_id
                    and er.status = 'confirmed')
       )

union all

-- Is a departure recorded anywhere? Membership removal deletes the row
-- (migration 035), so "leave over time" may have no source at all. This
-- looks for any table that would hold one.
select 'table', 'departure log candidates', 'tables matching %member%/%audit%/%log%', '-',
       coalesce((
         select string_agg(table_name, ', ' order by table_name)
           from information_schema.tables
          where table_schema = 'public'
            and (table_name like '%member%' or table_name like '%audit%' or table_name like '%_log%'
                 or table_name like 'log_%' or table_name like '%history%')
       ), 'none')

order by kind, name, detail;
