let Lude = ../Deps/Lude.dhall

let Prelude = ../Deps/Prelude.dhall

let Model = ../Deps/Contract.dhall

let Sdk = ../Deps/Sdk.dhall

let ImportSet = ../Structures/ImportSet.dhall

let OnUnsupported = ../Structures/OnUnsupported.dhall

let Scalar = ./Scalar.dhall

let Config =
      { packageName : Text
      , importName : Text
      , emitSync : Bool
      , onUnsupported : OnUnsupported.Mode
      }

let Input = Model.Value

let Output =
      { pyType : Text
      , imports : ImportSet.Type
      , scalar : Scalar.Output
      , dims : Natural
      , elementIsNullable : Bool
      }

let run =
      \(config : Config) ->
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

in  Sdk.Sigs.interpreter Config Input Output run
