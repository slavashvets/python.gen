let Lude = ../Deps/Lude.dhall

let Model = ../Deps/Contract.dhall

let Sdk = ../Deps/Sdk.dhall

let ImportSet = ../Structures/ImportSet.dhall

let Primitive = ./Primitive.dhall

let Config = {}

let Input = Model.Scalar

-- Passthrough for primitives; Custom is opaque here. The enum-vs-composite
-- decision is mandatory in Member, ParamsMember, and CustomType consumers.
let ScalarDecode = < Passthrough | Custom >

let Output =
      { pyType : Text
      , imports : ImportSet.Type
      , customRef : Optional Model.CustomTypeRef
      , decode : ScalarDecode
      }

let run =
      \(config : Config) ->
      \(input : Input) ->
        merge
          { Primitive =
              \(primitive : Model.Primitive) ->
                Lude.Compiled.map
                  Primitive.Output
                  Output
                  ( \(p : Primitive.Output) ->
                      { pyType = p.pyType
                      , imports = p.imports
                      , customRef = None Model.CustomTypeRef
                      , decode = ScalarDecode.Passthrough
                      }
                  )
                  (Primitive.run {=} primitive)
          , Custom =
              \(ref : Model.CustomTypeRef) ->
                Lude.Compiled.ok
                  Output
                  { pyType = ref.name.inPascalCase
                  , imports = ImportSet.empty
                  , customRef = Some ref
                  , decode = ScalarDecode.Custom
                  }
          }
          input

in  Sdk.Sigs.interpreter Config Input Output run /\ { ScalarDecode }
