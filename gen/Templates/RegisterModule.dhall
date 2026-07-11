let Prelude = ../Deps/Prelude.dhall

let Sdk = ../Deps/Sdk.dhall

let Surface = ../Structures/Surface.dhall

-- Per-connection type registration, emitted once per surface. psycopg decodes an
-- unregistered composite as a text string; registering its CompositeInfo makes
-- it decode to a namedtuple, which the generated decode then splats into the
-- frozen dataclass. An enum scalar already decodes as text, but an enum ARRAY
-- does not parse without the type registered, so each enum's TypeInfo is
-- registered too (elements stay text and the generated decode rebuilds the
-- StrEnum). Call once per connection before using the statements. Emitted only
-- when the project has composites or enums.
let Params =
      { compositeNames : List Text
      , enumNames : List Text
      , surface : Surface.Type
      }

let tupleLiteral =
      \(names : List Text) ->
            "("
        ++  Prelude.Text.concatMapSep ", " Text (\(n : Text) -> "\"${n}\"") names
        ++  ",)"

let compositeLoop =
      \(awaitKw : Text) ->
        [ "    for name in _COMPOSITE_TYPES:"
        , "        composite_info = ${awaitKw}CompositeInfo.fetch(conn, name)"
        , "        if composite_info is None:"
        , "            raise LookupError(f\"composite type {name!r} not found; cannot register it\")"
        , "        register_composite(composite_info, conn)"
        ]

let enumLoop =
      \(awaitKw : Text) ->
        [ "    for name in _ENUM_TYPES:"
        , "        enum_info = ${awaitKw}TypeInfo.fetch(conn, name)"
        , "        if enum_info is None:"
        , "            raise LookupError(f\"enum type {name!r} not found; cannot register it\")"
        , "        enum_info.register(conn)"
        ]

let run =
      \(params : Params) ->
        let surface = params.surface

        let hasComposites =
              Prelude.Bool.not (Prelude.List.null Text params.compositeNames)

        let hasEnums = Prelude.Bool.not (Prelude.List.null Text params.enumNames)

        let importLines =
                [ "from __future__ import annotations"
                , ""
                , "from psycopg import ${surface.connType}"
                ]
              # ( if    hasEnums
                  then  [ "from psycopg.types import TypeInfo" ]
                  else  [] : List Text
                )
              # ( if    hasComposites
                  then  [ "from psycopg.types.composite import CompositeInfo, register_composite"
                        ]
                  else  [] : List Text
                )

        let constantLines =
                ( if    hasComposites
                  then  [ "_COMPOSITE_TYPES = ${tupleLiteral params.compositeNames}" ]
                  else  [] : List Text
                )
              # ( if    hasEnums
                  then  [ "_ENUM_TYPES = ${tupleLiteral params.enumNames}" ]
                  else  [] : List Text
                )

        let bodyLines =
                ( if    hasComposites
                  then  compositeLoop surface.awaitKw
                  else  [] : List Text
                )
              # (if hasEnums then enumLoop surface.awaitKw else [] : List Text)

        let allLines =
                importLines
              # [ "", "" ]
              # constantLines
              # [ "", "" ]
              # [ "${surface.defKeyword} register_types(conn: ${surface.connType}[object]) -> None:"
                ]
              # bodyLines

        in  Prelude.Text.concatSep "\n" allLines ++ "\n"

in  Sdk.Sigs.template Params run
