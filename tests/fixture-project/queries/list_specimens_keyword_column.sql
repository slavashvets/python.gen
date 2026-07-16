-- Keyword result-column coverage: the SQL column aliased to reserved word class
-- stays named "class", while the statement-local Row field is class_.
-- psycopg args_row constructs that Row positionally, so no name remapping
-- can hide a missed sanitizer. Without sanitization the canonical statement
-- is invalid Python; this query locks the result-column guard.
SELECT
  id,
  title AS "class"
FROM specimen
ORDER BY id ASC
