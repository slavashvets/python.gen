let Model = ../Deps/Contract.dhall

let Identity =
      { className : Text, moduleName : Text, order : Natural }

let TypeKind =
      < Enum : Identity
      | Composite : Identity
      | Absent
      >

let Lookup = Model.Name -> TypeKind

in  { TypeKind, Lookup, Identity }
