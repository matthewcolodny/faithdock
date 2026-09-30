-- Follow-up to san_antonio_metro_churches.fix_denominations.sql (already
-- run) -- same pattern: denomination was blank/null but the church's own
-- name states a specific tradition. "Foursquare" (International Church
-- of the Foursquare Gospel) is a Pentecostal body, per direct
-- confirmation. Scoped by id, not name+address, since all 3 rows were
-- looked up directly from the live database rather than a CSV batch.
--
-- Their denomination_tags (the multi-value Tradition filter column) are
-- already correct -- compute_denomination_tags() matches "foursquare" in
-- the church's own name and tags all 3 ['Protestant','Pentecostal &
-- Charismatic'] regardless of what's in this single-value column. This
-- migration only fixes the single-value `denomination` column, which
-- drives the card badge and church-profile display text -- with it null,
-- the UI's own null-fallback shows "Non-denominational" on the card,
-- which is what surfaced this: "New Braunfels Central Tx Foursquare
-- Church" displaying a NON-DENOMINATIONAL badge despite clearly being a
-- Foursquare (Pentecostal) congregation by name.

UPDATE churches SET denomination = 'Pentecostal'
WHERE id = 'd6fb3518-8a0d-4894-b4bd-74d2699e3320'
  AND name = 'San Antonio Pecan Valley Foursquare Church';

UPDATE churches SET denomination = 'Pentecostal'
WHERE id = '41b92f5d-b1a3-4413-b7ef-5cf46672631a'
  AND name = 'New Braunfels Central Tx Foursquare Church';

UPDATE churches SET denomination = 'Pentecostal'
WHERE id = '90e2bd93-2beb-4b33-8701-76a55c89e931'
  AND name = 'San Antonio North Foursquare Church';
