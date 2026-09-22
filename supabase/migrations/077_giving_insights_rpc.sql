-- Run in Supabase SQL Editor.
--
-- Giving Insights, aggregated in the database instead of the browser.
--
-- loadGivingInsights() fetched every succeeded donation a church has
-- ever taken -- amount, donor, email, timestamp, one row each -- and
-- then reduced them on the phone to nine numbers and two small charts.
-- The work is trivial; the transfer is not. A church that takes fifty
-- gifts a week hands its treasurer roughly ten thousand rows a year to
-- download before the page can draw anything, and that cost grows with
-- the church's whole history rather than with what is on screen.
--
-- This returns those numbers directly. The payload stops depending on
-- how long the church has existed.

-- ---------------------------------------------------------------------
-- SECURITY INVOKER, deliberately, and it is the important decision here.
--
-- A SECURITY DEFINER function would bypass RLS on donations, which means
-- re-implementing that table's access rules inside this function -- and
-- getting them subtly wrong is how a church ends up reading another
-- church's giving. It also cannot be checked against the real policy
-- from here: the donations table predates this repository's migration
-- history, so its policies are not in the tree to copy.
--
-- Invoker rights sidestep all of that. The caller sees exactly the rows
-- RLS already lets them see -- no more, no less, and no second copy of
-- the rules to drift. Aggregation was the point; privilege was never
-- part of it. If a church member with no giving access calls this, they
-- get zeros, which is the same answer the old client code would have
-- arrived at from an empty result set.
-- ---------------------------------------------------------------------

-- p_tz is an IANA zone, passed by the client from the browser. Month
-- boundaries have to be drawn somewhere, and the old code drew them in
-- the reader's local time. Doing it in UTC instead would silently move a
-- late-evening gift on the 31st into the following month for anyone west
-- of Greenwich -- a small error that shows up as a chart that disagrees
-- with the church's own books.
create or replace function get_giving_insights(
  target_church_id uuid,
  p_tz text default 'UTC'
)
returns jsonb
language plpgsql
stable
as $fn$
declare
  v_tz text := coalesce(nullif(p_tz, ''), 'UTC');
  v_first_month date;
  v_result jsonb;
begin
  -- An unknown zone raises, and a chart is not worth failing a page
  -- over, so an unusable value falls back rather than throwing.
  begin
    perform now() at time zone v_tz;
  exception when others then
    v_tz := 'UTC';
  end;

  -- The first of the month, eleven months back, in the reader's zone.
  v_first_month := date_trunc('month', (now() at time zone v_tz))::date - interval '11 months';

  with mine as (
    select d.amount_cents,
           d.donor_id,
           d.donor_email,
           (d.created_at at time zone v_tz) as local_at
    from donations d
    where d.church_id = target_church_id
      and d.status = 'succeeded'
  ),
  totals as (
    select coalesce(sum(amount_cents), 0)::bigint as total_cents,
           count(*)::bigint                        as donation_count,
           -- Matches the old client rule exactly: donor_id, else email,
           -- else one shared 'unknown' bucket. Anonymous gifts therefore
           -- count as a single donor between them, which is understated
           -- and was already true.
           count(distinct coalesce(donor_id::text, donor_email, 'unknown'))::bigint as donor_count
    from mine
  ),
  -- Zero-filled, so a quiet month is a gap in the chart rather than a
  -- missing bar that shifts every other bar one place left.
  month_series as (
    select generate_series(v_first_month, v_first_month + interval '11 months', interval '1 month')::date as m
  ),
  by_month as (
    select ms.m as month_start,
           coalesce(sum(mine.amount_cents), 0)::bigint as cents
    from month_series ms
    left join mine
      on date_trunc('month', mine.local_at)::date = ms.m
    group by ms.m
    order by ms.m
  ),
  -- Age is self-reported and optional. Donations from people who have
  -- not shared one are left out of this chart rather than collected into
  -- an "unknown" bar that would read as a real age group -- the same
  -- choice the client made, kept deliberately.
  with_age as (
    select mine.amount_cents, p.age_range
    from mine
    join profiles p on p.id = mine.donor_id
    where mine.donor_id is not null
      and p.age_range is not null
      and p.age_range in ('under_18','18_24','25_39','40_59','60_79','80_plus')
  ),
  by_age as (
    select age_range, sum(amount_cents)::bigint as cents, count(*)::bigint as n
    from with_age
    group by age_range
  )
  select jsonb_build_object(
    'total_cents',    (select total_cents    from totals),
    'donation_count', (select donation_count from totals),
    'donor_count',    (select donor_count    from totals),
    'months',         coalesce((select jsonb_agg(jsonb_build_object('month_start', month_start, 'cents', cents) order by month_start) from by_month), '[]'::jsonb),
    'by_age',         coalesce((select jsonb_object_agg(age_range, cents) from by_age), '{}'::jsonb),
    -- How many donations are represented in the age chart at all, so the
    -- note under it can say "based on 12 of 40" honestly.
    'aged_count',     coalesce((select sum(n) from by_age), 0),
    'tz',             v_tz
  )
  into v_result;

  return v_result;
end
$fn$;

revoke all on function get_giving_insights(uuid, text) from public;
revoke all on function get_giving_insights(uuid, text) from anon;
grant execute on function get_giving_insights(uuid, text) to authenticated;

notify pgrst, 'reload schema';

do $verify$
begin
  if has_function_privilege('anon', 'get_giving_insights(uuid, text)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon can execute get_giving_insights.';
  end if;
  if not has_function_privilege('authenticated', 'get_giving_insights(uuid, text)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: a signed-in person cannot execute get_giving_insights.';
  end if;
  if (select count(*) from pg_proc where proname = 'get_giving_insights') <> 1 then
    raise exception 'VERIFY FAILED: get_giving_insights is overloaded.';
  end if;

  -- The whole safety argument rests on this staying INVOKER. prosecdef
  -- true would mean the function runs as its owner and reads every
  -- church's donations regardless of who called it.
  if (select prosecdef from pg_proc where proname = 'get_giving_insights') then
    raise exception 'VERIFY FAILED: get_giving_insights is SECURITY DEFINER; it must be INVOKER so RLS applies.';
  end if;

  raise notice 'OK: get_giving_insights installed, invoker rights, RLS still in force.';
end
$verify$;
