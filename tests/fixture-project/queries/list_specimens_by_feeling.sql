-- many: select with order by. Enum parameter ($feeling).
SELECT
  id, pub_id, feeling, title, label, rev, origin, tags, meta
FROM specimen
WHERE feeling = $feeling
ORDER BY id ASC
