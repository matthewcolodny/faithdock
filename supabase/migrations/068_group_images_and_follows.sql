-- Run in Supabase SQL Editor. Requires 067 (groups.visibility, search_groups).
--
-- Groups get a picture and a heart, the way churches and events already
-- have both.

-- === 1. The image ===
alter table groups add column if not exists image_url text;

-- groups uses table-wide grants today, in which case this adds nothing.
-- If it is ever moved to per-column grants, a new column would be
-- unreadable without it. Not a way to narrow anything -- see 049.
grant select (image_url) on groups to anon, authenticated;
grant update (image_url) on groups to authenticated;

-- === 2. Its own bucket ===
-- Rather than putting group pictures in `event-images`. The path layout
-- is identical either way, so reuse would have worked -- but a bucket
-- named for events holding group images is exactly the kind of thing
-- that is confusing to find later and painful to separate once there
-- are files in it.
insert into storage.buckets (id, name, public)
values ('group-images', 'group-images', true)
on conflict (id) do nothing;

-- The two policies from 056, restated with the new bucket in the list.
-- They are recreated rather than altered because a policy's USING and
-- WITH CHECK cannot be edited in place, and 056 established that
-- dropping by name and recreating is correct whether the policy was
-- missing, differently named or differently worded.
--
-- Still deliberately NOT granted, for the reasons 056 gives: SELECT
-- (these are public buckets, the object endpoint bypasses RLS, and a
-- read policy only enables LISTING -- which was removed on purpose so
-- nobody with the anon key can enumerate every uploaded file) and
-- DELETE (nothing in the client deletes a stored object).
drop policy if exists "Users can upload to their own folder" on storage.objects;
create policy "Users can upload to their own folder"
  on storage.objects for insert to authenticated
  with check (
    bucket_id in ('profile-photos', 'church-logos', 'event-images', 'group-images')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Users can update their own uploads" on storage.objects;
create policy "Users can update their own uploads"
  on storage.objects for update to authenticated
  using (
    bucket_id in ('profile-photos', 'church-logos', 'event-images', 'group-images')
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id in ('profile-photos', 'church-logos', 'event-images', 'group-images')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- === 3. Following a group ===
-- Modelled on event_follows (038), which was itself modelled on
-- church_follows. Same shape on purpose: to somebody using the site it
-- is the same gesture, and three tables that disagree about how a
-- follow is stored would be three sets of rules to keep in step.
--
-- Scope note, same as 038's: this is "keep an eye on this group". It is
-- NOT membership, does not request to join, and does not interact with
-- a group's join method -- an invite-only group can be followed by
-- somebody who cannot join it, which is arguably when following is most
-- useful.
create table if not exists group_follows (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  group_id uuid not null references groups(id) on delete cascade,
  created_at timestamptz not null default now(),
  -- The natural key, and what lets the client upsert on
  -- (user_id, group_id) rather than inventing a second way to say the
  -- same thing.
  unique (user_id, group_id)
);

create index if not exists group_follows_user_idx on group_follows (user_id);
create index if not exists group_follows_group_idx on group_follows (group_id);

alter table group_follows enable row level security;

-- Three explicit policies rather than one FOR ALL, so widening a single
-- verb later (letting a church see who follows its groups, say) is a
-- change to one policy instead of a rewrite.
drop policy if exists "Users can see their own group follows" on group_follows;
create policy "Users can see their own group follows"
  on group_follows for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "Users can follow a group" on group_follows;
create policy "Users can follow a group"
  on group_follows for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists "Users can unfollow a group" on group_follows;
create policy "Users can unfollow a group"
  on group_follows for delete to authenticated
  using (user_id = auth.uid());

-- REVOKE FIRST. This project's default privileges hand anon and
-- authenticated every privilege on every new table in public, so the
-- grants below would add nothing and narrow nothing on their own --
-- 049's mistake. anon gets nothing: a follow belongs to an account.
revoke all on group_follows from anon;
revoke all on group_follows from authenticated;
grant select, insert, delete on group_follows to authenticated;

-- === 4. search_groups returns the image ===
-- DROP then CREATE, not CREATE OR REPLACE: changing a function's
-- RETURNS TABLE row type is exactly the case REPLACE refuses with
-- 42P13. The body is 067's with one column added.
drop function if exists search_groups(text, uuid[], double precision, double precision, double precision, integer, integer);

create function search_groups(
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
  image_url text,
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
      g.join_method::text, g.visibility::text, g.image_url::text,
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
      (
        g.visibility = 'public'
        or exists (
          select 1 from church_memberships cm
          where cm.church_id = g.church_id
            and cm.user_id = auth.uid()
            and cm.status = 'approved'
        )
      )
      and coalesce(c.is_hidden, false) = false
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
    f.id, f.name, f.description, f.meeting_schedule, f.join_method, f.visibility, f.image_url,
    f.church_id, f.church_name, f.church_city, f.church_state,
    f.computed_distance_miles, f.member_count,
    count(*) over() as total_count
  from final f
  order by
    case when p_user_lat is null then null else f.computed_distance_miles end asc nulls last,
    f.name asc, f.id asc
  limit p_limit offset p_offset
$fn$;

revoke all on function search_groups(text, uuid[], double precision, double precision, double precision, integer, integer) from public;
grant execute on function search_groups(text, uuid[], double precision, double precision, double precision, integer, integer) to anon, authenticated;

notify pgrst, 'reload schema';

do $verify$
begin
  if not exists (select 1 from information_schema.columns
                  where table_name = 'groups' and column_name = 'image_url') then
    raise exception 'VERIFY FAILED: groups.image_url was not added.';
  end if;

  if not exists (select 1 from storage.buckets where id = 'group-images') then
    raise exception 'VERIFY FAILED: the group-images bucket was not created.';
  end if;

  -- The bucket must be public, or every group image 404s for visitors
  -- while the upload itself looks like it worked.
  if not exists (select 1 from storage.buckets where id = 'group-images' and public) then
    raise exception 'VERIFY FAILED: group-images exists but is not public.';
  end if;

  -- The upload policy must actually name the new bucket. Recreating a
  -- policy that then omits it would leave uploads failing with the same
  -- RLS error 056 was written to fix.
  if not exists (
    select 1 from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname = 'Users can upload to their own folder'
       and with_check like '%group-images%'
  ) then
    raise exception 'VERIFY FAILED: the upload policy does not include group-images.';
  end if;

  if not has_function_privilege('anon', 'search_groups(text, uuid[], double precision, double precision, double precision, integer, integer)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon cannot execute search_groups.';
  end if;
  if has_table_privilege('anon', 'group_follows', 'SELECT') then
    raise exception 'VERIFY FAILED: anon can read group_follows.';
  end if;
  if not has_table_privilege('authenticated', 'group_follows', 'INSERT') then
    raise exception 'VERIFY FAILED: signed-in users cannot follow a group.';
  end if;

  raise notice 'OK: group images, the group-images bucket, and group follows are in place.';
end
$verify$;
