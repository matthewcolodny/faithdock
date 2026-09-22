-- Run in Supabase SQL Editor.
--
-- A check-in volunteer should see check-in, and nothing else.
--
-- Today they see everything. Reading is gated by membership -- "are you
-- staff here" -- so a church that adds a Sunday welcome-desk volunteer
-- with can_check_in and nothing else hands them the full directory,
-- every group's membership, household structures, involvement
-- snapshots, saved reports and registrations. They were given one
-- ability and received the whole staff read surface.
--
-- can_check_in itself gates nothing anywhere: not in the client, which
-- reads it zero times, and not in the database, where group_attendance
-- is membership-only. The comment above check-in focus mode in
-- index.html already asserts that "the real boundary is can_check_in".
-- It was never wired up. This wires it up from the other end: rather
-- than making can_check_in grant something, it makes having ONLY
-- can_check_in withhold everything else.
--
-- WHAT A VOLUNTEER KEEPS. Traced from what the check-in screen actually
-- queries, plus an explicit product decision:
--   events                   -- to choose which event's door they are on
--   event_registrations      -- the roster, and writing checked_in_at
--   event_question_answers   -- deliberately. "Severe nut allergy" and
--                               "may be collected by her grandmother"
--                               are exactly what the person at the door
--                               needs. Closing this would be tidier and
--                               worse.
--   event_checkin_links      -- link-based check-in
--   their own church_staff row -- so the app can work out who they are
--
-- WHAT THIS IS NOT. It does not fix the other write gaps in
-- docs/staff-permission-audit.md -- a staff member with only
-- can_manage_giving can still delete an event. That is a separate
-- question with a separate answer, and mixing the two would make either
-- impossible to roll back alone.

