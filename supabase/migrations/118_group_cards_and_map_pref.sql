-- Run in Supabase SQL Editor. Run 117 first.
--
-- Two things a card needs, and one setting that should follow the
-- person rather than the browser.
--
-- ---------------------------------------------------------------------
-- MEASURED FIRST, NOT ASSUMED
--
-- The repo holds two definitions of search_groups -- 067 wrote one,
-- 068 dropped it and wrote another with image_url -- so the repo alone
-- could not say which was running. Probed 2026-09-30:
--
--   live:    search_groups(text, uuid[], double precision,
--                          double precision, double precision,
--                          integer, integer)
--   returns: 14 columns, image_url included  -> 068's is the live one
--   prosecdef: false                          -> SECURITY INVOKER
--
-- SECURITY INVOKER matters and is kept. The function reads groups and
-- churches directly, so it is migration 116's RLS policy that decides
-- which members-only groups a caller sees. Making it DEFINER here
-- would quietly undo 116.
--
-- Every column the new return type reads was checked present:
-- churches.address/city/state text, churches.lat/lng double precision,
-- groups.group_tags ARRAY, groups.meeting_format text.
--
-- profiles has no map or display preference column under any name.
--
-- ---------------------------------------------------------------------
-- WHAT CHANGES, AND WHY EACH
--
-- church_address, church_lat, church_lng
--   A group meets at its church, and the card offers Directions. It
--   currently builds a destination string out of "church name, city,
--   state", which is a search query and lands wherever Google decides.
--   Coordinates land exactly; the address is the fallback when a
--   church has not been geocoded. Neither costs us a geocode -- the
--   link hands Google a destination and Google resolves it when it is
--   opened. Our geocoding is for drawing pins and measuring distance.
--
-- group_tags, meeting_format
--   The card has no tag today, because these are the tags and there
--   was no way to read them. A church card leads with its
--   denomination and an event with when it is; a group leads with
--   what it is and whether it meets online.
--
-- p_group_tags
--   The browse filter currently fetches matching ids with a direct
--   .overlaps() on groups from the client, then narrows the page it
--   got back. That is a second reader of the same RLS policy, and its
--   cached ids are what stayed applied across a sign-out (fixed in
--   the client, but the query is still there). With the filter inside
--   the function, the count and the paging are right and the direct
--   read can go.
--
--   It is added with a DEFAULT so a call that omits it still resolves.
--   The client keeps using the old path until this has actually run;
--   shipping a call to a parameter that does not exist yet would take
--   the Groups tab out entirely.

-- The drop is dynamic, by OID, rather than by a written-out argument
-- list. The first attempt at this named the types and was refused by
-- its own guard: pg_get_function_identity_arguments includes argument
-- NAMES as well as types -- it is what pg_dump uses to write
-- "DROP FUNCTION public.f(p_keyword text, ...)" -- so it returns
-- "p_keyword text, p_church_ids uuid[], ..." and never matches a bare
-- list of types.
--
-- Matching a rendered string was the wrong test anyway. What actually
-- has to be true is checked directly below, and then the one function
-- that exists is dropped by its own identity, which cannot be
-- mis-spelled.
do $$
declare
  n_overloads int;
  target      text;
  sig         text;
  is_definer  boolean;
  n_args      int;
begin
  select count(*) into n_overloads
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'search_groups';

  if n_overloads <> 1 then
    raise exception 'ABORT: expected exactly one search_groups, found %. Dropping one would leave another answering calls.', n_overloads;
  end if;

  select p.oid::regprocedure::text, p.prosecdef, p.pronargs,
         pg_get_function_result(p.oid)
    into target, is_definer, n_args, sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'search_groups';

  -- Seven inputs, counted rather than spelled.
  if n_args <> 7 then
    raise exception 'ABORT: search_groups takes % arguments, not the 7 this was written against. Found: %', n_args, target;
  end if;

  -- image_url in the result is what identifies this as 068's version,
  -- which is the body the new one is an edit of. 067's had no such
  -- column.
  if sig not like '%image_url%' then
    raise exception 'ABORT: the live search_groups does not return image_url, so it is not the version this was written against. Returns: %', sig;
  end if;

  if is_definer then
    raise exception 'ABORT: search_groups is SECURITY DEFINER now. It was invoker when this was written, and 116 depends on that.';
  end if;

  raise notice 'Dropping %', target;
  execute 'drop function ' || target;
end $$;

