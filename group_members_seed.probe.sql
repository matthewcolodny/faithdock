-- READ ONLY. One statement. Paste the output back.
--
-- To seed members I need three things I do not have. group_members
-- predates supabase/migrations, so its columns and its allowed
-- status/role values are undocumented; and user_id almost certainly
-- references a real auth account, so members cannot be invented --
-- they have to be accounts that already exist.
--
-- D lists the accounts. If there is only one, a member list can still
-- be seeded and tested, but "approve a pending member" needs a second
-- person, and I will say so rather than seed something that cannot be
-- clicked.

select section, detail1, detail2, detail3
from (
  select 1 ord, 'A. column'::text section, column_name::text detail1,
         (data_type || case when is_nullable = 'YES' then ' null' else ' NOT NULL' end)::text detail2,
         coalesce(column_default, '')::text detail3
    from information_schema.columns
   where table_schema = 'public' and table_name = 'group_members'

  union all
  -- Check constraints give the allowed status and role strings;
  -- foreign keys say what user_id must point at.
  select 2, 'B. constraint'::text, conname::text,
         contype::text, pg_get_constraintdef(oid)::text
    from pg_constraint
   where conrelid = 'public.group_members'::regclass

  union all
  select 3, 'C. groups'::text, g.name::text,
         g.id::text,
         (c.name || ' / ' || (select count(*) from group_members m where m.group_id = g.id)::text || ' members')::text
    from groups g join churches c on c.id = g.church_id
   where g.description like '%[seed]%'

  union all
  -- Every account, so the seed can use real ones. Own database, own
  -- accounts; nothing leaves it.
  select 4, 'D. auth user'::text, u.email::text, u.id::text,
         coalesce(p.full_name, '(no profile row)')::text
    from auth.users u left join profiles p on p.id = u.id
) z
order by ord, detail1
limit 200;
