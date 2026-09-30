-- Hides 6 "Ministries"-named churches that were flagged during the
-- original San Antonio import (review_reason = ministries_no_match in
-- san_antonio_metro_churches.review_consolidated.csv) but were never
-- actually hidden -- a known, previously-identified gap: this repo's own
-- san_antonio_metro_churches.find_wrongly_visible.sql already anticipated
-- finding "around 6 rows" like this, but nothing ever ran an UPDATE to
-- fix it.
--
-- All 6 share the same zero-signal profile: matched = no (no Places
-- match attempt succeeded at all, not just a weak one), place_types
-- blank, no phone, no website -- in the original import data AND in the
-- live table today, confirming no owner has since claimed any of them
-- with real contact info. Confirmed live via a fresh cross-reference of
-- review_consolidated.csv against the current churches table (see
-- GOTCHAS.md) before generating this file -- not reused from memory.
--
-- Checked why the earlier attempt missed these: 5 of the 6 have an exact
-- name+address match against the review list (so a simple case/
-- whitespace mismatch, the theory in the old audit files' own comments,
-- doesn't explain most of them), and all 6 share the same created_at
-- timestamp as the rest of the batch (so they aren't a distinct later
-- insert either). The original miss's root cause is still unclear --
-- this file only fixes the current state, it doesn't re-diagnose why
-- the first attempt failed.
--
-- Hiding, not deleting: matches this project's existing pattern for
-- every other "this shouldn't be public" correction (admin_set_church_
-- hidden, the non-Christian-orgs hide, etc.) -- reversible, and an
-- owner could still claim and un-hide their own listing later if one of
-- these turns out to be real after all.

UPDATE churches SET is_hidden = true WHERE id IN (
  '70326648-7eb8-44fd-90a4-717953812d71', -- Mt Horeb International Prayer Camp Ministries Inc
  'd6903d47-00f3-48a6-9d35-e0c7ef3704f5', -- Servants Of Servants Ministries
  '2701aea7-f047-40a2-aadd-acdd043fb7cf', -- Mamrock Ministries Inc
  '7eff8683-c738-46af-b041-48f02fff30d8', -- Beacon Light Covenant Ministries
  'ce39b895-86b4-4c50-bfc2-d2795f9eb77e', -- Romanian Media Ministries Inc
  'bb920b89-6774-4382-8dad-8e592b2176b1'  -- Edem Hopeson Ministries
);
