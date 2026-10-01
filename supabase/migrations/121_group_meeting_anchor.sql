-- 121_group_meeting_anchor.sql
--
-- Makes the date filter 120 added EXACT. 120 matched every recurring
-- group on its weekday alone, so a group that meets once a month
-- showed for all four of them.
--
-- ---------------------------------------------------------------------
-- REWRITTEN before it was ever run. The first version of this file was
-- wrong, and wrong in a way that would have hidden groups rather than
-- over-showing them. Recording why, because the mistake is instructive.
--
-- I probed the DATA and wrote against what came back:
--
--   meeting_recurrence: weekly x5, biweekly x1, monthly x2
--
-- and concluded that monthly groups carry no ordinal, so an anchor
-- column was needed to work out which Wednesday they meet.
--
-- I had not probed the FORM. index.html's group editor offers:
--
--   once | weekly | first | second | third | fourth | last
--
-- There is no "biweekly" and no "monthly" in it. The ordinal is in the
-- recurrence value itself -- "every 2nd Tuesday" is stored as
-- 'second' -- so for anything the app can create, no anchor is needed
-- at all. biweekly and monthly are LEGACY values on three old rows.
--
-- The first version handled only 'biweekly' and 'monthly'. Every group
-- made with the current form would have fallen through all of its
-- branches and matched NO date, disappearing from Today, This weekend
-- and every range. That is the failure a data-only probe could not
-- show, and reading the writer is what caught it.
--
-- ---------------------------------------------------------------------
-- What this does now
--
--   once                      the one date in meeting_date
--   weekly                    every matching weekday
--   first/second/third/fourth that ordinal weekday of the month
--   last                      the last matching weekday of the month
--   biweekly  (legacy, 1 row) every 14 days from meeting_anchor_date
--   monthly   (legacy, 2 rows) weekday only -- see below
--
-- 'monthly' says which weekday but not which one of them, and nothing
-- in the table can recover it. Those two rows keep 120's
-- over-inclusive behaviour rather than being guessed at. The fix is
-- not SQL: open each one in the group editor and re-save it, which
-- rewrites meeting_recurrence to a real ordinal and makes it exact
-- from then on. The verify block names them.
--
-- Over-inclusive stays the deliberate choice for anything unknown. A
-- list saying a group may meet then sends someone to a page with the
-- real schedule; hiding one that does meet gives them no way to find
-- out.
--
-- meeting_anchor_date is added for biweekly, which is the one pattern
-- that genuinely cannot be derived -- "every other Saturday" needs to
-- know which Saturday the series started on. Backfilled from
-- created_at, which is a derivation and not a fact, so the verify
-- block prints it.
--
-- Backwards compatible: same ten arguments and the same result as 120,
-- so this REPLACES rather than drops, and nothing has to be re-granted.
--
-- NO SEMICOLON INSIDE A STRING LITERAL anywhere in this file. The
-- Supabase SQL Editor splits a script on semicolons without noticing
-- it is inside quotes, so one in the comment-on text below cut that
-- statement in half and everything after it arrived as an
-- unterminated fragment -- reported as "syntax error at end of input"
-- at LINE 0. 120 ran first time because it had no comment-on at all.

-- ---------------------------------------------------------------------
alter table groups add column if not exists meeting_anchor_date date;

comment on column groups.meeting_anchor_date is
  'First meeting of a biweekly series -- every 14th day from it is a meeting. Not used by weekly or by the first/second/third/fourth/last ordinals, which say which occurrence on their own. Null falls back to weekday-only matching.';

-- Biweekly only. Everything else carries its own rule.
update groups g
   set meeting_anchor_date = (
     select d::date
       from generate_series(g.created_at::date, g.created_at::date + 6, interval '1 day') as s(d)
      where g.meeting_day_of_week = case extract(dow from d)::int
              when 0 then 'Sunday'    when 1 then 'Monday'
              when 2 then 'Tuesday'   when 3 then 'Wednesday'
              when 4 then 'Thursday'  when 5 then 'Friday'
              else 'Saturday' end
      limit 1
   )
 where g.meeting_anchor_date is null
   and g.meeting_recurrence = 'biweekly'
   and g.meeting_day_of_week is not null
   and g.created_at is not null;

-- ---------------------------------------------------------------------
do $$
declare
  n_overloads int;
  n_args      int;
  sig         text;
  is_definer  boolean;
begin
  select count(*) into n_overloads
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'search_groups';

  if n_overloads <> 1 then
    raise exception 'ABORT: expected exactly one search_groups, found %.', n_overloads;
  end if;

  select p.pronargs, pg_get_function_result(p.oid), p.prosecdef
    into n_args, sig, is_definer
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'search_groups';

  -- Ten: 120's version, the one that already takes the date range.
  if n_args <> 10 then
    raise exception 'ABORT: search_groups takes % arguments, not the 10 this was written against. Run 120 first.', n_args;
  end if;

  if sig not like '%group_tags%' or sig not like '%meeting_format%' then
    raise exception 'ABORT: the live search_groups does not return group_tags and meeting_format. Returns: %', sig;
  end if;

  if is_definer then
    raise exception 'ABORT: search_groups is SECURITY DEFINER now. It was invoker when this was written, and 116 depends on that.';
  end if;
