let Lude = ../Deps/Lude.dhall

let Model = ../Deps/Contract.dhall

let Sdk = ../Deps/Sdk.dhall

let ImportSet = ../Structures/ImportSet.dhall

let OnUnsupported = ../Structures/OnUnsupported.dhall

let Primitive = ./Primitive.dhall

let Config =
      { packageName : Text
      , importName : Text
      , sync : Bool
      , onUnsupported : OnUnsupported.Mode
      }

let Input = Model.Scalar

-- Passthrough for primitives; Custom is opaque here. The enum-vs-composite
-- decision needs the project customTypes lookup, which lives in F/G, not here.
let ScalarDecode = < Passthrough | Custom >

let Output =
      { pyType : Text
      , imports : ImportSet.Type
      , customRef : Optional Model.Name
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
                      , customRef = None Model.Name
                      , decode = ScalarDecode.Passthrough
                      }
                  )
                  (Primitive.run config primitive)
          , Custom =
              \(name : Model.Name) ->
                Lude.Compiled.ok
                  Output
                  { pyType = name.inPascalCase
                  , imports = ImportSet.empty
                  , customRef = Some name
                  , decode = ScalarDecode.Custom
                  }
          }
          input

in  Sdk.Sigs.interpreter Config Input Output run /\ { ScalarDecode }
