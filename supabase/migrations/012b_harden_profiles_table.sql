-- Run in Supabase SQL Editor. Safe to run even if
-- 012a_revoke_profiles_admin_flag_SUPERSEDED.sql was already run --
-- this supersedes it (a repeated revoke is a harmless no-op in
-- Postgres). This is the CURRENT / live state of profiles' grants.
--
-- ============================================================
-- Background: two separate holes found this session, both on
-- `profiles`, both confirmed live.
-- ============================================================
--
-- 1) READ: an anonymous, unauthenticated `select('*')` on profiles
--    returns full real rows for every user -- full_name, phone,
--    avatar_url, account_type, and (worst) is_platform_admin, which
--    directly identifies your platform admins to anyone, no login
--    required.
--
-- 2) WRITE -- more severe, found while fixing (1): an anonymous
--    `update(...).eq('id', <a UUID that does not exist>)` against
--    profiles returned a clean 200/no-error instead of a permission
--    error. That specific probe touched zero real rows on purpose
--    (the id doesn't exist) -- but the only reason it could succeed
--    at all is that `anon` currently holds an unrestricted
--    table-wide UPDATE grant on profiles with nothing scoping it to
--    "your own row only". Confirming the same against a real row
--    would require actually writing to a real user's data even
--    idempotently, which this session's own safety controls
--    correctly refused to do without asking first -- so this is
--    reported as a near-certain, not a 100%-confirmed, hole. Given
--    the read-side grant was already confirmed wide open with no
--    row restriction, there's no reason to expect the write-side
--    grant to be scoped any more carefully, and every legitimate
--    write below already goes through a SECURITY DEFINER function
--    instead (which isn't affected by revoking the raw grant), so
--    closing this costs nothing either way.
--
-- ============================================================
-- Fix shape
-- ============================================================
--
-- Column-level grants can restrict WHICH COLUMNS are readable, but
-- never WHICH ROW -- there's no way to express "only your own row"
-- with a grant alone (same lesson as the churches.stripe_* fix
-- earlier this session, one level further: that fix only needed to
-- restrict columns; this one needs to restrict columns AND rows at
-- once). The working pattern, already proven this session with
-- is_platform_admin() and already used elsewhere in this codebase
-- for update_profile_name(): route anything "read/write MY OWN row
-- only" through a SECURITY DEFINER function scoped internally to
-- auth.uid(), and only keep genuinely cross-row-needed columns on
-- the raw table grant.
--
-- Every raw `.from('profiles')` read/write in the client was
-- checked (not guessed) to build this split:
--   - full_name: kept broadly readable by `authenticated` --
--     genuinely needed cross-row by ~15 real, already-shipped
--     features (church_staff/group_members/donations/event_
--     registrations/support_messages/platform_feedback embeds,
--     admin directory, insights donor/attendee name lookups).
--   - age_range: kept broadly readable by `authenticated` --
--     needed cross-row for the Insights donor/attendee age-bucket
--     breakdowns (reads OTHER people's age_range by id list).
--   - account_type, avatar_url, phone, is_platform_admin,
--     welcome_email_sent, full_name_changed_at: every real use of
--     these in the client is a read/write of the CALLER's own row
--     only (confirmed -- no cross-row read of any of these exists
--     anywhere in the app, avatar_url and full_name included, since
--     the two "other users' avatar_url" spots both already go
--     through the get_directory_people() RPC, not a raw select).
--     These all move to auth.uid()-scoped functions below and come
--     off the raw grant entirely, closing them for anon AND
--     authenticated, not just anon.
--   - plan_type: not read anywhere in the client at all -- dropped
--     from the grant on general principle, nothing depends on it.
--   - anon gets NO select and NO update on profiles at all, full
--     stop -- no legitimate feature reads or writes any profile
--     while signed out.

revoke select on profiles from anon;
revoke update on profiles from anon, authenticated;
revoke select on profiles from authenticated;
grant select (id, full_name, age_range) on profiles to authenticated;

-- ============================================================
-- Self-read: everything the client ever needs about "my own
-- profile" beyond full_name/age_range, in one call (used by the
-- Profile settings page).
-- ============================================================
create or replace function get_my_private_profile()
returns table(
  full_name text,
  account_type text,
  phone text,
  avatar_url text,
  age_range text,
  full_name_changed_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select full_name, account_type, phone, avatar_url, age_range, full_name_changed_at
  from profiles
  where id = auth.uid();
$$;
grant execute on function get_my_private_profile() to authenticated;

-- ============================================================
-- Self-read: just the account_type flag (used by updateAuthUI /
-- routeAfterLogin, alongside the existing is_platform_admin() RPC).
-- Kept separate from get_my_private_profile() above rather than
-- reusing it there, matching this app's existing small-single-
-- purpose-RPC style (is_platform_admin(), get_person_giving_
-- history(), etc.) and so these two auth-path functions don't pull
-- back phone/avatar_url/full_name_changed_at they don't use.
-- ============================================================
create or replace function get_my_account_type()
returns text
language sql
security definer
set search_path = public
as $$
  select account_type from profiles where id = auth.uid();
$$;
grant execute on function get_my_account_type() to authenticated;

-- ============================================================
-- Self-write RPCs, one per field the client actually sets. Each is
-- a harmless no-op if called with no session (auth.uid() is null,
-- matches no row) rather than erroring.
-- ============================================================

create or replace function update_my_phone(p_phone text)
returns void
language sql
security definer
set search_path = public
as $$
  update profiles set phone = p_phone where id = auth.uid();
$$;
grant execute on function update_my_phone(text) to authenticated;

create or replace function update_my_avatar(p_avatar_url text)
returns void
language sql
security definer
set search_path = public
as $$
  update profiles set avatar_url = p_avatar_url where id = auth.uid();
$$;
grant execute on function update_my_avatar(text) to authenticated;

create or replace function update_my_age_range(p_age_range text)
returns void
language sql
security definer
set search_path = public
as $$
  update profiles set age_range = p_age_range where id = auth.uid();
$$;
grant execute on function update_my_age_range(text) to authenticated;

create or replace function mark_my_account_type_church()
returns void
language sql
security definer
set search_path = public
as $$
  update profiles set account_type = 'church' where id = auth.uid();
$$;
grant execute on function mark_my_account_type_church() to authenticated;

-- Atomic check-and-set: sets welcome_email_sent = true and returns
-- whatever it was BEFORE this call, replacing the old
-- select-then-update pair with one round trip. The two call sites
-- that just want the "set true" side effect (and don't care about
-- the old value) can call this and ignore the return value.
create or replace function mark_my_welcome_email_sent()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare was_already_set boolean;
begin
  select welcome_email_sent into was_already_set from profiles where id = auth.uid();
  update profiles set welcome_email_sent = true where id = auth.uid();
  return coalesce(was_already_set, false);
end;
$$;
grant execute on function mark_my_welcome_email_sent() to authenticated;

-- ============================================================
-- Not touched here, on purpose:
-- ============================================================
-- update_profile_name() -- already exists, already SECURITY
-- DEFINER, already the exact pattern this migration follows for
-- everything else. Unaffected by the revokes above regardless of
-- its internal implementation, since SECURITY DEFINER functions run
-- with the function owner's privileges, not the caller's grants.
--
-- is_platform_admin() -- already fixed and shipped earlier this
-- session; left as-is and still used by updateAuthUI/routeAfterLogin
-- alongside the new get_my_account_type() above.
--
-- get_directory_people(), find_church_people_by_email(), and the
-- other already-audited admin/staff RPCs that join to profiles
-- internally (full_name, phone, avatar_url) for OTHER users --
-- SECURITY DEFINER, already gated on owner-or-staff, unaffected by
-- anything revoked here.

-- A self-read/write RPC for phone (update_my_phone above) was later
-- also confirmed run and verified live: RPC-gated correctly, raw
-- select denied, insert/duplicate paths both correct.
