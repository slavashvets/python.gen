let Model = ../Deps/Contract.dhall

let CompositeField = { fieldName : Text, pyType : Text }

let Identity =
      { className : Text, moduleName : Text, order : Natural }

let TypeKind =
      < Enum : Identity
      | Composite : { fields : List CompositeField, identity : Identity }
      | Absent
      >

let Lookup = Model.Name -> TypeKind

in  { TypeKind, Lookup, CompositeField, Identity }
