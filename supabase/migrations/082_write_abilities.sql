-- Run in Supabase SQL Editor.
--
-- Make the remaining abilities restrict writing.
--
-- The last of the Tier 1 findings in docs/staff-permission-audit.md.
-- Nine policies where an ability exists, the client hides the page
-- without it, and the database accepts the write anyway from anyone
-- holding a church_staff row.
--
-- Migration 081 narrowed all of these to staff_beyond_checkin(), which
-- kept check-in volunteers out. It did not make them ask for the right
-- ability: a staff member allowed only to manage giving could still
-- delete an event, remove a member, or rename a group. This asks.
--
-- events is the clearest of them. Its own child tables --
-- event_questions, event_rooms, event_discount_codes -- have required
-- can_manage_events since they were written. The parent never did. So
-- somebody who could not add a question to an event could delete the
-- event it belonged to.
--
-- ONE DELIBERATE DEPARTURE from the audit. It listed group_attendance
-- as bypassing can_check_in. On reflection that is the wrong ability:
-- group_attendance is who came to a SMALL GROUP, which is group data,
-- while event check-in is a different mechanism on a different table
-- (event_registrations.checked_in_at). Requiring can_check_in here
-- would also re-admit exactly the volunteers 081 excluded. It requires
-- can_manage_groups instead. Say so if that is wrong for a real church
-- -- it is one word to change.
--
-- READING IS NOT AFFECTED. Tightening a FOR ALL policy would take read
-- access with it, so every table below either already has a separate
-- SELECT policy granting staff (from 081) or gets one added here.
-- "You may not edit this" must not turn into "this does not exist".

-- ---------------------------------------------------------------------
-- Blast radius, per ability. Run and read before deciding to keep it.
-- ---------------------------------------------------------------------
do $preflight$
declare
  n_staff   int;
  n_events  int;
  n_groups  int;
  n_members int;
begin
  select count(*) into n_staff from church_staff;
  select count(*) into n_events  from church_staff where not coalesce(can_manage_events, false);
  select count(*) into n_groups  from church_staff where not coalesce(can_manage_groups, false);
  select count(*) into n_members from church_staff where not coalesce(can_manage_members, false);

  raise notice 'Staff rows: %.', n_staff;
  raise notice '  losing event management:      %', n_events;
  raise notice '  losing group management:      %', n_groups;
  raise notice '  losing member/household mgmt: %', n_members;
  raise notice 'They keep reading all of it. Only writing narrows.';
end
$preflight$;

-- ---------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------
drop policy if exists "owner or staff can manage events" on events;
create policy "owner or staff can manage events"
  on events for all
  using (
    exists (select 1 from churches where churches.id = events.church_id and churches.owner_id = auth.uid())
    or exists (select 1 from church_staff s
               where s.church_id = events.church_id and s.user_id = auth.uid()
                 and coalesce(s.can_manage_events, false))
  )
  with check (
    exists (select 1 from churches where churches.id = events.church_id and churches.owner_id = auth.uid())
    or exists (select 1 from church_staff s
               where s.church_id = events.church_id and s.user_id = auth.uid()
                 and coalesce(s.can_manage_events, false))
  );

-- ---------------------------------------------------------------------
-- Groups, group membership, group attendance
-- ---------------------------------------------------------------------
drop policy if exists "owner or staff can manage groups" on groups;
create policy "owner or staff can manage groups"
  on groups for all
  using (
    exists (select 1 from churches where churches.id = groups.church_id and churches.owner_id = auth.uid())
    or exists (select 1 from church_staff s
               where s.church_id = groups.church_id and s.user_id = auth.uid()
                 and coalesce(s.can_manage_groups, false))
  )
  with check (
    exists (select 1 from churches where churches.id = groups.church_id and churches.owner_id = auth.uid())
    or exists (select 1 from church_staff s
               where s.church_id = groups.church_id and s.user_id = auth.uid()
                 and coalesce(s.can_manage_groups, false))
  );

