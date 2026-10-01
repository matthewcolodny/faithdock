-- 120_search_groups_date_range.sql
--
-- Dates on the Groups tab: All / Today / This weekend and a range,
-- the same row Events has. search_groups could not answer it --
-- it neither selects nor filters on any of the meeting_* columns.
--
-- Probed before writing, 2026-10-01, because this folder does not
-- describe the groups table and 089 guessed at one and got five
-- rules wrong. What came back:
--
--   meeting_day_of_week  text   8 of 8 rows populated, English day
--                               names ('Friday', 'Monday', ...)
--   meeting_time         text   8 of 8   (text, not time)
--   meeting_recurrence   text   weekly x5, biweekly x1, monthly x2
--   meeting_date         date   0 populated
--   meeting_repeat_until date   0 populated
--   meeting_exceptions   array  element type not reported
--
--   live signature: p_keyword text, p_church_ids uuid[],
--     p_user_lat double precision, p_user_lng double precision,
--     p_max_distance_miles double precision, p_limit integer,
--     p_offset integer, p_group_tags text[]
--
-- Two things that probe decides, and they are worth reading before
-- trusting the filter:
--
-- 1. A group's date is a RULE, not a date. "Weekly on Friday" has no
--    row in a date range, so this computes whether an occurrence
--    falls inside the range rather than comparing a column to it.
--
-- 2. biweekly and monthly have NO ANCHOR. Nothing in the table says
--    which Friday a biweekly group meets -- meeting_date is null for
--    every recurring group, and there is no start_date. So those
--    three of eight groups are matched on their weekday alone, which
--    is OVER-inclusive: a monthly group will appear for every
--    Wednesday in the range, not only its own.
--
--    Deliberate, and the safer error of the two. A directory that
--    says "this group may meet then" sends someone to a page that
--    gives the real schedule; one that hides a group which does meet
--    that day gives them no way to find out. If an anchor column is
--    ever added (a first_meeting_date), this is the one branch to
--    revisit -- it is marked below.
--
-- Backwards compatible: both new parameters default to null, which
-- means no date filter, so every existing 8-argument call keeps
-- working and this can be run before the client that uses it ships.

-- ---------------------------------------------------------------------
-- The guard. Same shape as 118's: adding parameters to a function
-- creates an OVERLOAD rather than replacing it, and two search_groups
-- would make every call that omits the new arguments ambiguous. So the
-- old one is dropped first -- by its own identity, which cannot be
-- mis-spelled, and only after checking it is the one this was written
-- against.
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

  -- Eight inputs: 118's version. Counted rather than spelled, because
  -- pg_get_function_identity_arguments includes the argument NAMES and
  -- so never matches a bare type list -- the thing that made 118's own
  -- first guard refuse itself.
  if n_args <> 8 then
    raise exception 'ABORT: search_groups takes % arguments, not the 8 this was written against. Found: %', n_args, target;
  end if;

  -- group_tags and meeting_format in the result are what identify
  -- 118's version, which is the body this is an edit of.
  if sig not like '%group_tags%' or sig not like '%meeting_format%' then
    raise exception 'ABORT: the live search_groups does not return group_tags and meeting_format, so it is not the version this was written against. Returns: %', sig;
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
  p_group_tags text[] default null,
  p_from_date date default null,
  p_to_date date default null
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
      -- ---- the date range -------------------------------------------
      -- Either bound alone is a filter; neither is no filter. An open
      -- end is clamped to a year so the series below is always bounded
      -- -- a weekly group matches within the first seven days anyway,
      -- so a longer window answers nothing a shorter one does not.
      and (
        (p_from_date is null and p_to_date is null)
        or exists (
          select 1
          from generate_series(
                 coalesce(p_from_date, p_to_date - 366),
                 least(coalesce(p_to_date, p_from_date + 366),
                       coalesce(p_from_date, p_to_date - 366) + 366),
                 interval '1 day'
               ) as gs(d)
          where
            (
              -- A one-off meets once, on its own date.
              (g.meeting_date is not null and gs.d::date = g.meeting_date)
              or
              -- A recurring group meets on its weekday. REVISIT HERE if
              -- an anchor date is ever added: biweekly and monthly go
              -- through this branch too, with nothing to say which
              -- occurrence is theirs, so they match every instance of
              -- their weekday in the range.
              (
                g.meeting_date is null
                and g.meeting_day_of_week is not null
                and g.meeting_day_of_week = case extract(dow from gs.d)::int
                      when 0 then 'Sunday'    when 1 then 'Monday'
                      when 2 then 'Tuesday'   when 3 then 'Wednesday'
                      when 4 then 'Thursday'  when 5 then 'Friday'
                      else 'Saturday' end
                and (g.meeting_repeat_until is null
                     or gs.d::date <= g.meeting_repeat_until)
              )
            )
            -- Cancelled dates. Compared as text because the probe did
            -- not report the element type: a date[] renders as
            -- YYYY-MM-DD and a text[] of ISO dates matches the same
            -- way, and anything else simply never matches -- which is
            -- the same answer as not checking at all. It can drop an
            -- occurrence that is really cancelled; it can never drop
            -- one that is not.
            and not (
              coalesce(g.meeting_exceptions::text[], '{}'::text[])
                @> array[to_char(gs.d, 'YYYY-MM-DD')]
            )
        )
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

revoke all on function search_groups(text, uuid[], double precision, double precision, double precision, integer, integer, text[], date, date) from public;
grant execute on function search_groups(text, uuid[], double precision, double precision, double precision, integer, integer, text[], date, date) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Verify. Catalog reads and a real call as anon, because auth.uid() is
-- null in the SQL Editor -- a check that calls an admin RPC there
-- proves nothing. One union-all'd select with a section column: the
-- editor returns only the LAST statement's result.
do $$ begin perform set_config('role', 'anon', true); end $$;

select 'signature' as section,
       pg_get_function_identity_arguments(p.oid) as detail
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'search_groups'
union all
select 'overloads', count(*)::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'search_groups'
union all
select 'still invoker', (not bool_or(p.prosecdef))::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'search_groups'
union all
select 'no dates -> all rows', count(*)::text
  from search_groups(p_limit => 100)
union all
select 'today only', count(*)::text
  from search_groups(p_limit => 100,
                     p_from_date => current_date,
                     p_to_date   => current_date)
union all
select 'next 7 days', count(*)::text
  from search_groups(p_limit => 100,
                     p_from_date => current_date,
                     p_to_date   => current_date + 6)
order by 1;
