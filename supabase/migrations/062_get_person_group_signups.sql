-- Run in Supabase SQL Editor.
--
-- Creates a function the client has been calling all along.
--
-- === How this was found ===
-- Every `rpc('...')` name in index.html was extracted and checked
-- against this repo; seventeen had no source anywhere, so all
-- seventeen were dumped with pg_get_functiondef. Sixteen came back.
-- get_person_group_signups does not exist.
--
-- === What it looks like from the outside ===
-- The directory person modal does:
--     var { data: churchGroups, error: groupsErr } =
--       await supabase.rpc('get_person_group_signups', {...});
--     if (groupsErr) console.error(...);
--     churchGroups = churchGroups || [];
--     if (!churchGroups.length) { "No group sign-ups yet." }
-- The error goes to the console and the empty array falls straight
-- through to the empty state. **Somebody in three groups shows as being
-- in none**, with no indication anything failed. Staff looking at a
-- member's record have been reading a confident wrong answer.
--
-- === Why this is not guesswork ===
-- The shape is fixed at both ends. The caller reads `g.name` and
-- `g.role === 'leader'`, and get_person_event_signups -- the function
-- immediately above it in the same modal, doing the same job for events
-- -- already establishes the permission check, the security context and
-- the search_path. This is that function with groups in place of
-- events, not a new design.

create or replace function get_person_group_signups(target_church_id uuid, target_user_id uuid)
returns table(name text, role text)
language plpgsql
stable security definer
set search_path = public, pg_temp
as $fn$
begin
  -- Identical to get_person_event_signups: owner or staff of THIS
  -- church, and a silent empty return rather than an exception, so the
  -- modal's other sections still render for someone who should not see
  -- this one.
  if not (
    exists (select 1 from churches where id = target_church_id and owner_id = auth.uid())
    or is_church_staff_member(target_church_id)
  ) then
    return;
  end if;

  return query
  select g.name::text, gm.role::text
  from group_members gm
  join groups g on g.id = gm.group_id
  -- Scoped to the church being viewed, not to every group the person
  -- belongs to. A member of two churches must not have one church's
  -- staff reading their involvement at the other.
  where gm.user_id = target_user_id
    and g.church_id = target_church_id
    and gm.status = 'active'
  order by g.name asc;
end;
$fn$;

-- Same grant treatment as the sibling functions: PUBLIC gets nothing,
-- signed-in callers get execute, and the function's own check decides
-- what comes back. Postgres grants EXECUTE to PUBLIC by default on a
-- new function, so the revoke is what actually narrows this -- see
-- migration 054 and GOTCHAS.md on the two independent execute grants.
revoke all on function get_person_group_signups(uuid, uuid) from public;
revoke all on function get_person_group_signups(uuid, uuid) from anon;
grant execute on function get_person_group_signups(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';

do $verify$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_person_group_signups'
  ) then
    raise exception 'VERIFY FAILED: the function was not created.';
  end if;

  -- Both directions, because a grant that missed leaves the modal
  -- exactly as broken as it was, and a revoke that missed leaves it
  -- callable by anonymous visitors.
  if not has_function_privilege('authenticated', 'get_person_group_signups(uuid, uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: authenticated cannot execute it, so the modal is still empty.';
  end if;
  if has_function_privilege('anon', 'get_person_group_signups(uuid, uuid)', 'EXECUTE') then
    raise exception 'VERIFY FAILED: anon can execute it.';
  end if;

  raise notice 'OK: get_person_group_signups exists and is callable by signed-in users only.';
end
$verify$;
