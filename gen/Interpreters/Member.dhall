let Deps = ../Deps/package.dhall

let ImportSet = ../Structures/ImportSet.dhall

let CustomKind = ../Structures/CustomKind.dhall

let PyIdent = ../Structures/PyIdent.dhall

let Algebra = ../Algebras/Interpreter.dhall

let Lude = Deps.Lude

let Model = Deps.Sdk.Project

let Value = ./Value.dhall

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
      \(config : Algebra.Config) ->
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
                      \(src : Text) -> "cast(${castTarget}, ${src})"

                let enumDecode =
                      \(enumName : Text) ->
                      \(src : Text) ->
                        let call = "${enumName}(cast(str, ${src}))"

                        in  if    input.isNullable
                            then  "None if ${src} is None else ${call}"
                            else  call

                -- psycopg returns an enum array as a list of text, so each element
                -- is rebuilt into the StrEnum. The cast pins the iterable's element
                -- type; the per-element None guard mirrors elementIsNullable and the
                -- outer None guard mirrors a nullable column.
                let enumArrayDecode =
                      \(enumName : Text) ->
                      \(src : Text) ->
                        let elemCast =
                              if    value.elementIsNullable
                              then  "list[str | None]"
                              else  "list[str]"

                        let elemDecode =
                              if    value.elementIsNullable
                              then  "None if v is None else ${enumName}(v)"
                              else  "${enumName}(v)"

                        -- require_array fails loudly if the array came back as
                        -- text (the connection did not register the enum type)
                        -- instead of iterating a string into bogus members.
                        let elements =
                              "[${elemDecode} for v in cast(${elemCast}, require_array(${src}))]"

                        in  if    input.isNullable
                            then  "None if ${src} is None else ${elements}"
                            else  elements

                -- Composites are registered per connection (see register_types),
                -- so psycopg returns a namedtuple. The fixed-length tuple cast
                -- with each field's exact pyType lets the splat satisfy strict.
                let compositeDecode =
                      \(typeName : Text) ->
                      \(fields : List CustomKind.CompositeField) ->
                      \(src : Text) ->
                        let fieldTypes =
                              Deps.Prelude.Text.concatMapSep
                                ", "
                                CustomKind.CompositeField
                                (\(f : CustomKind.CompositeField) -> f.pyType)
                                fields

                        let call =
                              "${typeName}(*cast(tuple[${fieldTypes}], ${src}))"

                        in  if    input.isNullable
                            then  "None if ${src} is None else ${call}"
                            else  call

                in  merge
                      { Passthrough =
                          Lude.Compiled.ok
                            Output
                            { fieldName
                            , pgName = input.pgName
                            , pyType
                            , isNullable = input.isNullable
                            , imports = baseImports
                            , decodeExpr = passthroughDecode
                            }
                      , Custom =
                          Deps.Prelude.Optional.fold
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
                                      \(decodeExpr : Text -> Text) ->
                                        { fieldName
                                        , pgName = input.pgName
                                        , pyType
                                        , isNullable = input.isNullable
                                        , imports =
                                            ImportSet.combine
                                              baseImports
                                              customImports
                                        , decodeExpr
                                        }

                                -- A 1-D enum array decodes element-wise; a scalar
                                -- custom (dims == 0) keeps the single-value decode.
                                -- Composite arrays and dims > 1 are unimplemented,
                                -- so fail loudly rather than emit wrong Python.
                                let dimsIsOne =
                                      Natural/isZero (Natural/subtract 1 value.dims)

                                in  merge
                                      { Enum =
                                          \(order : Natural) ->
                                            let enumImport =
                                                  ImportSet.customEnum
                                                    (customImport order)

                                            in  if    Natural/isZero value.dims
                                                then  Lude.Compiled.ok
                                                        Output
                                                        ( mkOutput
                                                            enumImport
                                                            (enumDecode typeName)
                                                        )
                                                else  if    dimsIsOne
                                                then  Lude.Compiled.ok
                                                        Output
                                                        ( mkOutput
                                                            ( ImportSet.combine
                                                                enumImport
                                                                ImportSet.enumArray
                                                            )
                                                            (enumArrayDecode typeName)
                                                        )
                                                else  Lude.Compiled.report
                                                        Output
                                                        [ input.pgName
                                                        , name.inSnakeCase
                                                        ]
                                                        "Array of an enum with dimensionality > 1 is not supported"
                                      , Composite =
                                          \ ( composite
                                            : { fields :
                                                  List CustomKind.CompositeField
                                              , order : Natural
                                              }
                                            ) ->
                                            if    Natural/isZero value.dims
                                            then  Lude.Compiled.ok
                                                    Output
                                                    ( mkOutput
                                                        ( ImportSet.customComposite
                                                            (customImport composite.order)
                                                        )
                                                        ( compositeDecode
                                                            typeName
                                                            composite.fields
                                                        )
                                                    )
                                            else  Lude.Compiled.report
                                                    Output
                                                    [ input.pgName
                                                    , name.inSnakeCase
                                                    ]
                                                    "Array of a composite type is not supported (element-wise decode is unimplemented)"
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

let Run = Algebra.Config -> CustomKind.Lookup -> Input -> Lude.Compiled.Type Output

in  { Input, Output, Run, run }
