-- rows_affected: UPDATE without RETURNING, keyed by id; exercises the rowcount
-- execution path.
UPDATE specimen
SET rev = rev + 1
WHERE id = $id
