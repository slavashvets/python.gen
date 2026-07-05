-- single row: insert exercising a single-field composite as a parameter and
-- (via RETURNING) as a result column, in the same statement.
INSERT INTO tagged_item (name, tag)
VALUES ($name, $tag)
RETURNING id, name, tag
