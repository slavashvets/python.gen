let Deps = ../Deps/package.dhall

let ImportSet = ../Structures/ImportSet.dhall

let Algebra = ../Algebras/Interpreter.dhall

let Lude = Deps.Lude

let Model = Deps.Sdk.Project

let Primitive = ./Primitive.dhall

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
      \(config : Algebra.Config) ->
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

in  Algebra.module Input Output run /\ { ScalarDecode }
