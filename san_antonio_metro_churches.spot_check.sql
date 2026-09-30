-- 5 random visible churches from this batch, for a final spot-check.
SELECT name, address, denomination, is_hidden
FROM churches
WHERE import_source_filename = 'san_antonio_metro_churches.clean.csv'
  AND is_hidden = false
ORDER BY random()
LIMIT 5;
