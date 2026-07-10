let Deps = ../Deps/package.dhall

let ImportSet = ../Structures/ImportSet.dhall

let Algebra = ../Algebras/Interpreter.dhall

let Model = Deps.Sdk.Project

let Input = Model.Primitive

let Output = { pyType : Text, imports : ImportSet.Type }

let supported =
      \(pyType : Text) ->
      \(imports : ImportSet.Type) ->
        Deps.Lude.Compiled.ok Output { pyType, imports }

let unsupported =
      \(pgType : Text) ->
        Deps.Lude.Compiled.report Output [ pgType ] "Unsupported type"

let plain = \(pyType : Text) -> supported pyType ImportSet.empty

let run =
      \(config : Algebra.Config) ->
      \(input : Input) ->
        merge
          { Bit = unsupported "bit"
          , Bool = plain "bool"
          , Box = unsupported "box"
          , Box2D = unsupported "box2d"
          , Box3D = unsupported "box3d"
          , Bpchar = plain "str"
          , Bytea = plain "bytes"
          , Char = plain "str"
          , Cidr = unsupported "cidr"
          , Circle = unsupported "circle"
          , Citext = plain "str"
          , Date = supported "date" ImportSet.date
          , Datemultirange = unsupported "datemultirange"
          , Daterange = unsupported "daterange"
          , Float4 = plain "float"
          , Float8 = plain "float"
          , Geography = unsupported "geography"
          , Geometry = unsupported "geometry"
          , Hstore = unsupported "hstore"
          , Inet = unsupported "inet"
          , Int2 = plain "int"
          , Int4 = plain "int"
          , Int4multirange = unsupported "int4multirange"
          , Int4range = unsupported "int4range"
          , Int8 = plain "int"
          , Int8multirange = unsupported "int8multirange"
          , Int8range = unsupported "int8range"
          , Interval = supported "timedelta" ImportSet.timedelta
          , Json = supported "JsonValue" ImportSet.jsonValue
          , Jsonb = supported "JsonValue" ImportSet.jsonValue
          , Line = unsupported "line"
          , Lseg = unsupported "lseg"
          , Ltree = unsupported "ltree"
          , Macaddr = unsupported "macaddr"
          , Macaddr8 = unsupported "macaddr8"
          , Money = unsupported "money"
          , Name = plain "str"
          , Numeric = supported "Decimal" ImportSet.decimal
          , Nummultirange = unsupported "nummultirange"
          , Numrange = unsupported "numrange"
          , Oid = plain "int"
          , Path = unsupported "path"
          , PgLsn = unsupported "pg_lsn"
          , PgSnapshot = unsupported "pg_snapshot"
          , Point = unsupported "point"
          , Polygon = unsupported "polygon"
          , Text = plain "str"
          , Time = supported "time" ImportSet.time
          , Timestamp = supported "datetime" ImportSet.datetime
          , Timestamptz = supported "datetime" ImportSet.datetime
          , Timetz = unsupported "timetz"
          , Tsmultirange = unsupported "tsmultirange"
          , Tsquery = unsupported "tsquery"
          , Tsrange = unsupported "tsrange"
          , Tstzmultirange = unsupported "tstzmultirange"
          , Tstzrange = unsupported "tstzrange"
          , Tsvector = unsupported "tsvector"
          , Uuid = supported "UUID" ImportSet.uuid
          , Varbit = unsupported "varbit"
          , Varchar = plain "str"
          , Xml = unsupported "xml"
          }
          input

in  Algebra.module Input Output run
