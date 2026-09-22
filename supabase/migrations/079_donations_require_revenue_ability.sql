-- Run in Supabase SQL Editor.
--
-- Make can_view_revenue actually control access to giving.
--
-- Today it does not. The SELECT policy on donations reads:
--
--     donor_id = auth.uid()
--     OR <church owner>
--     OR is_church_staff_member(church_id)
--
-- That last clause is membership, not permission. Any staff member can
-- read every donation the church has ever received, whatever their
-- abilities say -- and not only through a page. A session plus a
-- church_staff row is enough to read the table straight from the API.
--
-- The client made this look narrower than it was. The Revenue page is
-- hidden unless canViewRevenue, so the ability appeared to gate the
-- money. It gated a nav link. Insights, which shows all-time given,
-- donor count, average gift and a twelve-month chart, was gated by
-- nothing at all, so the same figures were one click away for anybody
-- on staff.
--
-- The ability check below mirrors what the client already computes:
--   canViewRevenue = can_manage_giving OR can_view_revenue
-- Two flags because can_view_revenue was added later (migration 047) as
-- a weaker, read-only companion to can_manage_giving. Somebody who can
-- manage giving can obviously read it.
--
-- WHAT THIS CHANGES FOR PEOPLE. A staff member with neither flag stops
-- seeing giving figures anywhere: Insights, the People Statistics
-- report, and the Revenue page they already could not open. That is the
-- intent. The symptom for them is zeros rather than an error, which is
-- why the client change shipped alongside this says "you do not have
-- access to giving" instead of drawing an empty chart.
--
-- Donors keep seeing their own giving. Owners keep seeing everything.

-- ---------------------------------------------------------------------
-- Blast radius, before anything changes. Run the file and read this
-- first: it counts the staff who are about to lose access. If it is
-- zero, nobody notices this change at all.
-- ---------------------------------------------------------------------
do $preflight$
declare
  n_affected int;
  n_staff    int;
begin
  select count(*) into n_staff from church_staff;
  select count(*) into n_affected
  from church_staff s
  where coalesce(s.can_manage_giving, false) = false
    and coalesce(s.can_view_revenue, false) = false;

  raise notice 'Staff rows in total: %. Losing giving visibility: %.', n_staff, n_affected;
  if n_affected > 0 then
    raise notice 'Those % staff will see zeros where they previously saw giving figures. Intended -- but worth telling them.', n_affected;
  end if;
end
$preflight$;

-- ---------------------------------------------------------------------
-- The policy. Same name, so this replaces rather than stacks: two
-- SELECT policies on one table are OR-ed together, and leaving the old
-- one in place would make this change do nothing at all while looking
-- like it had worked.
-- ---------------------------------------------------------------------
drop policy if exists "donor or church owner/staff can view donations" on donations;

create policy "donor or church owner/staff can view donations"
  on donations for select
  using (
    -- Your own giving, always.
    donor_id = auth.uid()
    -- The owner, always.
    or exists (
      select 1 from churches c
      where c.id = donations.church_id and c.owner_id = auth.uid()
    )
    -- Staff, but only with an ability that says so.
    or exists (
      select 1 from church_staff s
      where s.church_id = donations.church_id
        and s.user_id = auth.uid()
        and (coalesce(s.can_manage_giving, false) or coalesce(s.can_view_revenue, false))
    )
  );

do $verify$
declare
  n_select_policies int;
  policy_src text;
begin
  select count(*) into n_select_policies
  from pg_policy
  where polrelid = 'donations'::regclass and polcmd = 'r';

  -- More than one SELECT policy means the old one survived somewhere
  -- under a different name, and they would be OR-ed -- so the loose
  -- clause would still be granting exactly what this migration removes.
  if n_select_policies <> 1 then
    raise exception 'VERIFY FAILED: donations has % SELECT policies; expected 1. Any extra one re-opens what this closes.', n_select_policies;
  end if;

  select pg_get_expr(polqual, polrelid) into policy_src
  from pg_policy
  where polrelid = 'donations'::regclass and polcmd = 'r';

  if policy_src like '%is_church_staff_member%' then
    raise exception 'VERIFY FAILED: the policy still calls is_church_staff_member, which is membership rather than permission.';
  end if;
  if policy_src not like '%can_view_revenue%' then
    raise exception 'VERIFY FAILED: the policy does not mention can_view_revenue.';
  end if;
  if policy_src not like '%can_manage_giving%' then
    raise exception 'VERIFY FAILED: the policy does not mention can_manage_giving.';
  end if;

  raise notice 'OK: reading a church''s donations now requires owning it, having given, or holding a revenue ability.';
end
$verify$;
