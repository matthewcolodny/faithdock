-- Run in the Supabase SQL Editor. Reads only. Creates nothing that
-- outlives the session.
--
-- WHAT WE KNOW NOW
--
-- pg_stat_statements named the slow functions:
--
--   get_groups_insights        mean 1570 ms   max 7580 ms
--   get_attendance_insights    mean 1536 ms   max 6785 ms
--   get_church_optout_emails   mean  458 ms   max 3765 ms
--   find_possible_duplicate_members  mean 264 ms  max 7947 ms  (1189 calls)
--
-- and the sequential-scan table named where the reading happens:
--
--   churches  1287 rows  160,721 seq scans  33,881,869 rows walked
--
-- Those two facts are probably one fact. Both insights functions are
-- `language sql stable` WITHOUT security definer, so row-level security
-- applies to every table they read, as the caller -- and an RLS policy
-- is a WHERE clause the planner may choose to evaluate per row.
--
-- I have already checked the obvious version of that: staff_beyond_checkin
-- is correctly declared STABLE, so it is not being re-run per row for
-- want of a volatility marker. Rather than keep reading policies and
-- guessing which one costs, this measures the functions themselves.
--
-- Section 3 is separate: client_error_logs holds 16,517 rows and has had
-- 15.3 million rows walked. Something in the browser is logging errors
-- constantly, and that is worth seeing whatever else is true.

create or replace function pg_temp.explain_slow_insights()
returns table(section text, ord int, detail text)
language plpgsql
as $fn$
declare
  test_email text := 'matthewcolodny@gmail.com';
  uid        uuid;
  cid        uuid;
  line       text;
  buf        text[];
  i          int;
begin
  select u.id into uid from auth.users u where u.email = test_email;
  if uid is null then
    section := '0. ERROR'; ord := 1;
    detail := 'No auth.users row for ' || test_email; return next; return;
  end if;

  -- The church this person actually owns, so the plans are over real
  -- data rather than an empty result.
  select c.id into cid from churches c where c.owner_id = uid order by c.name limit 1;
  if cid is null then
    select s.church_id into cid from church_staff s where s.user_id = uid limit 1;
  end if;
  if cid is null then
    section := '0. ERROR'; ord := 1;
    detail := 'That user owns and staffs no church, so there is nothing to measure.';
    return next; return;
  end if;

  section := '0. context'; ord := 1;
  detail := 'uid ' || uid || '   church ' || cid;
  return next;

  -- Become the signed-in user, exactly as PostgREST does.
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('role', 'authenticated', 'sub', uid)::text);

  -- ---- 1. groups insights, the slowest ------------------------------
  buf := '{}';
  for line in execute
    format('explain (analyze, buffers) select public.get_groups_insights(%L::uuid)', cid)
  loop buf := buf || line; end loop;
  execute 'reset role';
  for i in 1 .. coalesce(array_length(buf, 1), 0) loop
    section := '1. get_groups_insights'; ord := i; detail := buf[i]; return next;
  end loop;

  -- ---- 2. attendance insights ---------------------------------------
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('role', 'authenticated', 'sub', uid)::text);
  buf := '{}';
  for line in execute
    format('explain (analyze, buffers) select public.get_attendance_insights(%L::uuid)', cid)
  loop buf := buf || line; end loop;
  execute 'reset role';
  for i in 1 .. coalesce(array_length(buf, 1), 0) loop
    section := '2. get_attendance_insights'; ord := i; detail := buf[i]; return next;
  end loop;

  -- ---- 3. what is filling client_error_logs --------------------------
  i := 0;
  for line in
    select left(regexp_replace(l.message, '\s+', ' ', 'g'), 150)
           || '   [x' || count(*)::text || ']'
    from client_error_logs l
    group by left(regexp_replace(l.message, '\s+', ' ', 'g'), 150)
    order by count(*) desc
    limit 12
  loop
    i := i + 1;
    section := '3. top client errors'; ord := i; detail := line; return next;
  end loop;
end
$fn$;

select * from pg_temp.explain_slow_insights();
