let Prelude = ../Deps/Prelude.dhall

let Lude = ../Deps/Lude.dhall

let Sdk = ../Deps/Sdk.dhall

let ImportSet = ../Structures/ImportSet.dhall

let Surface = ../Structures/Surface.dhall

let RowDef = { className : Text, fieldsBlock : Text }

let indentAll
    : Natural -> Text -> Text
    = \(n : Natural) ->
      \(text : Text) ->
        let pad = Prelude.Text.replicate n " "

        in  pad ++ Lude.Text.indentNonEmpty n text

let renderRow
    : RowDef -> Text
    = \(row : RowDef) ->
            "@dataclass(frozen=True, slots=True)\n"
        ++  "class "
        ++  row.className
        ++  ":\n"
        ++  indentAll 4 row.fieldsBlock

let renderRowBlock
    : Optional RowDef -> Text
    = \(rowDef : Optional RowDef) ->
        merge
          { None = ""
          , Some = \(row : RowDef) -> "\n\n\n" ++ renderRow row
          }
          rowDef

let hasRow
    : Optional RowDef -> Bool
    = \(rowDef : Optional RowDef) ->
        merge { None = False, Some = \(_ : RowDef) -> True } rowDef

let Params =
      { functionName : Text
      , returnType : Text
      , helperName : Text
      , sqlLiteral : Text
      , rowDef : Optional RowDef
      , paramSigLines : List Text
      , paramDictEntries : List Text
      , imports : ImportSet.Type
      , emitSync : Bool
      , asyncSurface : Surface.Type
      , syncSurface : Surface.Type
      }

let importLineIf
    : Bool -> Text -> List Text
    = \(cond : Bool) -> \(line : Text) -> if cond then [ line ] else [] : List Text

let datetimeImport
    : ImportSet.Type -> List Text
    = \(imports : ImportSet.Type) ->
        let names =
                  importLineIf imports.date "date"
                # importLineIf imports.datetime "datetime"
                # importLineIf imports.time "time"
                # importLineIf imports.timedelta "timedelta"

        in  if    Prelude.Bool.not (Prelude.List.null Text names)
            then  [ "from datetime import " ++ Prelude.Text.concatSep ", " names ]
            else  [] : List Text

let runtimeImport
    : Surface.Type -> Text -> Text
    = \(surface : Surface.Type) ->
      \(helperName : Text) ->
        "from ${surface.runtimePrefix} import ${helperName} as _${helperName}${surface.helperSuffix}"

let coreImport
    : Text -> Bool -> List Text
    = \(corePrefix : Text) ->
      \(jsonValue : Bool) ->
        if    jsonValue
        then  [ "from ${corePrefix} import JsonValue" ]
        else  [] : List Text

let renderImports
    : Params -> Text
    = \(params : Params) ->
        let imports = params.imports

        let rowIsPresent = hasRow params.rowDef

        let asyncSurface = params.asyncSurface

        let syncSurface = params.syncSurface

        let stdlibBlock =
                  importLineIf rowIsPresent "from dataclasses import dataclass"
                # datetimeImport imports
                # importLineIf imports.decimal "from decimal import Decimal"
                # importLineIf imports.uuid "from uuid import UUID"

        let connectionNames =
                  [ asyncSurface.connType ]
                # (if params.emitSync then [ syncSurface.connType ] else [] : List Text)

        let psycopgBlock =
                  [ "from psycopg import " ++ Prelude.Text.concatSep ", " connectionNames ]
                # importLineIf
                    rowIsPresent
                    "from psycopg.rows import args_row as _args_row"
                # importLineIf
                    imports.json
                    "from psycopg.types.json import Json"
                # importLineIf
                    imports.jsonb
                    "from psycopg.types.json import Jsonb"

        let localBlock =
                  coreImport asyncSurface.corePrefix imports.jsonValue
                # [ runtimeImport asyncSurface params.helperName ]
                # ( if    params.emitSync
                    then  [ runtimeImport syncSurface params.helperName ]
                    else  [] : List Text
                  )
                # importLineIf
                    (ImportSet.hasCustom imports)
                    "from .. import types as _db_types"

        let groups =
              [ [ "from __future__ import annotations" ]
              , stdlibBlock
              , psycopgBlock
              , localBlock
              ]

        let nonEmptyGroups =
              Prelude.List.filter
                (List Text)
                ( \(group : List Text) ->
                    Prelude.Bool.not (Prelude.List.null Text group)
                )
                groups

        in  Prelude.Text.concatMapSep
              "\n\n"
              (List Text)
              (\(group : List Text) -> Prelude.Text.concatSep "\n" group)
              nonEmptyGroups

let renderSignature
    : Params -> Surface.Type -> Text
    = \(params : Params) ->
      \(surface : Surface.Type) ->
        let hasParams =
              Prelude.Bool.not (Prelude.List.null Text params.paramSigLines)

        let kwMarker = if hasParams then "    *,\n" else ""

        let paramBlock =
              Prelude.Text.concatMap
                Text
                (\(line : Text) -> "    " ++ line ++ ",\n")
                params.paramSigLines

        in      surface.defKeyword
            ++  " "
            ++  params.functionName
            ++  surface.functionSuffix
            ++  "(\n"
            ++  "    conn: ${surface.connType}[object],\n"
            ++  kwMarker
            ++  paramBlock
            ++  ") -> "
            ++  params.returnType
            ++  ":"

let renderParamsDict
    : Params -> Text
    = \(params : Params) ->
        if    Prelude.List.null Text params.paramDictEntries
        then  "params: dict[str, object] = {}"
        else      "params: dict[str, object] = {\n"
              ++  Prelude.Text.concatMap
                    Text
                    (\(entry : Text) -> "    " ++ entry ++ ",\n")
                    params.paramDictEntries
              ++  "}"

let renderCall
    : Params -> Surface.Type -> Text
    = \(params : Params) ->
      \(surface : Surface.Type) ->
        let helper = "_" ++ params.helperName ++ surface.helperSuffix

        let rowFactory =
              merge
                { None = ""
                , Some = \(row : RowDef) -> ", _args_row(${row.className})"
                }
                params.rowDef

        in  "return ${surface.awaitKw}${helper}(conn, SQL, params${rowFactory})"

let renderFunction
    : Params -> Surface.Type -> Text
    = \(params : Params) ->
      \(surface : Surface.Type) ->
            renderSignature params surface
        ++  "\n"
        ++  indentAll 4 (renderParamsDict params)
        ++  "\n"
        ++  indentAll 4 (renderCall params surface)

in  Sdk.Sigs.template
      Params
      ( \(params : Params) ->
              renderImports params
          ++  "\n\nSQL = \"\"\"\\\n"
          ++  params.sqlLiteral
          ++  "\n\"\"\""
          ++  renderRowBlock params.rowDef
          ++  "\n\n\n"
          ++  renderFunction params params.asyncSurface
          ++  ( if    params.emitSync
                then  "\n\n\n" ++ renderFunction params params.syncSurface
                else  ""
              )
          ++  "\n"
      )
    /\ { RowDef }
