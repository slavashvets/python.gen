-- single row: insert ... returning the full type surface.
-- jsonb param ($doc_jsonb), enum param ($feeling), composite param ($origin).
-- The domain columns (label, rev, meta) get literal/default values rather than
-- parameters. pgn cannot bind a parameter to a checked domain column: a
-- raw domain param is rejected, and a base-type-cast param fails the domain
-- CHECK against the synthetic probe value. Domain mapping is still exercised
-- through the RETURNING clause and the read queries below.
INSERT INTO specimen (
  flag, small, medium, large, ratio, precise,
  title, code, letter, born_on, amount, blob,
  doc_json, doc_jsonb,
  maybe_text, maybe_int, maybe_uuid, maybe_ts, maybe_num,
  tags, related_ids, grid,
  feeling, moods, origin,
  label, rev, meta
)
VALUES (
  $flag, $small, $medium, $large, $ratio, $precise,
  $title, $code, $letter, $born_on, $amount, $blob,
  $doc_json::json, $doc_jsonb::jsonb,
  $maybe_text, $maybe_int, $maybe_uuid, $maybe_ts, $maybe_num,
  $tags, $related_ids, $grid,
  $feeling, $moods::mood[], $origin,
  'specimen', 1, '{}'::jsonb
)
RETURNING
  id, pub_id,
  flag, small, medium, large, ratio, precise,
  title, code, letter, born_on, created_at, amount, blob,
  doc_json, doc_jsonb,
  maybe_text, maybe_int, maybe_uuid, maybe_ts, maybe_num,
  tags, related_ids, grid,
  feeling, moods, origin,
  label, rev, meta
