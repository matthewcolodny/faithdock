-- Run in Supabase SQL Editor.
--
-- client_error_logs accepts inserts from anyone: its policy is
-- `INSERT ... WITH CHECK (true)`, flagged by the Supabase linter as
-- rls_policy_always_true. That permissiveness is DELIBERATE and stays --
-- the whole point of the table is catching errors that happen before a
-- session exists (a failure during signup, a script error on the
-- homepage), so requiring auth would blind it exactly where it matters
-- most.
--
-- What's missing is a ceiling. Anyone holding the public anon key --
-- which is printed in the page source by design -- can POST to
-- /rest/v1/client_error_logs in a loop with megabyte-sized `stack`
-- values and grow the table without limit. The client already de-dupes
-- identical errors for 60 seconds, but that is browser-side politeness,
-- not a control: it's skipped entirely by anyone calling the API
-- directly. Same "the UI hiding it isn't enforcement" reasoning behind
-- the members-only trigger in 037.
--
-- Enforced with a BEFORE INSERT trigger rather than a stricter policy,
-- for the reason established in 035: permissive policies OR together,
-- so a new restrictive policy cannot take away what the existing one
-- already permits, and this table's original policy isn't in this repo
-- to edit safely. A trigger runs regardless of which policy allowed the
-- statement.

-- Needed by the rate check below; without it that count is a sequential
-- scan on every single insert, which would make logging slower as the
-- table grows -- the opposite of the goal.
create index if not exists client_error_logs_occurred_at_idx
  on client_error_logs (occurred_at desc);

create or replace function enforce_client_error_log_limits()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recent_count integer;
  v_window constant interval := interval '1 minute';
  -- Separate ceilings on purpose. A flood of anonymous junk must not be
  -- able to silence error reports from signed-in users, which is
  -- exactly what one shared counter would allow: fill it with garbage
  -- and every real report is refused too.
  v_anon_limit constant integer := 60;
  v_user_limit constant integer := 30;
begin
  -- TRUNCATE rather than reject. A CHECK constraint on length would
  -- throw away the whole report because its stack trace was long, and
  -- an over-long stack is still a useful error -- the first 10k of it
  -- is where the cause lives. Bounding the size is the actual goal;
  -- losing the error is not.
  new.message    := left(coalesce(new.message, ''), 2000);
  new.stack      := left(coalesce(new.stack, ''), 10000);
  new.url        := left(coalesce(new.url, ''), 500);
  new.user_agent := left(coalesce(new.user_agent, ''), 500);

  -- The client sets user_id from its own getUser() call, so it can be
  -- forged to any uuid. Not severe -- it pollutes someone else's log
  -- rather than reading anything -- but there's no reason to take the
  -- caller's word for it when the database already knows who they are.
  if auth.uid() is not null then
    new.user_id := auth.uid();
  else
    new.user_id := null;
  end if;

  if new.user_id is null then
    select count(*) into v_recent_count
      from client_error_logs
      where user_id is null and occurred_at > now() - v_window;
    if v_recent_count >= v_anon_limit then
      raise exception 'CLIENT_ERROR_LOG_RATE_LIMIT';
    end if;
  else
    select count(*) into v_recent_count
      from client_error_logs
      where user_id = new.user_id and occurred_at > now() - v_window;
    if v_recent_count >= v_user_limit then
      raise exception 'CLIENT_ERROR_LOG_RATE_LIMIT';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists client_error_logs_limits on client_error_logs;
create trigger client_error_logs_limits
  before insert on client_error_logs
  for each row execute function enforce_client_error_log_limits();

notify pgrst, 'reload schema';

-- The client already swallows logging failures (sendErrorLog wraps the
-- insert in .catch()), so a refused insert is silent and harmless --
-- logging an error must never itself throw. Nothing to change there.