create function search_groups(
  p_keyword text default null,
  p_church_ids uuid[] default null,
  p_user_lat double precision default null,
  p_user_lng double precision default null,
  p_max_distance_miles double precision default null,
  p_limit integer default 24,
  p_offset integer default 0,
  p_group_tags text[] default null
)
returns table(
  id uuid,
  name text,
  description text,
  meeting_schedule text,
  join_method text,
  visibility text,
  image_url text,
  group_tags text[],
  meeting_format text,
  church_id uuid,
  church_name text,
  church_city text,
  church_state text,
  church_address text,
  church_lat double precision,
  church_lng double precision,
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
      coalesce(g.group_tags, '{}'::text[]) as group_tags,
      g.meeting_format::text,
      c.id as church_id, c.name::text as church_name,
      c.city::text as church_city, c.state::text as church_state,
      c.address::text as church_address,
      c.lat as church_lat, c.lng as church_lng,
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
      -- Overlap, not containment: ticking three categories means "any
      -- of these", which is what the chips above the list say and what
      -- the client's own .overlaps() did.
      and (p_group_tags is null or cardinality(p_group_tags) = 0
           or g.group_tags && p_group_tags)
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
    f.group_tags, f.meeting_format,
    f.church_id, f.church_name, f.church_city, f.church_state,
    f.church_address, f.church_lat, f.church_lng,
    f.computed_distance_miles, f.member_count,
    count(*) over() as total_count
  from final f
  order by
    case when p_user_lat is null then null else f.computed_distance_miles end asc nulls last,
    f.name asc, f.id asc
  limit p_limit offset p_offset
$fn$;

revoke all on function search_groups(text, uuid[], double precision, double precision, double precision, integer, integer, text[]) from public;
grant execute on function search_groups(text, uuid[], double precision, double precision, double precision, integer, integer, text[]) to anon, authenticated;

-- ---------------------------------------------------------------------
-- The map preference, on the account.
--
-- Nullable with no default, on purpose. NULL means "this person has
-- never set it", and the client leaves the browser's own copy alone
-- when it reads NULL. A default of false would say "they chose to
-- hide the shops", which is a different statement and would overwrite
-- a choice made before they signed in.
alter table profiles add column if not exists map_show_pois boolean;

-- Small, single-purpose, SECURITY DEFINER -- the shape every other
-- self-read and self-write on this table already has
-- (get_my_account_type, get_my_private_profile, update_profile_name,
-- all measured DEFINER).
--
-- DEFINER is doing real work here, not ceremony: migration 117 has
-- just revoked UPDATE on profiles from authenticated, so the setter
-- below is the ONLY way this column can be written from the browser.
-- That is the point of the pattern -- one named door per field,
-- scoped internally to auth.uid(), instead of a grant that trusts a
-- policy to decide which row.
--
-- With no session auth.uid() is null, which matches no row: the
-- getter returns nothing and the setter updates nothing. Both are
-- harmless no-ops rather than errors, which is what 012b's functions
-- do too.
create or replace function get_my_map_pois()
returns boolean
language sql
security definer
set search_path = public
as $$
  select map_show_pois from profiles where id = auth.uid();
$$;
revoke all on function get_my_map_pois() from public;
grant execute on function get_my_map_pois() to authenticated;

create or replace function set_my_map_pois(p_on boolean)
returns void
language sql
security definer
set search_path = public
as $$
  update profiles set map_show_pois = p_on where id = auth.uid();
$$;
revoke all on function set_my_map_pois(boolean) from public;
grant execute on function set_my_map_pois(boolean) to authenticated;

-- ---------------------------------------------------------------------
-- Verification. Catalog reads and one anon call -- no admin RPC, since
-- auth.uid() is null in the SQL Editor and is_platform_admin() would
-- always be false there.
do $$
declare
  cols      text;
  anon_rows int;
  with_addr int;
begin
  -- The rendered return type, rather than walking proargmodes --
  -- those catalog arrays are null for some function shapes and a
  -- verify block that errors on its own query proves nothing.
  select pg_get_function_result(p.oid) into cols
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'search_groups';

  if cols not like '%church_address%' or cols not like '%church_lat%'
     or cols not like '%group_tags%' or cols not like '%meeting_format%' then
    raise exception 'VERIFY FAILED: the new columns are not in the return type. Got: %', cols;
  end if;

  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'search_groups' and p.prosecdef) then
    raise exception 'VERIFY FAILED: search_groups came back SECURITY DEFINER. 116 depends on it being invoker.';
  end if;

  -- What a signed-out visitor actually gets. postgres bypasses RLS, so
  -- counting as postgres would prove nothing.
  set local role anon;
  select count(*), count(*) filter (where church_address is not null)
    into anon_rows, with_addr
    from search_groups(null, null, null, null, null, 200, 0);
  reset role;

  raise notice 'anon sees % groups, % of them with a church address.', anon_rows, with_addr;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'profiles'
                    and column_name = 'map_show_pois') then
    raise exception 'VERIFY FAILED: profiles.map_show_pois was not added.';
  end if;

  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'set_my_map_pois' and p.prosecdef) then
    raise exception 'VERIFY FAILED: set_my_map_pois is missing or is not SECURITY DEFINER -- 117 revoked the UPDATE grant, so it would have no way to write.';
  end if;

  raise notice 'OK. search_groups returns the church location and the group tags; the map preference has a home.';
  raise notice 'Check next: the Groups tab still lists groups, and Directions on a group card opens the church address.';
end $$;

-- ---------------------------------------------------------------------
-- ROLLBACK. Restores the function exactly as probed, and leaves the
-- profiles column in place (an unread nullable column harms nothing,
-- and dropping it would throw away anyone's saved preference):
--
--   drop function if exists search_groups(text, uuid[], double precision,
--     double precision, double precision, integer, integer, text[]);
--
-- then re-run migration 068's search_groups block.
