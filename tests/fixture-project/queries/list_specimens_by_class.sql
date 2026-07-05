-- Keyword-param coverage: the placeholder `class` is a Python reserved word, so
-- the generated signature must use `class_` while the params-dict key and the
-- %(class)s placeholder keep the raw name. Without sanitization this query emits
-- an un-importable signature, so its presence locks the keyword guard.
SELECT
  id,
  title
FROM specimen
WHERE title = $class
ORDER BY id ASC
