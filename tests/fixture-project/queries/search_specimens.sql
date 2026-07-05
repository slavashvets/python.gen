-- many: nullable parameter via coalesce, jsonb containment parameter, and a
-- domain comparison with the param cast to the base type (pgn cannot bind a
-- domain parameter directly).
SELECT
  id, title, label, meta
FROM specimen
WHERE
  title ILIKE COALESCE($title_like, '%')
  AND meta @> $meta_filter::jsonb
  AND label = COALESCE($label::text, label)
ORDER BY id ASC
