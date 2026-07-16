let Prelude = ../Deps/Prelude.dhall

let Identity =
      { className : Text, moduleName : Text, order : Natural }

let TypeKind =
      < Enum : Identity
      | Composite : Identity
      | Absent
      >

-- Index-aligned with a project's `customTypes` list: `Lookup` at position `i`
-- is the kind classification of `customTypes[i]`. Replaces the former
-- `Model.Name -> TypeKind` closure (which relied on `Text/equal`), so a
-- reference resolves by its `CustomTypeRef.index` instead of by name.
let Lookup = List TypeKind

-- Resolve a reference's kind by index; an out-of-range index reads as `Absent`
-- (mirrors gen-sdk's own `optionalIndex` helper in supportedCustomTypes.dhall).
let at =
      \(lookup : Lookup) ->
      \(index : Natural) ->
        Prelude.Optional.fold
          TypeKind
          (Prelude.List.index index TypeKind lookup)
          TypeKind
          (\(kind : TypeKind) -> kind)
          TypeKind.Absent

in  { TypeKind, Lookup, Identity, at }
