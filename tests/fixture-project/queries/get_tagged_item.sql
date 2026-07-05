-- zero_or_one: select by pk with limit 1; the single-field composite here is
-- purely a result column (no parameter use).
SELECT
  id, name, tag
FROM tagged_item
WHERE id = $id
LIMIT 1
