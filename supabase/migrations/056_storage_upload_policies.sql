-- Run in Supabase SQL Editor.
--
-- "Adding a photo to profile photo gives error: new row violates row
-- level security policy."
--
-- That message is an INSERT WITH CHECK failure on storage.objects --
-- the profiles row is never reached, so update_my_avatar() is not
-- involved. Something is missing or not matching on the bucket.
--
-- === Written without seeing the current policies ===
-- Stated plainly rather than implied: the catalog was not available
-- when this was written, so this does not diagnose, it establishes.
-- Every policy is dropped by name and recreated, which is correct
-- whether it was missing, differently named, or differently worded.
--
-- The one thing to know about that: permissive policies OR together,
-- so if an equivalent policy already exists under another name, this
-- adds a redundant one rather than replacing it. Redundant, not
-- harmful -- but the listing at the bottom will show it, and a
-- duplicate is worth deleting once seen.
--
-- === All three buckets, because they are the same shape ===
-- Checked in the client rather than assumed: church-logos,
-- event-images and profile-photos all build their path as
--     <auth.uid()>/<timestamp>-<filename>
-- so one rule covers all three, and a policy written for only the
-- reported one would leave the identical bug waiting in the other two.
--
-- === What is deliberately NOT granted ===
-- SELECT. These are public buckets: the public object endpoint
-- bypasses RLS entirely, so a read policy is not needed to serve an
-- image URL -- it only enables LISTING, which is exactly what was
-- removed earlier to stop anyone with the anon key enumerating every
-- uploaded logo, event image and profile photo. Re-adding it here to
-- "fix uploads" would quietly undo that.
--
-- DELETE. Nothing in the client deletes a stored object: removing a
-- profile photo nulls the avatar URL and leaves the file. That is a
-- real (small) orphan problem, but granting a permission nothing uses
-- is not the fix for it.

-- === Uploading into your own folder ===
-- (storage.foldername(name))[1] is the first path segment, which the
-- client sets to the uploader's own id. Scoping to it is what stops
-- one signed-in person writing into another's folder.
drop policy if exists "Users can upload to their own folder" on storage.objects;
create policy "Users can upload to their own folder"
  on storage.objects for insert to authenticated
  with check (
    bucket_id in ('profile-photos', 'church-logos', 'event-images')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- === Overwriting your own file ===
-- Needed because the profile-photo upload passes upsert: true, which
-- makes storage-api take an INSERT ... ON CONFLICT path. The client
-- change alongside this migration removes that flag -- the path
-- already carries a timestamp, so it can never collide and the flag
-- was asking for a permission the operation does not need. The policy
-- stays regardless: an upload that replaces a file is a reasonable
-- thing to want later, and this is the correct rule for it.
drop policy if exists "Users can update their own uploads" on storage.objects;
create policy "Users can update their own uploads"
  on storage.objects for update to authenticated
  using (
    bucket_id in ('profile-photos', 'church-logos', 'event-images')
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id in ('profile-photos', 'church-logos', 'event-images')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- === Look at what is actually there now ===
-- Run this after the above and read it rather than trusting that the
-- statements succeeding means the policies are as intended -- 049 ran
-- clean and did nothing. Two policies for the same command on the
-- same bucket means an older one under a different name is still
-- present and should be dropped by that name.
select policyname, cmd, roles::text, qual, with_check
  from pg_policies
 where schemaname = 'storage' and tablename = 'objects'
 order by cmd, policyname;
