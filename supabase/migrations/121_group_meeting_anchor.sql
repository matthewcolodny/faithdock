-- 121_group_meeting_anchor.sql
--
-- Makes the date filter 120 added EXACT for biweekly and monthly
-- groups. 120 matched them on weekday alone -- a monthly group showed
-- for every Wednesday in the range -- because nothing in the table
-- said WHICH Wednesday. This adds the missing fact and uses it.
--
-- Probed before writing, 2026-10-01:
--
--   created_at  timestamptz, populated on 8 of 8 rows, earliest
--               2026-09-30
--   the three without an anchor:
--     Men's Prayer Breakfast  monthly  Saturday   created 2026-09-30
--     Saturday Serve Team     biweekly Saturday   created 2026-09-30
--     Seniors Book Club       monthly  Wednesday  created 2026-09-30
--
-- ---------------------------------------------------------------------
-- What the anchor is, and what it is not
--
-- meeting_anchor_date is the first meeting of the series. From it the
-- rest follows: biweekly is every fourteenth day from it, monthly is
-- the same weekday-of-month ordinal as it.
--
-- For rows that already exist there is NOTHING to recover -- no column
-- records when a series started -- so the backfill is a derivation,
-- not a fact: the first matching weekday on or after created_at. For
-- the three above that is a guess, and it is worth checking: the
-- verify block at the bottom prints what each one got. The form will
-- ask for new groups, so this guess applies to these rows only.
--
-- The trap the probe caught: 2026-09-30 is a WEDNESDAY, so Seniors
-- Book Club -- monthly on Wednesday -- anchors on day 30 of the
-- month, which is the FIFTH Wednesday. Most months have four. Matched
-- literally, that group would almost never appear, which is a worse
-- answer than the over-inclusive one 120 gave.
--
-- So a fifth occurrence is read as "the last one in the month", which
-- is how scheduling tools treat it and is a real schedule someone
-- might keep. Ordinals one to four are matched exactly; every month
-- has at least four of every weekday, so those never go missing.
--
-- Rows with no anchor fall back to 120's weekday-only behaviour rather
-- than vanishing. Over-inclusive is still the safer error: a list that
-- says a group may meet then sends someone to a page with the real
-- schedule, while hiding one that does meet gives them no way to find
-- out.

-- ---------------------------------------------------------------------
alter table groups add column if not exists meeting_anchor_date date;

comment on column groups.meeting_anchor_date is
  'First meeting of a recurring series. Biweekly repeats every 14 days from it; monthly repeats on the same weekday ordinal as it, where a 5th occurrence means the last one in the month. Null falls back to weekday-only matching.';

-- The backfill. Recurring rows only -- a one-off already carries its
-- date in meeting_date -- and only where it is still null, so running
-- this twice changes nothing.
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
   and g.meeting_day_of_week is not null
   and g.meeting_date is null
   and g.created_at is not null;

