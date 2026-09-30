-- Do any name+address pairs appear more than once among rows tagged with
-- this batch's filename? If the CSV had 1,263 distinct rows imported but
-- the database has duplicate inserts for some of them, that would inflate
-- the dry-run count above the expected 852 without showing up as
-- "missing" in the earlier checks (both duplicates match fine).
SELECT name, address, COUNT(*) AS n
FROM churches
WHERE import_source_filename = 'san_antonio_metro_churches.clean.csv'
GROUP BY name, address
HAVING COUNT(*) > 1
ORDER BY n DESC, name;