-- ---------------------------------------------------------------------
-- Who is a check-in-only volunteer.
--
-- Defined by absence rather than presence: can_check_in, and none of
-- the others. Somebody who is a volunteer AND manages groups is not a
-- volunteer for this purpose -- they have a reason to see group data,
-- and the narrow surface would break them.
--
-- SECURITY DEFINER so it can read church_staff regardless of the
-- caller's own policies on that table, which this migration also
-- narrows. An invoker-rights helper used inside a policy on the table
-- it reads is a good way to build a recursion.
-- ---------------------------------------------------------------------
create or replace function is_checkin_only_staff(target_church_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $fn$
  select exists (
    select 1 from church_staff s
    where s.church_id = target_church_id
      and s.user_id = auth.uid()
      and coalesce(s.can_check_in, false)
      and not coalesce(s.can_manage_events, false)
      and not coalesce(s.can_manage_giving, false)
      and not coalesce(s.can_view_revenue, false)
      and not coalesce(s.can_edit_profile, false)
      and not coalesce(s.can_manage_groups, false)
      and not coalesce(s.can_manage_messages, false)
      and not coalesce(s.can_manage_members, false)
      and not coalesce(s.can_manage_rooms, false)
      and not coalesce(s.can_manage_ministries, false)
      and not coalesce(s.is_manager, false)
  );
$fn$;

-- Staff, but not a check-in-only volunteer. This is what every policy
-- below uses where it previously asked only about membership.
create or replace function staff_beyond_checkin(target_church_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $fn$
  select exists (
    select 1 from church_staff s
    where s.church_id = target_church_id and s.user_id = auth.uid()
  ) and not is_checkin_only_staff(target_church_id);
$fn$;

revoke all on function is_checkin_only_staff(uuid) from public, anon;
revoke all on function staff_beyond_checkin(uuid) from public, anon;
grant execute on function is_checkin_only_staff(uuid) to authenticated;
grant execute on function staff_beyond_checkin(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Preflight. Who is actually affected today.
-- ---------------------------------------------------------------------
do $preflight$
declare
  n_volunteers int;
begin
  select count(*) into n_volunteers
  from church_staff s
  where coalesce(s.can_check_in, false)
    and not coalesce(s.can_manage_events, false)
    and not coalesce(s.can_manage_giving, false)
    and not coalesce(s.can_view_revenue, false)
    and not coalesce(s.can_edit_profile, false)
    and not coalesce(s.can_manage_groups, false)
    and not coalesce(s.can_manage_messages, false)
    and not coalesce(s.can_manage_members, false)
    and not coalesce(s.can_manage_rooms, false)
    and not coalesce(s.can_manage_ministries, false)
    and not coalesce(s.is_manager, false);
  raise notice 'Check-in-only volunteers affected by this change: %', n_volunteers;
end
$preflight$;

-- ---------------------------------------------------------------------
-- The rewrites. Every non-staff branch is preserved exactly -- owners,
-- the person themself, group leaders, public visibility. Only the
-- "is staff here" branch narrows.
-- ---------------------------------------------------------------------

-- Opt-outs: who has asked this church to stop emailing them.
drop policy if exists "Church staff can see their own opt-outs" on church_email_optouts;
create policy "Church staff can see their own opt-outs"
  on church_email_optouts for select
  using (
    exists (select 1 from churches c where c.id = church_email_optouts.church_id and c.owner_id = auth.uid())
    or staff_beyond_checkin(church_email_optouts.church_id)
  );

-- Pending member invitations.
drop policy if exists "Owner or staff can manage invites for their church" on church_member_invites;
create policy "Owner or staff can manage invites for their church"
  on church_member_invites for all
  using (
    church_id in (select id from churches where owner_id = auth.uid())
    or staff_beyond_checkin(church_id)
  )
  with check (
    church_id in (select id from churches where owner_id = auth.uid())
    or staff_beyond_checkin(church_id)
  );

-- Who belongs to the church.
drop policy if exists "Church owner/staff can manage their church's memberships" on church_memberships;
create policy "Church owner/staff can manage their church's memberships"
  on church_memberships for all
  using (
    exists (select 1 from churches c where c.id = church_memberships.church_id and c.owner_id = auth.uid())
    or staff_beyond_checkin(church_memberships.church_id)
  )
  with check (
    exists (select 1 from churches c where c.id = church_memberships.church_id and c.owner_id = auth.uid())
    or staff_beyond_checkin(church_memberships.church_id)
  );

drop policy if exists "user can view their own memberships" on church_memberships;
create policy "user can view their own memberships"
  on church_memberships for select
  using (
    user_id = auth.uid()
    or exists (select 1 from churches where churches.id = church_memberships.church_id and churches.owner_id = auth.uid())
    or staff_beyond_checkin(church_memberships.church_id)
  );

-- Rooms.
drop policy if exists "Church owner/staff can view their rooms" on church_rooms;
create policy "Church owner/staff can view their rooms"
  on church_rooms for select
  using (
    exists (select 1 from churches c where c.id = church_rooms.church_id and c.owner_id = auth.uid())
    or staff_beyond_checkin(church_rooms.church_id)
  );

-- The team list. The volunteer keeps their OWN row -- the app needs it
-- to work out who they are and what they may do -- but not the roster
-- of everyone else on staff.
drop policy if exists "owner and staff can view the team" on church_staff;
create policy "owner and staff can view the team"
  on church_staff for select
  using (
    exists (select 1 from churches where churches.id = church_staff.church_id and churches.owner_id = auth.uid())
    or user_id = auth.uid()
    or staff_beyond_checkin(church_staff.church_id)
  );

-- Fund names.
drop policy if exists "Church owner/staff can view all their funds" on giving_funds;
create policy "Church owner/staff can view all their funds"
  on giving_funds for select
  using (
    exists (select 1 from churches c where c.id = giving_funds.church_id and c.owner_id = auth.uid())
    or staff_beyond_checkin(giving_funds.church_id)
  );

-- Group attendance: who turned up to which small group, which is
-- pastoral information rather than operational.
drop policy if exists "Church owner/staff can manage group attendance" on group_attendance;
create policy "Church owner/staff can manage group attendance"
  on group_attendance for all
  using (
    exists (
      select 1 from groups g
      where g.id = group_attendance.group_id
        and (exists (select 1 from churches c where c.id = g.church_id and c.owner_id = auth.uid())
             or staff_beyond_checkin(g.church_id))
    )
  )
  with check (
    exists (
      select 1 from groups g
      where g.id = group_attendance.group_id
        and (exists (select 1 from churches c where c.id = g.church_id and c.owner_id = auth.uid())
             or staff_beyond_checkin(g.church_id))
    )
  );

drop policy if exists "Church owner/staff can view group attendance" on group_attendance;
create policy "Church owner/staff can view group attendance"
  on group_attendance for select
  using (
    exists (
      select 1 from groups g
      where g.id = group_attendance.group_id
        and (exists (select 1 from churches c where c.id = g.church_id and c.owner_id = auth.uid())
             or staff_beyond_checkin(g.church_id))
    )
  );

-- Group membership. Four branches here and only the staff one changes:
-- the member themself, the owner, group leaders and public member lists
-- all stay exactly as they were.
drop policy if exists "owner, staff, leaders, member themself, or public if allowed" on group_members;
create policy "owner, staff, leaders, member themself, or public if allowed"
  on group_members for select
  using (
    user_id = auth.uid()
    or exists (
      select 1 from groups
      where groups.id = group_members.group_id
        and (exists (select 1 from churches where churches.id = groups.church_id and churches.owner_id = auth.uid())
             or staff_beyond_checkin(groups.church_id))
    )
    or is_group_leader(group_id)
    or (status = 'active' and exists (
          select 1 from groups
          where groups.id = group_members.group_id and groups.show_member_list = true))
  );

drop policy if exists "owner, staff, or leaders can update membership" on group_members;
create policy "owner, staff, or leaders can update membership"
  on group_members for update
  using (
    exists (
      select 1 from groups
      where groups.id = group_members.group_id
        and (exists (select 1 from churches where churches.id = groups.church_id and churches.owner_id = auth.uid())
             or staff_beyond_checkin(groups.church_id))
    )
    or is_group_leader(group_id)
  )
  with check (true);

drop policy if exists "users can leave, owner, staff, or leaders can manage membership" on group_members;
create policy "users can leave, owner, staff, or leaders can manage membership"
  on group_members for delete
  using (
    user_id = auth.uid()
    or exists (
      select 1 from groups
      where groups.id = group_members.group_id
        and (exists (select 1 from churches where churches.id = groups.church_id and churches.owner_id = auth.uid())
             or staff_beyond_checkin(groups.church_id))
    )
    or is_group_leader(group_id)
  );

-- Groups themselves. A volunteer has no reason to create, rename or
-- delete one. Public and member-facing reads go through other policies
-- and are untouched.
drop policy if exists "owner or staff can manage groups" on groups;
create policy "owner or staff can manage groups"
  on groups for all
  using (
    exists (select 1 from churches where churches.id = groups.church_id and churches.owner_id = auth.uid())
    or staff_beyond_checkin(groups.church_id)
  )
  with check (
    exists (select 1 from churches where churches.id = groups.church_id and churches.owner_id = auth.uid())
    or staff_beyond_checkin(groups.church_id)
  );

-- Households: family structure, and who lives with whom.
drop policy if exists "Church owner/staff can manage their households" on households;
create policy "Church owner/staff can manage their households"
  on households for all
  using (
    exists (select 1 from churches c where c.id = households.church_id and c.owner_id = auth.uid())
    or staff_beyond_checkin(households.church_id)
  )
  with check (
    exists (select 1 from churches c where c.id = households.church_id and c.owner_id = auth.uid())
    or staff_beyond_checkin(households.church_id)
  );

drop policy if exists "Church owner/staff can view their households" on households;
create policy "Church owner/staff can view their households"
  on households for select
  using (
    exists (select 1 from churches c where c.id = households.church_id and c.owner_id = auth.uid())
    or staff_beyond_checkin(households.church_id)
  );

drop policy if exists "Church owner/staff can manage household members" on household_members;
create policy "Church owner/staff can manage household members"
  on household_members for all
  using (
    exists (
      select 1 from households h
      where h.id = household_members.household_id
        and (exists (select 1 from churches c where c.id = h.church_id and c.owner_id = auth.uid())
             or staff_beyond_checkin(h.church_id))
    )
  )
  with check (
    exists (
      select 1 from households h
      where h.id = household_members.household_id
        and (exists (select 1 from churches c where c.id = h.church_id and c.owner_id = auth.uid())
             or staff_beyond_checkin(h.church_id))
    )
  );

drop policy if exists "Church owner/staff can view household members" on household_members;
create policy "Church owner/staff can view household members"
  on household_members for select
  using (
    exists (
      select 1 from households h
      where h.id = household_members.household_id
        and (exists (select 1 from churches c where c.id = h.church_id and c.owner_id = auth.uid())
             or staff_beyond_checkin(h.church_id))
    )
  );

-- Derived engagement data about individuals.
drop policy if exists "Church owner/staff can view their involvement snapshots" on involvement_snapshots;
create policy "Church owner/staff can view their involvement snapshots"
  on involvement_snapshots for select
  using (
    exists (select 1 from churches c where c.id = involvement_snapshots.church_id and c.owner_id = auth.uid())
    or staff_beyond_checkin(involvement_snapshots.church_id)
  );

-- Saved reports, which are named queries over everything above.
drop policy if exists "Church owner/staff can manage their saved reports" on saved_reports;
create policy "Church owner/staff can manage their saved reports"
  on saved_reports for all
  using (
    exists (select 1 from churches c where c.id = saved_reports.church_id and c.owner_id = auth.uid())
    or staff_beyond_checkin(saved_reports.church_id)
  )
  with check (
    exists (select 1 from churches c where c.id = saved_reports.church_id and c.owner_id = auth.uid())
    or staff_beyond_checkin(saved_reports.church_id)
  );

drop policy if exists "Church owner/staff can view their saved reports" on saved_reports;
create policy "Church owner/staff can view their saved reports"
  on saved_reports for select
  using (
    exists (select 1 from churches c where c.id = saved_reports.church_id and c.owner_id = auth.uid())
    or staff_beyond_checkin(saved_reports.church_id)
  );

-- Which room an event is in is not something the door needs.
drop policy if exists "Church owner/staff can view their event room links" on event_rooms;
create policy "Church owner/staff can view their event room links"
  on event_rooms for select
  using (
    exists (
      select 1 from events e join churches c on c.id = e.church_id
      where e.id = event_rooms.event_id
        and (c.owner_id = auth.uid() or staff_beyond_checkin(c.id))
    )
  );

-- Managing events -- creating, editing, deleting. A volunteer keeps
-- READING events, which is a separate policy and untouched, because
-- they have to choose which door they are on.
--
-- This still lets any non-volunteer staff member manage events without
-- can_manage_events, which is a separate finding in the audit and needs
-- its own migration. Narrowing it here closes the volunteer path now
-- rather than leaving it open until that decision is made.
drop policy if exists "owner or staff can manage events" on events;
create policy "owner or staff can manage events"
  on events for all
  using (
    exists (select 1 from churches where churches.id = events.church_id and churches.owner_id = auth.uid())
    or staff_beyond_checkin(events.church_id)
  )
  with check (
    exists (select 1 from churches where churches.id = events.church_id and churches.owner_id = auth.uid())
    or staff_beyond_checkin(events.church_id)
  );

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Verify.
-- ---------------------------------------------------------------------
do $verify$
declare
  n_left int;
  r record;
begin
  if has_function_privilege('anon', 'staff_beyond_checkin(uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon can execute staff_beyond_checkin.';
  end if;

  -- Every policy this migration rewrote should now mention the helper.
  -- Anything still testing membership directly on these tables was
  -- missed, and a missed one is a door left open.
  select count(*) into n_left
  from pg_policy p join pg_class c on c.oid = p.polrelid
  where c.relname in ('church_email_optouts','church_member_invites','church_memberships',
                      'church_rooms','giving_funds','group_attendance','group_members',
                      'groups','households','household_members','involvement_snapshots',
                      'saved_reports','event_rooms','events')
    and (pg_get_expr(p.polqual, p.polrelid) like '%is_church_staff_member%'
         or (pg_get_expr(p.polqual, p.polrelid) like '%church_staff%'
             and pg_get_expr(p.polqual, p.polrelid) not like '%staff_beyond_checkin%'
             and pg_get_expr(p.polqual, p.polrelid) not like '%can\_%' escape '\'));

  if n_left > 0 then
    raise warning 'VERIFY: % policy/policies on the covered tables still test membership directly:', n_left;
    for r in
      select c.relname, p.polname
      from pg_policy p join pg_class c on c.oid = p.polrelid
      where c.relname in ('church_email_optouts','church_member_invites','church_memberships',
                          'church_rooms','giving_funds','group_attendance','group_members',
                          'groups','households','household_members','involvement_snapshots',
                          'saved_reports','event_rooms','events')
        and (pg_get_expr(p.polqual, p.polrelid) like '%is_church_staff_member%'
             or (pg_get_expr(p.polqual, p.polrelid) like '%church_staff%'
                 and pg_get_expr(p.polqual, p.polrelid) not like '%staff_beyond_checkin%'
                 and pg_get_expr(p.polqual, p.polrelid) not like '%can\_%' escape '\'))
    loop
      raise warning '  %.%', r.relname, r.polname;
    end loop;
    raise exception 'VERIFY FAILED: % membership-only policy/policies remain on the covered tables.', n_left;
  end if;

  raise notice 'OK: a check-in-only volunteer now sees events, the roster, the answers and their own staff row -- and nothing else.';
end
$verify$;
