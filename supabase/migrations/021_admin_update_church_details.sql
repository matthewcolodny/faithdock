-- Run in Supabase SQL Editor.
--
-- Lets a platform admin correct a church's core public-facing fields
-- (name, denomination, address, phone, website) from the admin church
-- detail page. The normal churches UPDATE RLS is owner-only, so this is
-- the only way an UNCLAIMED church's info can ever be corrected -- there
-- is no owner to do it from the normal dashboard -- though it works
-- identically for a claimed church too.
--
-- Re-geocodes only when the caller says the address actually changed
-- (p_update_coords) -- an unrelated name/phone/website fix shouldn't
-- touch already-good lat/lng. p_lat/p_lng are the client's own fresh
-- Google geocode result for the new address; if that lookup failed (no
-- result, or Maps unavailable client-side), the client still saves the
-- text change and passes p_lat/p_lng as null -- coordinates are cleared
-- rather than left silently pointing at the OLD address, which would be
-- worse (a church that reads as "at" a location it no longer is).
--
-- dedupe_key isn't touched here -- it's never included in any explicit
-- INSERT column list either (see admin_import_churches in migration
-- 020), which is consistent with it being a generated/computed column
-- that Postgres keeps in sync on its own. If that assumption turns out
-- to be wrong, dedupe_key would go stale after a name/address edit --
-- worth confirming directly against the live schema if that's ever a
-- concern.

create or replace function admin_update_church_details(
  target_church_id uuid,
  p_name text,
  p_denomination text default null,
  p_address text default null,
  p_phone text default null,
  p_website text default null,
  p_lat double precision default null,
  p_lng double precision default null,
  p_update_coords boolean default false
)
returns void
language plpgsql
security definer
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
      website = p_website
    where id = target_church_id;
  end if;
end;
$$;

grant execute on function admin_update_church_details(uuid, text, text, text, text, text, double precision, double precision, boolean) to authenticated;

notify pgrst, 'reload schema';
