-- The generator's response when a query or custom type hits a PG shape none of
-- Primitive/CustomType/ParamsMember can render (see their `unsupported`/
-- `report`/Domain branches). Fail (default) aborts generation with the
-- offending type named. Skip drops the smallest self-consistent unit instead
-- (a statement's Row + facade entry, or a custom type's module + types/
-- __init__ + _register entry) with a warning and keeps generating the rest,
-- mirroring java.gen's warn-and-skip-the-statement convention; a query that
-- depends on a skipped type is skipped too.
let Mode = < Fail | Skip >

in  { Mode }
