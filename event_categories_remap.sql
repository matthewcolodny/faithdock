-- One-off data correction. Run in the Supabase SQL Editor.
-- Untracked on purpose (repo-root convention for one-off scripts).
--
-- The category set changed in build 2026-09-17-v74:
--   Community            -> Fellowship
--   Classes + Studies    -> Classes & Studies   (merged)
--   Holidays             -> removed
--
-- The client only ever showed the NEW set after that build, but
-- category_tags is a plain text[] holding whatever was written at the
-- time -- so an event tagged 'Community' would quietly stop matching
-- any filter: still tagged, no longer reachable. That is the failure
-- this fixes.
--
-- As anon I could see exactly one event and zero category tags in use,
-- so this may well be a no-op. It exists because "may well be" isn't
-- "is" -- private and members-only events, and events at hidden
-- churches, aren't visible from here at all.

-- === 1. Look before you write ===
-- Run this on its own first. If it returns no rows, stop: there is
-- nothing to migrate and step 2 would be a no-op anyway.
select id, title, category_tags
from events
where category_tags && array['Community', 'Classes', 'Studies', 'Holidays']
order by start_at desc;

-- === 2. The remap ===
-- Rebuilds each affected array rather than doing four separate
-- array_replace passes, because two of the old values collapse into one
-- new one: an event tagged BOTH 'Classes' and 'Studies' must end up
-- with a single 'Classes & Studies', not a duplicate. distinct handles
-- that; sequential replaces would not.
--
-- 'Holidays' is dropped by the WHERE inside the subquery rather than
-- mapped to anything. Folding it into Celebrations was the alternative
-- and would have been a guess about what those events actually are --
-- if you'd rather do that, change the filter to a fifth `when` branch.
--
-- An event whose ONLY tag was 'Holidays' ends up with '{}' (via the
-- coalesce), not null -- matching how an untagged event is already
-- stored, so search_events' `array_length(...) is null` check keeps
-- treating it the same way.
update events
set category_tags = (
  select coalesce(array_agg(distinct mapped order by mapped), '{}')
  from (
    select case tag
             when 'Community' then 'Fellowship'
             when 'Classes'   then 'Classes & Studies'
             when 'Studies'   then 'Classes & Studies'
             else tag
           end as mapped
    from unnest(events.category_tags) as tag
    where tag <> 'Holidays'
  ) m
)
where category_tags && array['Community', 'Classes', 'Studies', 'Holidays'];

-- === 3. Confirm ===
-- Expect zero rows. Anything returned here still carries a retired
-- value and would be invisible to the category filters.
select id, title, category_tags
from events
where category_tags && array['Community', 'Classes', 'Studies', 'Holidays'];
