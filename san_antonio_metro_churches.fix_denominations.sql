-- Corrects 8 rows where denomination was blank but the church's own name
-- states a specific tradition. Uses the actual tradition name (Anglican,
-- Nazarene) rather than lumping into a broader bucket -- the site's
-- denomination column is already free text (Church of God, Orthodox,
-- Apostolic already coexist with the filter UI's coarser checkbox list),
-- so this is consistent with the existing data, not a new pattern.
-- Scoped by name+address (not just name) to avoid touching a same-named
-- church elsewhere. All 8 are part of this batch's filename.

UPDATE churches SET denomination = 'Protestant / Evangelical'
WHERE import_source_filename = 'san_antonio_metro_churches.clean.csv'
  AND name = 'Air Force Village Protestant Church'
  AND address = '4917 RAVENSWOOD DR, SAN ANTONIO, TX 78227-4320';

UPDATE churches SET denomination = 'Protestant / Evangelical'
WHERE import_source_filename = 'san_antonio_metro_churches.clean.csv'
  AND name = 'Air Force Village Ii Protestant Church'
  AND address = '5100 JOHN D RYAN BLVD, SAN ANTONIO, TX 78245-3527';

UPDATE churches SET denomination = 'Anglican'
WHERE import_source_filename = 'san_antonio_metro_churches.clean.csv'
  AND name = 'Christ Our King Anglican Church'
  AND address = '115 KINGS WAY, NEW BRAUNFELS, TX 78132-3940';

UPDATE churches SET denomination = 'Anglican'
WHERE import_source_filename = 'san_antonio_metro_churches.clean.csv'
  AND name = 'St Chads Anglican Church'
  AND address = 'PO BOX 781432, SAN ANTONIO, TX 78278-1432';

UPDATE churches SET denomination = 'Anglican'
WHERE import_source_filename = 'san_antonio_metro_churches.clean.csv'
  AND name = 'Church of the Redeemer - Anglican'
  AND address = '244 FM 306 STE 120 PMB 321, NEW BRAUNFELS, TX 78130-5487';

UPDATE churches SET denomination = 'Nazarene'
WHERE import_source_filename = 'san_antonio_metro_churches.clean.csv'
  AND name = 'Crossroads Community Church of the Nazarene'
  AND address = '5834 RAY ELLISON BLVD, SAN ANTONIO, TX 78242-2029';

UPDATE churches SET denomination = 'Nazarene'
WHERE import_source_filename = 'san_antonio_metro_churches.clean.csv'
  AND name = 'Connection Point Church of the Nazarene'
  AND address = '210 W KLEIN RD, NEW BRAUNFELS, TX 78130-9628';

UPDATE churches SET denomination = 'Nazarene'
WHERE import_source_filename = 'san_antonio_metro_churches.clean.csv'
  AND name = 'Texas-Oklahoma Latin District Church of the Nazarene'
  AND address = '137 JEANETTE DR, SAN ANTONIO, TX 78216-7307';
