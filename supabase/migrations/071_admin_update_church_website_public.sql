-- Run in Supabase SQL Editor. Requires 070 (churches.website_public).
--
-- Lets the platform admin switch a church's website on and off from the
-- admin page. Body is 021's, with one column added.
--
-- DROP then CREATE, not CREATE OR REPLACE. Adding a parameter changes
-- the signature, and REPLACE with a different signature does not
-- replace anything -- it creates a SECOND function. Both would then
-- match a call that omits the new argument, and PostgREST would answer
-- with an ambiguity error rather than picking one. Dropping by the old,
-- fully-qualified signature is the only way to be sure which one is
-- gone.
drop function if exists admin_update_church_details(
  uuid, text, text, text, text, text, double precision, double precision, boolean
);

create function admin_update_church_details(
  target_church_id uuid,
  p_name text,
  p_denomination text default null,
  p_address text default null,
  p_phone text default null,
  p_website text default null,
  p_lat double precision default null,
  p_lng double precision default null,
  p_update_coords boolean default false,
  -- Appended last and defaulted, so a caller that has not been updated
  -- yet still works and simply leaves the flag alone... except that it
  -- cannot: this is a plain assignment, not a coalesce, so omitting it
  -- would switch the website OFF. Defaulting to false is the safe
  -- direction (hidden), and the client always sends it explicitly.
  p_website_public boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_platform_admin() then
    raise exception 'You do not have permission to edit church details.';
  end if;

  if p_name is null or trim(p_name) = '' then
    raise exception 'Church name is required.';
  end if;

  if p_update_coords then
    update churches
    set
      name = p_name,
      denomination = p_denomination,
      address = p_address,
      phone = p_phone,
      website = p_website,
      website_public = p_website_public,
      lat = p_lat,
      lng = p_lng
    where id = target_church_id;
  else
    update churches
    set
      name = p_name,
      denomination = p_denomination,
      address = p_address,
      phone = p_phone,
      website = p_website,
      website_public = p_website_public
    where id = target_church_id;
  end if;
end;
$$;

grant execute on function admin_update_church_details(
  uuid, text, text, text, text, text, double precision, double precision, boolean, boolean
) to authenticated;

notify pgrst, 'reload schema';

do $verify$
declare
  overloads integer;
begin
  -- Exactly one. Two would mean the drop above missed, and every call
  -- from the admin page would start failing on ambiguity.
  select count(*) into overloads
    from pg_proc where proname = 'admin_update_church_details';
  if overloads <> 1 then
    raise exception 'VERIFY FAILED: % versions of admin_update_church_details exist, expected 1.', overloads;
  end if;

  if not has_function_privilege('authenticated',
      'admin_update_church_details(uuid, text, text, text, text, text, double precision, double precision, boolean, boolean)',
      'EXECUTE') then
    raise exception 'VERIFY FAILED: the new signature is not executable.';
  end if;

  raise notice 'OK: admin_update_church_details now carries website_public.';
end
$verify$;
