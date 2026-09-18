-- Run in Supabase SQL Editor.
--
-- Public group discovery: a visibility setting, and the search behind a
-- platform-wide Groups page.
--
-- === What exists today ===
-- Nothing marks a group as public or not. The church profile page does
--     from('groups').select('*').eq('church_id', churchId)
-- so every group a church has ever created is already visible to every
-- anonymous visitor. `groups` predates this repo's migrations, and 046
-- only added the church-level groups_enabled switch, not a per-group
-- one.
--
-- So "public groups, plus groups you can see because you are a member"
-- is a distinction that does not exist yet and has to be created before
-- a search can honour it.

-- === visibility ===
-- Defaults to 'public', which is exactly what every group already is.
-- Running this changes nothing about who can see what -- the same rule
-- 046 set for itself, and worth keeping: a migration that quietly hides
-- a church's groups from its own page would be a bad trade for a tidier
-- default.
alter table groups add column if not exists visibility text not null default 'public';
alter table groups drop constraint if exists groups_visibility_check;
alter table groups add constraint groups_visibility_check
  check (visibility in ('public', 'members'));

-- A new column on a table using per-column grants is unreadable until
-- granted, and one on a table with table-wide grants is already covered
-- -- this is a no-op in the second case rather than a mistake. What it
-- is NOT is a way to narrow anything: see 049 for that error. anon is
-- included because the church profile page renders groups for signed-
-- out visitors.
grant select (visibility) on groups to anon, authenticated;
grant update (visibility) on groups to authenticated;

-- === search_groups ===
-- Deliberately shaped like search_events, including SECURITY INVOKER:
-- this is a public discovery feed and RLS should apply as the caller,
-- the same as the events one. The visibility test below mirrors the
-- private-event test in search_events almost line for line, because it
-- is the same question about a different table.
drop function if exists search_groups(text, uuid[], double precision, double precision, double precision, integer, integer);

create or replace function search_groups(
  p_keyword text default null,
  p_church_ids uuid[] default null,
  p_user_lat double precision default null,
  p_user_lng double precision default null,
  p_max_distance_miles double precision default null,
  p_limit integer default 24,
  p_offset integer default 0
)
returns table(
  id uuid,
  name text,
  description text,
  meeting_schedule text,
  join_method text,
  visibility text,
  church_id uuid,
  church_name text,
  church_city text,
  church_state text,
  distance_miles double precision,
  member_count bigint,
  total_count bigint
)
language sql
stable
as $fn$
  with bounded as (
    select
      g.id, g.name::text, g.description::text, g.meeting_schedule::text,
      g.join_method::text, g.visibility::text,
      c.id as church_id, c.name::text as church_name,
      c.city::text as church_city, c.state::text as church_state,
      (select count(*) from group_members gm
        where gm.group_id = g.id and gm.status = 'active') as member_count,
      case when p_user_lat is not null and c.lat is not null and c.lng is not null then
        3958.8 * acos(least(1, greatest(-1,
          cos(radians(p_user_lat)) * cos(radians(c.lat)) * cos(radians(c.lng) - radians(p_user_lng))
          + sin(radians(p_user_lat)) * sin(radians(c.lat))
        )))
      else null end as computed_distance_miles
    from groups g
    join churches c on c.id = g.church_id
    where
      -- A group you can see because the church chose to show it, or
      -- because you are actually a member of that church. Same shape as
      -- search_events' public/private test.
      (
        g.visibility = 'public'
        or exists (
          select 1 from church_memberships cm
          where cm.church_id = g.church_id
            and cm.user_id = auth.uid()
            and cm.status = 'approved'
        )
      )
      -- A hidden church is hidden everywhere, not just in the church
      -- directory.
      and coalesce(c.is_hidden, false) = false
      -- And a church that switched Groups off (046) must not have its
      -- groups surface here either. Its own page stops showing the tab;
      -- a platform-wide search that ignored that would put the groups
      -- back in front of people by another door.
      and coalesce(c.groups_enabled, true) = true
      and (p_church_ids is null or g.church_id = any(p_church_ids))
      and (
        p_keyword is null or p_keyword = ''
        or g.name ilike '%' || p_keyword || '%'
        or g.description ilike '%' || p_keyword || '%'
        or c.name ilike '%' || p_keyword || '%'
      )
      and (
        p_user_lat is null or p_max_distance_miles is null or p_max_distance_miles <= 0
        or (
          c.lat is not null and c.lng is not null
          and c.lat between p_user_lat - (p_max_distance_miles / 69.0) and p_user_lat + (p_max_distance_miles / 69.0)
          and c.lng between p_user_lng - (p_max_distance_miles / (69.0 * cos(radians(p_user_lat)))) and p_user_lng + (p_max_distance_miles / (69.0 * cos(radians(p_user_lat))))
        )
      )
  ),
  final as (
    select * from bounded
    where p_user_lat is null or p_max_distance_miles is null or p_max_distance_miles <= 0
      or computed_distance_miles is null or computed_distance_miles <= p_max_distance_miles
  )
  select
    f.id, f.name, f.description, f.meeting_schedule, f.join_method, f.visibility,
    f.church_id, f.church_name, f.church_city, f.church_state,
    f.computed_distance_miles, f.member_count,
    count(*) over() as total_count
  from final f
  -- Nearest first when a location was given, otherwise alphabetical.
  -- A stable secondary key either way, so paging cannot repeat or skip
  -- a row the way an unordered offset can.
  order by
    case when p_user_lat is null then null else f.computed_distance_miles end asc nulls last,
    f.name asc, f.id asc
  limit p_limit offset p_offset
$fn$;

-- Readable by signed-out visitors: this is public discovery, and the
-- function's own WHERE clause is what decides which rows that means.
revoke all on function search_groups(text, uuid[], double precision, double precision, double precision, integer, integer) from public;
grant execute on function search_groups(text, uuid[], double precision, double precision, double precision, integer, integer) to anon, authenticated;

notify pgrst, 'reload schema';

do $verify$
declare
  v_public int;
  v_members int;
begin
  if not exists (select 1 from information_schema.columns
                  where table_name = 'groups' and column_name = 'visibility') then
    raise exception 'VERIFY FAILED: groups.visibility was not added.';
  end if;

  -- Both directions, as usual: anon must be able to run it (it is the
  -- public feed) and the column must be readable or every card comes
  -- back without its own visibility.
  if not has_function_privilege('anon', 'search_groups(text, uuid[], double precision, double precision, double precision, integer, integer)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon cannot execute search_groups, so the public page would be empty.';
  end if;
  if not has_column_privilege('anon', 'groups', 'visibility', 'SELECT') then
    raise exception 'VERIFY FAILED: anon cannot read groups.visibility.';
  end if;

  -- Nothing should have been hidden by running this.
  select count(*) filter (where visibility = 'public'),
         count(*) filter (where visibility = 'members')
    into v_public, v_members
    from groups;
  if v_members > 0 then
    raise exception 'VERIFY FAILED: % group(s) came out as members-only, but the default is public.', v_members;
  end if;

  raise notice 'OK: % group(s), all still public. search_groups is callable by anon.', v_public;
end
$verify$;