-- groups had no staff SELECT policy of its own -- staff read came from
-- the FOR ALL policy above, which now requires an ability. Added so
-- narrowing the write does not hide the church's own groups from its
-- own staff. Additive: public and member-facing reads go through their
-- own policies and are untouched.
drop policy if exists "Staff can view their church's groups" on groups;
create policy "Staff can view their church's groups"
  on groups for select
  using (
    exists (select 1 from churches where churches.id = groups.church_id and churches.owner_id = auth.uid())
    or staff_beyond_checkin(groups.church_id)
  );

-- Group membership. The member themself and group leaders keep their
-- branches exactly; only the staff branch asks for an ability.
drop policy if exists "owner, staff, or leaders can update membership" on group_members;
create policy "owner, staff, or leaders can update membership"
  on group_members for update
  using (
    exists (
      select 1 from groups
      where groups.id = group_members.group_id
        and (exists (select 1 from churches where churches.id = groups.church_id and churches.owner_id = auth.uid())
             or exists (select 1 from church_staff s
                        where s.church_id = groups.church_id and s.user_id = auth.uid()
                          and coalesce(s.can_manage_groups, false)))
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
             or exists (select 1 from church_staff s
                        where s.church_id = groups.church_id and s.user_id = auth.uid()
                          and coalesce(s.can_manage_groups, false)))
    )
    or is_group_leader(group_id)
  );

drop policy if exists "Church owner/staff can manage group attendance" on group_attendance;
create policy "Church owner/staff can manage group attendance"
  on group_attendance for all
  using (
    exists (
      select 1 from groups g
      where g.id = group_attendance.group_id
        and (exists (select 1 from churches c where c.id = g.church_id and c.owner_id = auth.uid())
             or exists (select 1 from church_staff s
                        where s.church_id = g.church_id and s.user_id = auth.uid()
                          and coalesce(s.can_manage_groups, false)))
    )
  )
  with check (
    exists (
      select 1 from groups g
      where g.id = group_attendance.group_id
        and (exists (select 1 from churches c where c.id = g.church_id and c.owner_id = auth.uid())
             or exists (select 1 from church_staff s
                        where s.church_id = g.church_id and s.user_id = auth.uid()
                          and coalesce(s.can_manage_groups, false)))
    )
  );

-- ---------------------------------------------------------------------
-- Membership, invitations, households
-- ---------------------------------------------------------------------
drop policy if exists "Church owner/staff can manage their church's memberships" on church_memberships;
create policy "Church owner/staff can manage their church's memberships"
  on church_memberships for all
  using (
    exists (select 1 from churches c where c.id = church_memberships.church_id and c.owner_id = auth.uid())
    or exists (select 1 from church_staff s
               where s.church_id = church_memberships.church_id and s.user_id = auth.uid()
                 and coalesce(s.can_manage_members, false))
  )
  with check (
    exists (select 1 from churches c where c.id = church_memberships.church_id and c.owner_id = auth.uid())
    or exists (select 1 from church_staff s
               where s.church_id = church_memberships.church_id and s.user_id = auth.uid()
                 and coalesce(s.can_manage_members, false))
  );

drop policy if exists "Owner or staff can manage invites for their church" on church_member_invites;
create policy "Owner or staff can manage invites for their church"
  on church_member_invites for all
  using (
    church_id in (select id from churches where owner_id = auth.uid())
    or exists (select 1 from church_staff s
               where s.church_id = church_member_invites.church_id and s.user_id = auth.uid()
                 and coalesce(s.can_manage_members, false))
  )
  with check (
    church_id in (select id from churches where owner_id = auth.uid())
    or exists (select 1 from church_staff s
               where s.church_id = church_member_invites.church_id and s.user_id = auth.uid()
                 and coalesce(s.can_manage_members, false))
  );

-- Same reason as groups: this table's only staff policy was the FOR ALL
-- one, so narrowing the write would have hidden pending invitations
-- from staff who cannot issue them but can reasonably see them.
drop policy if exists "Staff can view their church's member invites" on church_member_invites;
create policy "Staff can view their church's member invites"
  on church_member_invites for select
  using (
    church_id in (select id from churches where owner_id = auth.uid())
    or staff_beyond_checkin(church_id)
  );

