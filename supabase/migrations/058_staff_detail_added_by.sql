-- Run in Supabase SQL Editor.
--
-- Team & Permissions gains "Added by <name> · <date>" per staff row.
--
-- On a team of fifteen, "why does this person have Manager" is a
-- question about provenance, and church_staff already records both
-- answers -- invited_by and created_at -- which nothing has ever
-- surfaced.
--
-- === DROP first, not CREATE OR REPLACE ===
-- The return type gains two columns, and Postgres refuses to replace
-- a function whose OUT parameters changed (42P13). Same constraint
-- that forced the DROP in 037, 039 and 045. Dropping by the exact
-- current signature rather than by name, so a stray overload cannot
-- be removed by accident.
drop function if exists get_church_staff_detail(uuid);

create or replace function get_church_staff_detail(target_church_id uuid)
returns table (
  staff_id uuid,
  user_id uuid,
  full_name text,
  can_manage_events boolean,
  can_manage_giving boolean,
  can_edit_profile boolean,
  can_manage_groups boolean,
  can_manage_messages boolean,
  is_manager boolean,
  receives_contact_messages boolean,
  can_manage_members boolean,
  can_check_in boolean,
  can_manage_rooms boolean,
  can_manage_ministries boolean,
  can_view_revenue boolean,
  added_by_name text,
  added_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not (
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or is_church_staff_member(target_church_id)
  ) then
    raise exception 'Not authorized to view staff for this church.';
  end if;

  return query
    select cs.id, cs.user_id, p.full_name,
      cs.can_manage_events, cs.can_manage_giving, cs.can_edit_profile,
      cs.can_manage_groups, cs.can_manage_messages, cs.is_manager,
      cs.receives_contact_messages, cs.can_manage_members, cs.can_check_in,
      cs.can_manage_rooms, cs.can_manage_ministries, cs.can_view_revenue,
      -- LEFT join: the person who did the adding may have deleted their
      -- account since, and a row that vanishes because its inviter left
      -- would be worse than one with a blank name. The client shows the
      -- date alone in that case.
      adder.full_name,
      cs.created_at
    from church_staff cs
    left join profiles p on p.id = cs.user_id
    left join profiles adder on adder.id = cs.invited_by
    where cs.church_id = target_church_id;
end;
$fn$;

revoke all on function get_church_staff_detail(uuid) from public, anon;
grant execute on function get_church_staff_detail(uuid) to authenticated;

notify pgrst, 'reload schema';

-- Confirm the swap, since CREATE succeeding is not evidence the body
-- is what was intended (see 049, and 053's verify block).
do $verify$
declare
  v_def text := pg_get_functiondef(to_regprocedure('get_church_staff_detail(uuid)'));
begin
  if position('added_by_name' in v_def) = 0 then
    raise exception 'VERIFY FAILED: get_church_staff_detail has no added_by_name column.';
  end if;
  if position('cs.invited_by' in v_def) = 0 then
    raise exception 'VERIFY FAILED: the adder join is missing.';
  end if;
  raise notice 'OK: staff detail now reports who added each person and when.';
end
$verify$;
