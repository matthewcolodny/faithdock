-- Run in Supabase SQL Editor -- BUT ONLY AFTER confirming a profile
-- photo now uploads successfully. See the note at the bottom.
--
-- 056's own-folder rules are currently doing nothing.
--
-- The listing 056 printed showed four older, LOOSER policies still in
-- place beside the two it added:
--
--   INSERT  Authenticated users can upload church logos
--             bucket_id = 'church-logos' AND auth.role() = 'authenticated'
--   INSERT  Authenticated users can upload event images
--             bucket_id = 'event-images' AND auth.role() = 'authenticated'
--   INSERT  users can upload their own profile photo
--             bucket_id = 'profile-photos' AND auth.uid() IS NOT NULL
--   UPDATE  Authenticated users can update church logos
--   UPDATE  users can update their own profile photo
--
-- None of them constrains the PATH. Permissive policies OR together,
-- so while these exist, "(storage.foldername(name))[1] = auth.uid()"
-- is not enforced for anybody: any signed-in person can still write to
-- any path in any of the three buckets, including a folder named after
-- someone else's user id.
--
-- This is the 049 lesson in policy form rather than grant form. Adding
-- a stricter rule beside a looser one narrows nothing -- the looser
-- one still permits. 056 read as a tightening and was not one.
--
-- === Why dropping these is safe ===
-- Checked in the client rather than assumed: all three upload sites
-- build their path as <auth.uid()>/<timestamp>-<filename>, so every
-- upload the app makes satisfies the own-folder rule that remains.
-- Edge functions use the service role, which bypasses RLS entirely
-- and is unaffected either way.
--
-- Note the third one's name: "users can upload their own profile
-- photo" is what it was called, but `auth.uid() IS NOT NULL` is not
-- "their own" -- it is "anyone signed in", to any path. The policy
-- 056 added is the one that matches that name.

drop policy if exists "Authenticated users can upload church logos" on storage.objects;
drop policy if exists "Authenticated users can upload event images" on storage.objects;
drop policy if exists "users can upload their own profile photo" on storage.objects;
drop policy if exists "Authenticated users can update church logos" on storage.objects;
drop policy if exists "users can update their own profile photo" on storage.objects;

-- Confirm what is left: exactly one INSERT and one UPDATE policy,
-- both path-scoped. Read it rather than trusting the drops.
select policyname, cmd, roles::text, qual, with_check
  from pg_policies
 where schemaname = 'storage' and tablename = 'objects'
 order by cmd, policyname;

-- === RUN ORDER MATTERS ===
-- Upload a profile photo, a church logo and an event image FIRST, with
-- the older policies still in place. If any of them still fails, the
-- cause is not the policies and dropping the permissive ones removes
-- the fallback that is currently making those uploads work at all --
-- turning one broken upload into three. Confirm uploads work, then run
-- this, then confirm they still work.
