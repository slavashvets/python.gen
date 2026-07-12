let Prelude = ../Deps/Prelude.dhall

let Sdk = ../Deps/Sdk.dhall

-- Per-connection type registration, emitted once. psycopg decodes an
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
      , emitSync : Bool
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
        let hasComposites =
              Prelude.Bool.not (Prelude.List.null Text params.compositeNames)

        let hasEnums = Prelude.Bool.not (Prelude.List.null Text params.enumNames)

        let importLines =
                [ "from __future__ import annotations"
                , ""
                , if    params.emitSync
                  then  "from psycopg import AsyncConnection, Connection"
                  else  "from psycopg import AsyncConnection"
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

        let asyncBodyLines =
                ( if    hasComposites
                  then  compositeLoop "await "
                  else  [] : List Text
                )
              # (if hasEnums then enumLoop "await " else [] : List Text)

        let syncBodyLines =
                ( if    hasComposites
                  then  compositeLoop ""
                  else  [] : List Text
                )
              # (if hasEnums then enumLoop "" else [] : List Text)

        let syncFunction =
              if    params.emitSync
              then    [ "", "" ]
                    # [ "def register_types_sync(conn: Connection[object]) -> None:"
                      ]
                    # syncBodyLines
              else  [] : List Text

        let allLines =
                importLines
              # [ "", "" ]
              # constantLines
              # [ "", "" ]
              # [ "async def register_types(conn: AsyncConnection[object]) -> None:"
                ]
              # asyncBodyLines
              # syncFunction

        in  Prelude.Text.concatSep "\n" allLines ++ "\n"

in  Sdk.Sigs.template Params run
