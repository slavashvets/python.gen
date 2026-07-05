let Deps = ../Deps/package.dhall

let ImportSet = ../Structures/ImportSet.dhall

let CustomKind = ../Structures/CustomKind.dhall

let Algebra = ../Algebras/Interpreter.dhall

let Lude = Deps.Lude

let Model = Deps.Project

let Value = ./Value.dhall

let Input = Model.Member

let PyIdent = ../Structures/PyIdent.dhall

-- Identifiers the statement template hardcodes around the splatted params: the
-- receiver `conn` and the locals `sql`/`params`/`decode`/`cur`/`row`. A param
-- named like one of these would collide (e.g. a duplicate `conn` argument), so
-- they are sanitized alongside the Python keywords.
let reservedNames =
      [ "conn", "sql", "params", "decode", "cur", "row" ]

-- A SQL placeholder may be spelled as a Python reserved word (e.g. $class, $from)
-- or clash with a template-reserved name (e.g. $conn). Suffix an underscore so the
-- emitted signature and bind variable are valid Python; the params-dict key and
-- the %(name)s placeholder keep the raw name (see Query.dhall), so psycopg still
-- binds by the original name.
let pySafeName = PyIdent.sanitizeAgainst (PyIdent.pythonKeywords # reservedNames)

let Output =
      { fieldName : Text
      , pgName : Text
      , pyType : Text
      , imports : ImportSet.Type
      , bindExpr : Text
      , needsJsonbImport : Bool
      }

-- True when the primitive is exactly json or jsonb (every other variant is
-- False). Detected against the model union, not the rendered pyType, so it stays
-- correct independent of the Primitive interpreter's type names.
let primitiveIsJson =
      \(primitive : Model.Primitive) ->
        merge
          { Bit = False
          , Bool = False
          , Box = False
          , Box2D = False
          , Box3D = False
          , Bpchar = False
          , Bytea = False
          , Char = False
          , Cidr = False
          , Circle = False
          , Citext = False
          , Date = False
          , Datemultirange = False
          , Daterange = False
          , Float4 = False
          , Float8 = False
          , Geography = False
          , Geometry = False
          , Hstore = False
          , Inet = False
          , Int2 = False
          , Int4 = False
          , Int4multirange = False
          , Int4range = False
          , Int8 = False
          , Int8multirange = False
          , Int8range = False
          , Interval = False
          , Json = True
          , Jsonb = True
          , Line = False
          , Lseg = False
          , Ltree = False
          , Macaddr = False
          , Macaddr8 = False
          , Money = False
          , Name = False
          , Numeric = False
          , Nummultirange = False
          , Numrange = False
          , Oid = False
          , Path = False
          , PgLsn = False
          , PgSnapshot = False
          , Point = False
          , Polygon = False
          , Text = False
          , Time = False
          , Timestamp = False
          , Timestamptz = False
          , Timetz = False
          , Tsmultirange = False
          , Tsquery = False
          , Tsrange = False
          , Tstzmultirange = False
          , Tstzrange = False
          , Tsvector = False
          , Uuid = False
          , Varbit = False
          , Varchar = False
          , Xml = False
          }
          primitive

-- True only for jsonb (json -> False), so the param encoder can pick Jsonb() vs
-- Json() rather than collapsing both to Jsonb().
let primitiveIsJsonb =
      \(primitive : Model.Primitive) ->
        merge
          { Bit = False
          , Bool = False
          , Box = False
          , Box2D = False
          , Box3D = False
          , Bpchar = False
          , Bytea = False
          , Char = False
          , Cidr = False
          , Circle = False
          , Citext = False
          , Date = False
          , Datemultirange = False
          , Daterange = False
          , Float4 = False
          , Float8 = False
          , Geography = False
          , Geometry = False
          , Hstore = False
          , Inet = False
          , Int2 = False
          , Int4 = False
          , Int4multirange = False
          , Int4range = False
          , Int8 = False
          , Int8multirange = False
          , Int8range = False
          , Interval = False
          , Json = False
          , Jsonb = True
          , Line = False
          , Lseg = False
          , Ltree = False
          , Macaddr = False
          , Macaddr8 = False
          , Money = False
          , Name = False
          , Numeric = False
          , Nummultirange = False
          , Numrange = False
          , Oid = False
          , Path = False
          , PgLsn = False
          , PgSnapshot = False
          , Point = False
          , Polygon = False
          , Text = False
          , Time = False
          , Timestamp = False
          , Timestamptz = False
          , Timetz = False
          , Tsmultirange = False
          , Tsquery = False
          , Tsrange = False
          , Tstzmultirange = False
          , Tstzrange = False
          , Tsvector = False
          , Uuid = False
          , Varbit = False
          , Varchar = False
          , Xml = False
          }
          primitive

let scalarIsJson =
      \(value : Model.Value) ->
        merge
          { Primitive = primitiveIsJson, Custom = \(_ : Model.Name) -> False }
          value.scalar

let scalarIsJsonb =
      \(value : Model.Value) ->
        merge
          { Primitive = primitiveIsJsonb, Custom = \(_ : Model.Name) -> False }
          value.scalar

let valueIsArray =
      \(value : Model.Value) ->
        Deps.Prelude.Optional.fold
          Model.ArraySettings
          value.arraySettings
          Bool
          (\(_ : Model.ArraySettings) -> True)
          False

-- A bare (non-array) jsonb scalar binds via psycopg Jsonb(); a bare json scalar
-- binds via Json(). json preserves the document verbatim, jsonb normalizes it, so
-- the two must not be collapsed.
let isJsonbScalar =
      \(value : Model.Value) ->
        Deps.Prelude.Bool.and
          [ scalarIsJsonb value, Deps.Prelude.Bool.not (valueIsArray value) ]

let isJsonScalar =
      \(value : Model.Value) ->
        Deps.Prelude.Bool.and
          [ scalarIsJson value
          , Deps.Prelude.Bool.not (scalarIsJsonb value)
          , Deps.Prelude.Bool.not (valueIsArray value)
          ]

-- A json/jsonb ARRAY param has no faithful psycopg bind (Jsonb wraps a scalar,
-- not element-wise), so the generator rejects it instead of emitting an
-- unwrapped list that adapts wrong at runtime. The text[]::jsonb[] cast pattern
-- in SQL is the supported route (the param then types as text[], not json[]).
let isJsonArray =
      \(value : Model.Value) ->
        Deps.Prelude.Bool.and [ scalarIsJson value, valueIsArray value ]

let run =
      \(config : Algebra.Config) ->
      \(lookup : CustomKind.Lookup) ->
      \(input : Input) ->
        let fieldName = pySafeName input.name.inSnakeCase

        let needsJsonbImport = isJsonbScalar input.value

        let needsJsonImport = isJsonScalar input.value

        let isJsonArrayParam = isJsonArray input.value

        let wrapJson =
              \(ctor : Text) ->
                if    input.isNullable
                then  "None if ${fieldName} is None else ${ctor}(${fieldName})"
                else  "${ctor}(${fieldName})"

        let defaultBind =
              if    needsJsonbImport
              then  wrapJson "Jsonb"
              else  if needsJsonImport then wrapJson "Json" else fieldName

        -- psycopg binds a bare tuple to an anonymous composite, but cannot adapt
        -- a dataclass, so a composite param is converted to its field tuple.
        let compositeBind =
              \(fields : List CustomKind.CompositeField) ->
                let joinedFields =
                      Deps.Prelude.Text.concatMapSep
                        ", "
                        CustomKind.CompositeField
                        ( \(f : CustomKind.CompositeField) ->
                            "${fieldName}.${f.fieldName}"
                        )
                        fields

                -- concatMapSep never emits a separator for a single-element list, so
                -- a one-field composite would render "(x.f)": parens around a bare
                -- expression, not a tuple. Python only treats trailing-comma parens
                -- as a 1-tuple, so force it for exactly one field; concatMapSep
                -- already inserts the internal comma for two or more.
                let trailingComma =
                      if    Deps.Prelude.Natural.equal
                              ( Deps.Prelude.List.length
                                  CustomKind.CompositeField
                                  fields
                              )
                              1
                      then  ","
                      else  ""

                let tupleExpr = "(" ++ joinedFields ++ trailingComma ++ ")"

                in  if    input.isNullable
                    then  "None if ${fieldName} is None else ${tupleExpr}"
                    else  tupleExpr

        let buildOutput =
              \(value : Value.Output) ->
                let pyType =
                      value.pyType ++ (if input.isNullable then " | None" else "")

                let jsonImport =
                      if    needsJsonbImport
                      then  ImportSet.jsonb
                      else  if needsJsonImport then ImportSet.json else ImportSet.empty

                let mkOutput =
                      \(typeImports : ImportSet.Type) ->
                      \(bindExpr : Text) ->
                        { fieldName
                        , pgName = input.pgName
                        , pyType
                        , imports = ImportSet.combine typeImports jsonImport
                        , bindExpr
                        , needsJsonbImport
                        }

                in  Deps.Prelude.Optional.fold
                      Model.Name
                      value.scalar.customRef
                      (Lude.Compiled.Type Output)
                      ( \(name : Model.Name) ->
                          let customImport =
                                \(order : Natural) ->
                                  { className = name.inPascalCase
                                  , moduleName = name.inSnakeCase
                                  , order
                                  }

                          in  merge
                                { Enum =
                                    \(order : Natural) ->
                                      Lude.Compiled.ok
                                        Output
                                        ( mkOutput
                                            ( ImportSet.combine
                                                value.imports
                                                ( ImportSet.customEnum
                                                    (customImport order)
                                                )
                                            )
                                            defaultBind
                                        )
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
                                                  ( ImportSet.combine
                                                      value.imports
                                                      ( ImportSet.customComposite
                                                          (customImport composite.order)
                                                      )
                                                  )
                                                  (compositeBind composite.fields)
                                              )
                                      else  Lude.Compiled.report
                                              Output
                                              [ input.pgName, name.inSnakeCase ]
                                              "Array of a composite type as a parameter is not supported"
                                , Absent =
                                    Lude.Compiled.report
                                      Output
                                      [ name.inSnakeCase ]
                                      "Custom type not found in project customTypes"
                                }
                                (lookup name)
                      )
                      ( if    isJsonArrayParam
                        then  Lude.Compiled.report
                                Output
                                [ input.pgName ]
                                "json/jsonb array as a parameter is not supported"
                        else  Lude.Compiled.ok
                                Output
                                (mkOutput value.imports defaultBind)
                      )

        let compiledValue
            : Lude.Compiled.Type Value.Output
            = Lude.Compiled.nest
                Value.Output
                input.pgName
                (Value.run config input.value)

        in  Lude.Compiled.flatMap Value.Output Output buildOutput compiledValue

let Run = Algebra.Config -> CustomKind.Lookup -> Input -> Lude.Compiled.Type Output

in  { Input, Output, Run, run }
