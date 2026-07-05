-- many: array parameter via = any($pub_ids).
SELECT
  id, pub_id, feeling, title
FROM specimen
WHERE pub_id = ANY($pub_ids)
ORDER BY id ASC
