-- many: enum array parameter via = any($moods::mood[]); returns the enum array column.
SELECT
  id, pub_id, feeling, moods, title
FROM specimen
WHERE feeling = ANY($moods::mood[])
ORDER BY id ASC
