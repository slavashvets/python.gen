let Deps = ../Deps/package.dhall

let ImportSet = ../Structures/ImportSet.dhall

let Algebra = ../Algebras/Interpreter.dhall

let Lude = Deps.Lude

let Prelude = Deps.Prelude

let Model = Deps.Project

let Scalar = ./Scalar.dhall

let Input = Model.Value

let Output =
      { pyType : Text
      , imports : ImportSet.Type
      , scalar : Scalar.Output
      , dims : Natural
      , elementIsNullable : Bool
      }

let run =
      \(config : Algebra.Config) ->
      \(input : Input) ->
        Lude.Compiled.map
          Scalar.Output
          Output
          ( \(scalar : Scalar.Output) ->
              Prelude.Optional.fold
                Model.ArraySettings
                input.arraySettings
                Output
                ( \(arraySettings : Model.ArraySettings) ->
                    let elementType =
                          if    arraySettings.elementIsNullable
                          then  "${scalar.pyType} | None"
                          else  scalar.pyType

                    let arrayType =
                          Natural/fold
                            arraySettings.dimensionality
                            Text
                            (\(inner : Text) -> "list[${inner}]")
                            elementType

                    in  { pyType = arrayType
                        , imports = scalar.imports
                        , scalar
                        , dims = arraySettings.dimensionality
                        , elementIsNullable = arraySettings.elementIsNullable
                        }
                )
                { pyType = scalar.pyType
                , imports = scalar.imports
                , scalar
                , dims = 0
                , elementIsNullable = False
                }
          )
          (Scalar.run config input.scalar)

in  Algebra.module Input Output run