end $$;

create or replace function search_groups(
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
      and (p_group_tags is null or cardinality(p_group_tags) = 0
           or g.group_tags && p_group_tags)
      and (
        p_keyword is null or p_keyword = ''
        or g.name ilike '%' || p_keyword || '%'
        or g.description ilike '%' || p_keyword || '%'
        or c.name ilike '%' || p_keyword || '%'
      )
      -- ---- the date range -------------------------------------------
      -- A group's date is a rule, not a date, so this asks whether an
      -- OCCURRENCE falls inside the range. Either bound alone is a
      -- filter; neither is no filter. An open end is clamped to a year
      -- so the series is bounded -- every pattern here repeats within
      -- 31 days, so a longer window answers nothing a shorter one does.
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
                and (
                  -- Every one of them.
                  coalesce(g.meeting_recurrence, 'weekly') = 'weekly'

                  -- The ordinal is the recurrence value itself. This is
                  -- what the group editor writes, so it covers every
                  -- group the app can create.
                  or (
                    g.meeting_recurrence in ('first','second','third','fourth')
                    and ceil(extract(day from gs.d) / 7.0) = case g.meeting_recurrence
                          when 'first' then 1 when 'second' then 2
                          when 'third' then 3 else 4 end
                  )
                  -- Adding a week would leave the month, so this is the
                  -- last one in it.
                  or (
                    g.meeting_recurrence = 'last'
                    and extract(day from gs.d) + 7 >
                        extract(day from (date_trunc('month', gs.d) + interval '1 month' - interval '1 day'))
                  )

                  -- Legacy. 'biweekly' is not in the editor and cannot
                  -- be derived, so it rides on the anchor.
                  or (
                    g.meeting_recurrence = 'biweekly'
                    and g.meeting_anchor_date is not null
                    and gs.d::date >= g.meeting_anchor_date
                    and ((gs.d::date - g.meeting_anchor_date) % 14) = 0
                  )

                  -- Legacy. 'monthly' names a weekday and not which one
                  -- of them, and nothing in the table can recover it.
                  -- Keeps 120's weekday-only match rather than a guess;
                  -- re-saving the group in the editor rewrites it to a
                  -- real ordinal and it becomes exact.
                  or g.meeting_recurrence = 'monthly'

                  -- Anything else unrecognised: show it rather than
                  -- hide it. This is the branch whose absence would
                  -- have made every first/second/third/fourth/last
                  -- group vanish.
                  or g.meeting_recurrence is not null
                     and g.meeting_recurrence not in
                         ('weekly','once','first','second','third','fourth','last','biweekly')
                )
              )
            )
            -- Cancelled dates. Compared as text because the element
            -- type is not recorded: a date[] renders as YYYY-MM-DD and
            -- a text[] of ISO dates matches the same way, and anything
            -- else never matches -- the same answer as not checking.
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

-- ---------------------------------------------------------------------
-- Verify. Catalog reads and real calls as anon, because auth.uid() is
-- null in the SQL Editor. One union-all'd select with a section
-- column: the editor returns only the LAST statement's result.
--
-- The rows to actually read:
--   "re-save these"  the legacy monthly groups, still weekday-only
--   "biweekly anchor" the one derived date in here
do $$ begin perform set_config('role', 'anon', true); end $$;

select 'recurrence in use' as section,
       coalesce(meeting_recurrence, '(null)') || '  x' || count(*)::text as detail
  from public.groups group by meeting_recurrence
union all
select 're-save these',
       name || ' | monthly on ' || coalesce(meeting_day_of_week, '-')
       || ' | still weekday-only'
  from public.groups
 where meeting_recurrence = 'monthly'
union all
select 'biweekly anchor',
       name || ' | anchor ' || coalesce(meeting_anchor_date::text, '(none)')
  from public.groups
 where meeting_recurrence = 'biweekly'
union all
select 'no dates -> all rows', count(*)::text
  from search_groups(p_limit => 100)
union all
select 'today', count(*)::text
  from search_groups(p_limit => 100,
                     p_from_date => current_date, p_to_date => current_date)
union all
select 'this coming saturday', count(*)::text
  from search_groups(p_limit => 100,
                     p_from_date => current_date + ((6 - extract(dow from current_date)::int + 7) % 7),
                     p_to_date   => current_date + ((6 - extract(dow from current_date)::int + 7) % 7))
union all
select 'next 31 days', count(*)::text
  from search_groups(p_limit => 100,
                     p_from_date => current_date, p_to_date => current_date + 30)
order by 1, 2;
