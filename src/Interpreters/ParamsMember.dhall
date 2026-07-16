let Lude = ../Deps/Lude.dhall

let Prelude = ../Deps/Prelude.dhall

let Model = ../Deps/Contract.dhall

let ImportSet = ../Structures/ImportSet.dhall

let CustomKind = ../Structures/CustomKind.dhall

let Value = ./Value.dhall

let Config = {}

let Input = Model.Member

let PyIdent = ../Structures/PyIdent.dhall

let Output =
      { fieldName : Text
      , pgName : Text
      , pyType : Text
      , imports : ImportSet.Type
      , bindExpr : Text
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
          { Primitive = primitiveIsJson
          , Custom = \(_ : Model.CustomTypeRef) -> False
          }
          value.scalar

let scalarIsJsonb =
      \(value : Model.Value) ->
        merge
          { Primitive = primitiveIsJsonb
          , Custom = \(_ : Model.CustomTypeRef) -> False
          }
          value.scalar

let valueIsArray =
      \(value : Model.Value) -> Prelude.Bool.not (Natural/isZero value.dimensionality)

-- A bare (non-array) jsonb scalar binds via psycopg Jsonb(); a bare json scalar
-- binds via Json(). json preserves the document verbatim, jsonb normalizes it, so
-- the two must not be collapsed.
let isJsonbScalar =
      \(value : Model.Value) ->
        Prelude.Bool.and
          [ scalarIsJsonb value, Prelude.Bool.not (valueIsArray value) ]

let isJsonScalar =
      \(value : Model.Value) ->
        Prelude.Bool.and
          [ scalarIsJson value
          , Prelude.Bool.not (scalarIsJsonb value)
          , Prelude.Bool.not (valueIsArray value)
          ]

-- A json/jsonb ARRAY param has no faithful psycopg bind (Jsonb wraps a scalar,
-- not element-wise), so the generator rejects it instead of emitting an
-- unwrapped list that adapts wrong at runtime. The text[]::jsonb[] cast pattern
-- in SQL is the supported route (the param then types as text[], not json[]).
let isJsonArray =
      \(value : Model.Value) ->
        Prelude.Bool.and [ scalarIsJson value, valueIsArray value ]

let run =
      \(_ : Config) ->
      \(lookup : CustomKind.Lookup) ->
      \(input : Input) ->
        let fieldName = PyIdent.parameterSafeName input.name.inSnakeCase

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

        let buildOutput =
              \(value : Value.Output) ->
                let nullableSuffix =
                      if input.isNullable then " | None" else ""

                let jsonImport =
                      if    needsJsonbImport
                      then  ImportSet.jsonb
                      else  if needsJsonImport then ImportSet.json else ImportSet.empty

                let mkOutput =
                      \(typeImports : ImportSet.Type) ->
                      \(pyType : Text) ->
                      \(bindExpr : Text) ->
                        { fieldName
                        , pgName = input.pgName
                        , pyType
                        , imports = ImportSet.combine typeImports jsonImport
                        , bindExpr
                        }

                in  Prelude.Optional.fold
                      Model.CustomTypeRef
                      value.scalar.customRef
                      (Lude.Compiled.Type Output)
                      ( \(ref : Model.CustomTypeRef) ->
                          let dimsAtMostTwo =
                                Natural/isZero (Natural/subtract 2 value.dims)

                          let dimsAtMostOne =
                                Natural/isZero (Natural/subtract 1 value.dims)

                          in  merge
                                { Enum =
                                    \(identity : CustomKind.Identity) ->
                                      let enumImport =
                                            ImportSet.customEnum
                                              identity

                                      in  if dimsAtMostTwo
                                          then  Lude.Compiled.ok
                                                  Output
                                                  ( mkOutput
                                                      ( ImportSet.combine
                                                          value.imports
                                                          enumImport
                                                      )
                                                      ( Value.qualifyCustom
                                                          "_db_types."
                                                          identity.className
                                                          value
                                                        ++ nullableSuffix
                                                      )
                                                      fieldName
                                                  )
                                          else  Lude.Compiled.report
                                                  Output
                                                  [ input.pgName
                                                  , ref.name.inSnakeCase
                                                  ]
                                                  "Array of an enum parameter with dimensionality > 2 is not supported"
                                , Composite =
                                    \(identity : CustomKind.Identity) ->
                                      if dimsAtMostOne
                                      then  Lude.Compiled.ok
                                              Output
                                              ( mkOutput
                                                  ( ImportSet.combine
                                                      value.imports
                                                      ( ImportSet.customComposite
                                                          identity
                                                      )
                                                  )
                                                  ( Value.qualifyCustom
                                                      "_db_types."
                                                      identity.className
                                                      value
                                                    ++ nullableSuffix
                                                  )
                                                  fieldName
                                              )
                                      else  Lude.Compiled.report
                                              Output
                                              [ input.pgName, ref.name.inSnakeCase ]
                                              "Array of a composite type parameter with dimensionality > 1 is not supported"
                                , Absent =
                                    Lude.Compiled.report
                                      Output
                                      [ ref.name.inSnakeCase ]
                                      "Custom type not found in project customTypes"
                                }
                                (CustomKind.at lookup ref.index)
                      )
                      ( if    isJsonArrayParam
                        then  Lude.Compiled.report
                                Output
                                [ input.pgName ]
                                "json/jsonb array as a parameter is not supported"
                        else  Lude.Compiled.ok
                                Output
                                ( mkOutput
                                    value.imports
                                    (value.pyType ++ nullableSuffix)
                                    defaultBind
                                )
                      )

        let compiledValue
            : Lude.Compiled.Type Value.Output
            = Lude.Compiled.nest
                Value.Output
                input.pgName
                (Value.run {=} input.value)

        in  Lude.Compiled.flatMap Value.Output Output buildOutput compiledValue

in  { Input, Output, run }
