let Lude = ../Deps/Lude.dhall

let Prelude = ../Deps/Prelude.dhall

let Model = ../Deps/Contract.dhall

let ImportSet = ../Structures/ImportSet.dhall

let CustomKind = ../Structures/CustomKind.dhall

let PyIdent = ../Structures/PyIdent.dhall

let OnUnsupported = ../Structures/OnUnsupported.dhall

let Value = ./Value.dhall

let Config =
      { packageName : Text
      , importName : Text
      , emitSync : Bool
      , onUnsupported : OnUnsupported.Mode
      }

let Input = Model.Member

let Output = { fieldName : Text, pyType : Text, imports : ImportSet.Type }

let runWithPrefix =
      \(prefix : Text) ->
      \(config : Config) ->
      \(lookup : CustomKind.Lookup) ->
      \(input : Input) ->
        -- Result-column / composite-field name becomes a dataclass field and decode
        -- kwarg, so a keyword-named column must be sanitized; row["..."] keeps the
        -- raw pgName. Only the keyword set is load-bearing here (a field named `row`
        -- is valid), unlike params which also avoid the template locals.
        let fieldName = PyIdent.pySafeName input.name.inSnakeCase

        let buildOutput =
              \(value : Value.Output) ->
                let nullableSuffix = if input.isNullable then " | None" else ""

                let pyType = Value.qualifyCustom prefix value ++ nullableSuffix

                let baseImports = value.imports

                in  merge
                      { Passthrough =
                          Lude.Compiled.ok
                            Output
                            { fieldName
                            , pyType
                            , imports = baseImports
                            }
                      , Custom =
                          Prelude.Optional.fold
                            Model.Name
                            value.scalar.customRef
                            (Lude.Compiled.Type Output)
                            ( \(name : Model.Name) ->
                                let typeName = name.inPascalCase

                                let customImport =
                                      \(order : Natural) ->
                                        { className = typeName
                                        , moduleName = name.inSnakeCase
                                        , order
                                        }

                                let mkOutput =
                                      \(customImports : ImportSet.Type) ->
                                        { fieldName
                                        , pyType
                                        , imports =
                                            ImportSet.combine baseImports customImports
                                        }

                                let dimsAtMostTwo =
                                      Natural/isZero (Natural/subtract 2 value.dims)

                                let dimsAtMostOne =
                                      Natural/isZero (Natural/subtract 1 value.dims)

                                in  merge
                                      { Enum =
                                          \(order : Natural) ->
                                            let enumImport =
                                                  ImportSet.customEnum
                                                    (customImport order)

                                            in  if dimsAtMostTwo
                                                then  Lude.Compiled.ok
                                                        Output
                                                        (mkOutput enumImport)
                                                else  Lude.Compiled.report
                                                        Output
                                                        [ input.pgName
                                                        , name.inSnakeCase
                                                        ]
                                                        "Array of an enum with dimensionality > 2 is not supported"
                                      , Composite =
                                          \ ( composite
                                            : { fields :
                                                  List CustomKind.CompositeField
                                              , order : Natural
                                              }
                                            ) ->
                                            if dimsAtMostOne
                                            then  Lude.Compiled.ok
                                                    Output
                                                    ( mkOutput
                                                        ( ImportSet.customComposite
                                                            (customImport composite.order)
                                                        )
                                                    )
                                            else  Lude.Compiled.report
                                                    Output
                                                    [ input.pgName
                                                    , name.inSnakeCase
                                                    ]
                                                    "Array of a composite type with dimensionality > 1 is not supported"
                                      , Absent =
                                          Lude.Compiled.report
                                            Output
                                            [ name.inSnakeCase ]
                                            "Custom type not found in project customTypes"
                                      }
                                      (lookup name)
                            )
                            ( Lude.Compiled.report
                                Output
                                [ input.pgName ]
                                "Custom scalar without a customRef name"
                            )
                      }
                      value.scalar.decode

        let compiledValue
            : Lude.Compiled.Type Value.Output
            = Lude.Compiled.nest
                Value.Output
                input.pgName
                (Value.run config input.value)

        in  Lude.Compiled.flatMap Value.Output Output buildOutput compiledValue

let run = runWithPrefix ""

in  { Input, Output, run, runWithPrefix }