drop policy if exists "Church owner/staff can manage their households" on households;
create policy "Church owner/staff can manage their households"
  on households for all
  using (
    exists (select 1 from churches c where c.id = households.church_id and c.owner_id = auth.uid())
    or exists (select 1 from church_staff s
               where s.church_id = households.church_id and s.user_id = auth.uid()
                 and coalesce(s.can_manage_members, false))
  )
  with check (
    exists (select 1 from churches c where c.id = households.church_id and c.owner_id = auth.uid())
    or exists (select 1 from church_staff s
               where s.church_id = households.church_id and s.user_id = auth.uid()
                 and coalesce(s.can_manage_members, false))
  );

drop policy if exists "Church owner/staff can manage household members" on household_members;
create policy "Church owner/staff can manage household members"
  on household_members for all
  using (
    exists (
      select 1 from households h
      where h.id = household_members.household_id
        and (exists (select 1 from churches c where c.id = h.church_id and c.owner_id = auth.uid())
             or exists (select 1 from church_staff s
                        where s.church_id = h.church_id and s.user_id = auth.uid()
                          and coalesce(s.can_manage_members, false)))
    )
  )
  with check (
    exists (
      select 1 from households h
      where h.id = household_members.household_id
        and (exists (select 1 from churches c where c.id = h.church_id and c.owner_id = auth.uid())
             or exists (select 1 from church_staff s
                        where s.church_id = h.church_id and s.user_id = auth.uid()
                          and coalesce(s.can_manage_members, false)))
    )
  );

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Verify.
-- ---------------------------------------------------------------------
do $verify$
declare
  n_bad int;
  r record;
begin
  -- Every write policy on these tables must now name an ability.
  select count(*) into n_bad
  from pg_policy p join pg_class c on c.oid = p.polrelid
  where c.relname in ('events','groups','group_members','group_attendance',
                      'church_memberships','church_member_invites',
                      'households','household_members')
    and p.polcmd in ('a','w','d','*')
    and pg_get_expr(p.polqual, p.polrelid) is not null
    and pg_get_expr(p.polqual, p.polrelid) like '%church_staff%'
    and pg_get_expr(p.polqual, p.polrelid) not like '%can\_manage\_%' escape '\';

  if n_bad > 0 then
    for r in
      select c.relname, p.polname
      from pg_policy p join pg_class c on c.oid = p.polrelid
      where c.relname in ('events','groups','group_members','group_attendance',
                          'church_memberships','church_member_invites',
                          'households','household_members')
        and p.polcmd in ('a','w','d','*')
        and pg_get_expr(p.polqual, p.polrelid) is not null
        and pg_get_expr(p.polqual, p.polrelid) like '%church_staff%'
        and pg_get_expr(p.polqual, p.polrelid) not like '%can\_manage\_%' escape '\'
    loop
      raise warning '  %.%', r.relname, r.polname;
    end loop;
    raise exception 'VERIFY FAILED: % write policy/policies still accept any staff member.', n_bad;
  end if;

  -- And staff must still be able to READ each of them, or the fix has
  -- turned an edit restriction into a disappearance.
  if not exists (select 1 from pg_policy p join pg_class c on c.oid = p.polrelid
                 where c.relname = 'groups' and p.polcmd = 'r'
                   and pg_get_expr(p.polqual, p.polrelid) like '%staff_beyond_checkin%') then
    raise exception 'VERIFY FAILED: staff lost read access to groups.';
  end if;
  if not exists (select 1 from pg_policy p join pg_class c on c.oid = p.polrelid
                 where c.relname = 'church_member_invites' and p.polcmd = 'r'
                   and pg_get_expr(p.polqual, p.polrelid) like '%staff_beyond_checkin%') then
    raise exception 'VERIFY FAILED: staff lost read access to church_member_invites.';
  end if;

  raise notice 'OK: managing events, groups, members and households each require their own ability.';
end
$verify$;