-- ---------------------------------------------------------------------
-- The function. Same ten arguments and the same result as 120, so this
-- REPLACES rather than drops and recreates -- no overload is possible
-- and nothing has to be re-granted. The guard only checks that what is
-- live is what this was written against.
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
      -- Overlap, not containment: ticking three categories means "any
      -- of these", which is what the chips above the list say.
      and (p_group_tags is null or cardinality(p_group_tags) = 0
           or g.group_tags && p_group_tags)
      and (
        p_keyword is null or p_keyword = ''
        or g.name ilike '%' || p_keyword || '%'
        or g.description ilike '%' || p_keyword || '%'
        or c.name ilike '%' || p_keyword || '%'
      )
      -- ---- the date range, exactly -----------------------------------
      -- A group's date is a rule, not a date, so this asks whether an
      -- OCCURRENCE falls inside the range. Either bound alone is a
      -- filter; neither is no filter. An open end is clamped to a year
      -- so the series is always bounded -- every recurrence pattern
      -- here repeats within 31 days, so a longer window answers
      -- nothing a shorter one does not.
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
                -- The series has started and has not ended.
                and (g.meeting_anchor_date is null
                     or gs.d::date >= g.meeting_anchor_date)
                and (g.meeting_repeat_until is null
                     or gs.d::date <= g.meeting_repeat_until)
                and (
                  -- Weekly is every one of them, so the weekday match
                  -- above is the whole answer.
                  coalesce(g.meeting_recurrence, 'weekly') = 'weekly'
                  -- No anchor: fall back to 120's weekday-only match
                  -- rather than hiding the group.
                  or g.meeting_anchor_date is null
                  -- Every fourteenth day from the first meeting.
                  or (
                    g.meeting_recurrence = 'biweekly'
                    and ((gs.d::date - g.meeting_anchor_date) % 14) = 0
                  )
                  -- The same weekday ordinal as the first meeting --
                  -- "the second Tuesday", "the last Wednesday".
                  or (
                    g.meeting_recurrence = 'monthly'
                    and case
                      when ceil(extract(day from g.meeting_anchor_date) / 7.0) >= 5
                        -- The anchor landed on a fifth occurrence,
                        -- which most months do not have. Read as the
                        -- LAST one: adding a week would leave the
                        -- month. See the header for why.
                        then extract(day from gs.d) + 7 >
                             extract(day from (date_trunc('month', gs.d) + interval '1 month' - interval '1 day'))
                      else ceil(extract(day from gs.d) / 7.0)
                           = ceil(extract(day from g.meeting_anchor_date) / 7.0)
                    end
                  )
                )
              )
            )
            -- Cancelled dates. Compared as text because the element
            -- type is not recorded: a date[] renders as YYYY-MM-DD and
            -- a text[] of ISO dates matches the same way, and anything
            -- else never matches -- the same answer as not checking.
            -- It can drop an occurrence that is really cancelled; it
            -- can never drop one that is not.
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
-- READ THE "anchor backfill" ROWS. Those three dates are derived from
-- created_at, not recorded, and they are the only part of this that is
-- a guess. "ordinal 5 (last)" on Seniors Book Club is expected.
do $$ begin perform set_config('role', 'anon', true); end $$;

select 'anchor backfill' as section,
       name || ' | ' || coalesce(meeting_recurrence, 'weekly')
       || ' | ' || coalesce(meeting_day_of_week, '-')
       || ' | anchor ' || coalesce(meeting_anchor_date::text, '(none)')
       || case
            when meeting_anchor_date is null then ''
            when ceil(extract(day from meeting_anchor_date) / 7.0) >= 5
              then ' | ordinal 5 (last)'
            else ' | ordinal ' || ceil(extract(day from meeting_anchor_date) / 7.0)::text
          end as detail
  from public.groups
union all
select 'no anchor left', count(*)::text
  from public.groups
 where meeting_anchor_date is null and meeting_date is null
union all
select 'no dates -> all rows', count(*)::text
  from search_groups(p_limit => 100)
union all
select 'today', count(*)::text
  from search_groups(p_limit => 100,
                     p_from_date => current_date, p_to_date => current_date)
union all
select 'next 7 days', count(*)::text
  from search_groups(p_limit => 100,
                     p_from_date => current_date, p_to_date => current_date + 6)
union all
select 'next 14 days', count(*)::text
  from search_groups(p_limit => 100,
                     p_from_date => current_date, p_to_date => current_date + 13)
union all
-- The point of the whole migration: over a single month a monthly
-- group must appear ONCE, not four times. This counts rows, so it
-- cannot show that on its own -- but next-7 vs next-14 vs next-31
-- rising in steps rather than jumping straight to the total is what
-- "exact" looks like from here.
select 'next 31 days', count(*)::text
  from search_groups(p_limit => 100,
                     p_from_date => current_date, p_to_date => current_date + 30)
order by 1, 2;
