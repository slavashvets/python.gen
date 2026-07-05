let Deps = ../Deps/package.dhall

let Model = Deps.Project

-- A composite field as the decode/encode sites need it: the Python attribute
-- name and the rendered Python type (already nullability-applied). Threaded so
-- a column decode can build `Point2D(*cast(tuple[x, y], src))` and a param
-- encode can build `(value.x, value.y)` without re-reading the customType.
let CompositeField = { fieldName : Text, pyType : Text }

-- Classification of a custom type referenced by a Scalar.Custom name. Composite
-- carries its field list so callers render per-field decode/encode. Absent means
-- the name did not resolve against project.customTypes, which is a model
-- inconsistency the caller turns into a Compiled error.
-- Enum and Composite both carry `order`, the type's alphabetical position in
-- project.customTypes; the import renderer sorts on it so the per-module
-- `from ..types.X import Y` block stays alphabetical regardless of column order.
-- NOTE: union is named TypeKind because `Kind` is a reserved Dhall keyword.
let TypeKind =
      < Enum : Natural
      | Composite : { fields : List CompositeField, order : Natural }
      | Absent
      >

-- Resolves a custom-type Name to its TypeKind. Project.run builds this from
-- project.customTypes and threads it into Member/ParamsMember (and onward to
-- Result/ResultColumns) so those interpreters can pick the right decode/encode.
let Lookup = Model.Name -> TypeKind

in  { TypeKind, Lookup, CompositeField }
