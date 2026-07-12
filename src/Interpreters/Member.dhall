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

-- decodeExpr is a Dhall function: given the source expression (e.g. row["x"] or
-- a composite tuple slot), it returns the Python decode expression. ResultColumns
-- and CustomType compose these so decode logic stays next to the type info.
let Output =
      { fieldName : Text
      , pgName : Text
      , pyType : Text
      , isNullable : Bool
      , imports : ImportSet.Type
      , decodeExpr : Text -> Text
      }

let run =
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

                let pyType = value.pyType ++ nullableSuffix

                let castTarget = pyType

                let baseImports = value.imports

                let passthroughDecode =
                      \(src : Text) -> "_cast(${castTarget}, ${src})"

                in  merge
                      { Passthrough =
                          Lude.Compiled.ok
                            Output
                            { fieldName
                            , pgName = input.pgName
                            , pyType
                            , isNullable = input.isNullable
                            , imports = ImportSet.combine baseImports ImportSet.cast
                            , decodeExpr = passthroughDecode
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
                                        , pgName = input.pgName
                                        , pyType
                                        , isNullable = input.isNullable
                                        , imports =
                                            ImportSet.combineAll
                                              [ baseImports
                                              , customImports
                                              , ImportSet.cast
                                              ]
                                        , decodeExpr = passthroughDecode
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

in  { Input, Output, run }
