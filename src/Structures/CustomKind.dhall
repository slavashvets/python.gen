let Model = ../Deps/Contract.dhall

let CompositeField = { fieldName : Text, pyType : Text }

let TypeKind =
      < Enum : Natural
      | Composite : { fields : List CompositeField, order : Natural }
      | Absent
      >

let Lookup = Model.Name -> TypeKind

in  { TypeKind, Lookup, CompositeField }
