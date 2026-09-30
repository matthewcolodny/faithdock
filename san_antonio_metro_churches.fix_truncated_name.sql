-- Corrects one church name that was truncated in the raw IRS source
-- (found by the "ends in a bare preposition/article/conjunction" audit
-- -- see GOTCHAS.md). Confirmed via multiple independent public
-- directories (Net Ministries, Chamber of Commerce, Brownbook) before
-- making this change -- not a guess.
--
-- The other two names flagged by that same audit are deliberately left
-- alone here:
--   "Christian Fellowship Church Of" -- no confident external source
--   found for its real name.
--   "Church of the Good Shepherd Orthodox Order of St Benedict in A" --
--   "in America" is a plausible completion but unconfirmed; not worth
--   acting on without a firmer source.
-- Scoped by id (not just name) since the name itself is what's changing.

UPDATE churches
SET name = 'Greater Evangelist Temple Church of God in Christ'
WHERE id = '661bd083-36f5-45de-aa61-2961a82c2ad7'
  AND name = 'Greater Evangelist Temple Church Of';
