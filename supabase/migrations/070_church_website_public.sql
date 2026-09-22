-- Run in Supabase SQL Editor.
--
-- Whether a church's website shows on its public profile.
--
-- Default FALSE, including for every church already listed. Most of the
-- directory is unclaimed listings imported from public sources, and a
-- website on a listing the church has never seen reads as FaithDock
-- republishing them rather than representing them. Off until somebody
-- who owns the church says otherwise.
--
-- The column is about DISPLAY, not storage. churches.website keeps
-- whatever was imported either way: hiding it is reversible and losing
-- it is not, and an owner claiming their listing should find the field
-- already filled in rather than have to go and look it up.
alter table churches
  add column if not exists website_public boolean not null default false;

comment on column churches.website_public is
  'Whether website is shown on the public church profile. Default false: an imported listing has not been reviewed by anyone at that church yet.';

-- churches uses table-wide grants today, so these add nothing at
-- present. They exist for the same reason 068''s did: if this table is
-- ever moved to per-column grants, a new column is unreadable without
-- them, and the failure is a blank field rather than an error. Not a
-- way to narrow anything -- see 049.
grant select (website_public) on churches to anon, authenticated;
grant update (website_public) on churches to authenticated;

notify pgrst, 'reload schema';

do $verify$
declare
  visible_count integer;
begin
  if not exists (select 1 from information_schema.columns
                  where table_name = 'churches' and column_name = 'website_public') then
    raise exception 'VERIFY FAILED: churches.website_public was not added.';
  end if;

  -- The default is the whole point of this migration. A column that
  -- defaulted true would have published every imported website the
  -- moment the client started reading it.
  select count(*) into visible_count from churches where website_public;
  if visible_count <> 0 then
    raise exception 'VERIFY FAILED: % churches already have website_public set; expected none.', visible_count;
  end if;

  raise notice 'OK: churches.website_public added, off for all % listings.',
    (select count(*) from churches);
end
$verify$;
