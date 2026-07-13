let Lude = ../Deps/Lude.dhall

let Prelude = ../Deps/Prelude.dhall

let Model = ../Deps/Contract.dhall

let Sdk = ../Deps/Sdk.dhall

let ImportSet = ../Structures/ImportSet.dhall

let Scalar = ./Scalar.dhall

let Config = {}

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
          (Scalar.run {=} input.scalar)

let qualifyCustom
    : Text -> Text -> Output -> Text
    = \(prefix : Text) ->
      \(className : Text) ->
      \(value : Output) ->
        Prelude.Optional.fold
          Model.Name
          value.scalar.customRef
          Text
          ( \(name : Model.Name) ->
              Text/replace
                name.inPascalCase
                (prefix ++ className)
                value.pyType
          )
          value.pyType

in  Sdk.Sigs.interpreter Config Input Output run /\ { qualifyCustom }
