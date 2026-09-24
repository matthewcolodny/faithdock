-- Run in the Supabase SQL Editor.
--
-- Two problems, both found by supabase/checks/policy_function_sources.sql,
-- neither of them a security hole. The invariants pass: private and
-- draft events are invisible to anon and to an authenticated account
-- that is a member of nothing.
--
-- PROBLEM 1: THE DATABASE HAS A RULE THE REPOSITORY DOES NOT.
-- events carries a policy, "owner and permitted staff can manage
-- events", calling a function, can_manage_church_events(uuid). Neither
-- appears in any migration here. Every other policy helper does -
-- staff_beyond_checkin, is_checkin_only_staff, is_approved_church_member,
-- is_registered_for_event, can_manage_church_members, and the rest. That
-- one predates this folder or was made by hand in the dashboard.
--
-- It means nobody can review that rule from the repo, and a database
-- rebuilt from these migrations would not have it - the rebuilt copy
-- would quietly behave differently from production. This records it,
-- with CREATE OR REPLACE, so the body is identical and the repo stops
-- lying about what the database contains.
--
-- PROBLEM 2: TWO POLICIES SAY THE SAME THING.
-- events has two PERMISSIVE FOR ALL policies:
--
--   owner and permitted staff can manage events   can_manage_church_events(church_id)
--   owner or staff can manage events              the same test, written inline (082)
--
-- Read side by side they are the same rule:
--
--   owner_id = auth.uid()  OR  church_staff.can_manage_events is true
--
-- The only textual difference is `can_manage_events = true` against
-- `coalesce(can_manage_events, false)`, and those agree: a NULL
-- comparison is not true, and a WHERE clause discards it either way.
--
-- Permissive policies OR together, so two copies of one rule are not
-- dangerous - just impossible to reason about. The next person reading
-- this table has to prove to themselves that neither is looser, which is
-- exactly the work that let the earlier events hole survive review.
--
-- WHICH ONE SURVIVES. The function-based one, because every other
-- ability in this schema is expressed that way (can_manage_church_members,
-- can_manage_church_messages, can_edit_church_profile, can_run_event_checkin,
-- can_read_contact_messages). 082's inline copy is the odd one out.
--
-- THE PREFLIGHT DOES NOT TAKE MY WORD FOR IT. Reading two expressions
-- and concluding they agree is an argument. The block below evaluates
-- both against every (user, church) pair that actually exists and
-- refuses to go on if they differ for even one of them.

-- ---------------------------------------------------------------------
-- Preflight. Aborts rather than proceeding on an assumption.
-- ---------------------------------------------------------------------
do $preflight$
declare
  n_disagree   int;
  n_pairs      int;
  has_fn_pol   bool;
  has_inline   bool;
  wc_fn        text;
  wc_inline    text;
begin
  select exists (select 1 from pg_policy p join pg_class c on c.oid = p.polrelid
                  where c.relname = 'events' and p.polname = 'owner and permitted staff can manage events')
    into has_fn_pol;
  select exists (select 1 from pg_policy p join pg_class c on c.oid = p.polrelid
                  where c.relname = 'events' and p.polname = 'owner or staff can manage events')
    into has_inline;

  if not has_inline then
    raise notice 'The duplicate policy is already gone. Nothing to drop.';
  end if;
  if not has_fn_pol then
    raise exception 'ABORT: "owner and permitted staff can manage events" does not exist. Dropping the other one would remove event management entirely.';
  end if;

  -- WITH CHECK governs writes. A FOR ALL policy with no WITH CHECK uses
  -- its USING expression for both, so null here is fine -- but it is
  -- printed rather than assumed, because this is the half that decides
  -- who can INSERT and UPDATE.
  select pg_get_expr(p.polwithcheck, p.polrelid) into wc_fn
    from pg_policy p join pg_class c on c.oid = p.polrelid
   where c.relname = 'events' and p.polname = 'owner and permitted staff can manage events';
  select pg_get_expr(p.polwithcheck, p.polrelid) into wc_inline
    from pg_policy p join pg_class c on c.oid = p.polrelid
   where c.relname = 'events' and p.polname = 'owner or staff can manage events';
  raise notice 'WITH CHECK, surviving policy : %', coalesce(wc_fn, '(none -- USING is used for writes too)');
  raise notice 'WITH CHECK, policy being dropped: %', coalesce(wc_inline, '(none -- USING is used for writes too)');

  -- Behavioural equivalence, measured over real rows rather than argued.
  with candidates as (
    select owner_id as uid, id as cid from churches where owner_id is not null
    union
    select user_id, church_id from church_staff where user_id is not null
  )
  select
    count(*) filter (
      where (
        exists (select 1 from churches x where x.id = cid and x.owner_id = uid)
        or exists (select 1 from church_staff s
                    where s.church_id = cid and s.user_id = uid
                      and coalesce(s.can_manage_events, false))
      ) is distinct from (
        exists (select 1 from churches x where x.id = cid and x.owner_id = uid)
        or exists (select 1 from church_staff s
                    where s.church_id = cid and s.user_id = uid
                      and s.can_manage_events = true)
      )
    ),
    count(*)
  into n_disagree, n_pairs
  from candidates;

  raise notice 'Compared both rules over % real (user, church) pair(s).', n_pairs;
  if n_disagree <> 0 then
    raise exception 'ABORT: the two policies disagree for % pair(s). They are NOT duplicates -- do not drop either until you know which is right.', n_disagree;
  end if;
  raise notice 'They agree on every pair. Safe to drop the duplicate.';
end
$preflight$;

-- ---------------------------------------------------------------------
-- 1. Record the function in the repository.
-- ---------------------------------------------------------------------
-- Byte-for-byte the body already running in production, so this changes
-- nothing today. Its value is that the next rebuild, review or audit can
-- see it. CREATE OR REPLACE keeps the existing grants; a DROP would
-- discard them and hand EXECUTE back to PUBLIC by default.
create or replace function public.can_manage_church_events(target_church_id uuid)
returns boolean
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
      or exists (select 1 from church_staff where church_id = target_church_id and user_id = auth.uid() and can_manage_events = true);
$function$;

-- ---------------------------------------------------------------------
-- 2. Drop the duplicate.
-- ---------------------------------------------------------------------
drop policy if exists "owner or staff can manage events" on events;

-- ---------------------------------------------------------------------
-- Verify. Read the output; do not assume it worked.
-- ---------------------------------------------------------------------
-- Expect: three SELECT-capable policies, the duplicate gone, and both
-- exposure counts zero. The counts are the point -- the policy list only
-- describes the rules, while these measure what they actually permit.
select
  (select count(*) from pg_policy p join pg_class c on c.oid = p.polrelid
    where c.relname = 'events' and p.polcmd in ('r','*'))                       as events_select_policies,
  (select count(*) from pg_policy p join pg_class c on c.oid = p.polrelid
    where c.relname = 'events' and p.polname = 'owner or staff can manage events') as duplicate_remaining,
  (select string_agg(p.polname, ' | ' order by p.polname)
     from pg_policy p join pg_class c on c.oid = p.polrelid
    where c.relname = 'events' and p.polcmd in ('r','*'))                       as remaining_policies,
  has_function_privilege('authenticated', 'public.can_manage_church_events(uuid)', 'EXECUTE') as auth_can_execute;
