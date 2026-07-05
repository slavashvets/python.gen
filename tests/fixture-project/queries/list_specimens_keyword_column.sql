-- Keyword result-column coverage: the column aliased to the reserved word class
-- must emit a dataclass field and decode kwarg of class_ while the row lookup
-- keeps the raw "class". Without sanitization the generated _rows.py has a
-- SyntaxError, so this query locks the result-column guard (mirrors
-- list_specimens_by_class for params).
SELECT
  id,
  title AS "class"
FROM specimen
ORDER BY id ASC
