-- zero_or_one: select by pk with limit 1.
SELECT
  id, pub_id,
  flag, small, medium, large, ratio, precise,
  title, code, letter, born_on, created_at, amount, blob,
  doc_json, doc_jsonb,
  maybe_text, maybe_int, maybe_uuid, maybe_ts, maybe_num,
  tags, related_ids, grid,
  feeling, origin,
  label, rev, meta
FROM specimen
WHERE id = $id
LIMIT 1
