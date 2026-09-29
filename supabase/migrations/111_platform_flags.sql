-- Run in Supabase SQL Editor.
--
-- A switch board for features that are built but not ready to be seen.
--
-- ---------------------------------------------------------------------
-- WHY THIS EXISTS
--
-- Church descriptor tags (migration 110) work, but churches.church_tags
-- is empty on every row until churches fill it in. A "By Category"
-- filter over an empty column is a filter that returns nothing for every
-- choice, which reads as broken rather than as early. So the button is
-- built and left switched off, and switched on from the admin page once
-- enough churches have set tags.
--
-- A flag, not a build-time constant: index.html is served straight from
-- the repo by Cloudflare Pages, so flipping a constant means a commit, a
-- build and a cache cycle. This is a row.
--
-- ---------------------------------------------------------------------
-- WHO CAN DO WHAT
--
-- Anyone who can see the directory can READ the flags -- the signed-out
-- visitor is exactly who needs to know whether to draw the button. Only
-- a platform admin can write one.
--
-- Nothing secret goes in here. It is readable by anon by design, so a
-- flag name is a public statement that the feature exists.

do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'is_platform_admin') then
    raise exception 'ABORT: is_platform_admin() is missing; the write policy would have nothing to check.';
  end if;
end $$;

create table if not exists platform_flags (
  key        text primary key,
  enabled    boolean     not null default false,
  note       text,
  updated_at timestamptz not null default now()
);

alter table platform_flags enable row level security;

-- Dropped and recreated rather than "if not exists": a policy that
-- already exists with a different body would otherwise be left in place,
-- and permissive policies OR together, so a stale one cannot be ignored.
drop policy if exists platform_flags_read on platform_flags;
create policy platform_flags_read on platform_flags
  for select to anon, authenticated using (true);

drop policy if exists platform_flags_write on platform_flags;
create policy platform_flags_write on platform_flags
  for all to authenticated
  using (is_platform_admin()) with check (is_platform_admin());

grant select on platform_flags to anon, authenticated;
grant insert, update, delete on platform_flags to authenticated;

-- Off. The whole point is that it starts off.
insert into platform_flags (key, enabled, note)
values ('church_categories', false,
        'Shows the By Category button in the churches directory. Switch on once enough churches have set descriptor tags -- see migration 110.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
do $$
declare
  n_policies integer;
  n_rows     integer;
  is_on      boolean;
begin
  -- Deliberately does NOT call is_platform_admin(): auth.uid() is null
  -- in the SQL Editor, so it would return false here and prove nothing.
  select count(*) into n_policies from pg_policies
   where schemaname = 'public' and tablename = 'platform_flags';
  if n_policies <> 2 then
    raise exception 'VERIFY FAILED: expected exactly 2 policies on platform_flags, found %.', n_policies;
  end if;

  select count(*) into n_rows from platform_flags;
  select enabled into is_on from platform_flags where key = 'church_categories';
  if is_on is null then
    raise exception 'VERIFY FAILED: the church_categories flag was not inserted.';
  end if;

  raise notice 'OK. platform_flags has % row(s); church_categories is %.',
    n_rows, case when is_on then 'ON' else 'OFF' end;
  raise notice 'Turn it on from the admin page, not from here -- the page writes as you, which is what the policy checks.';
end $$;
