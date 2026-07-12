let Prelude = ../Deps/Prelude.dhall

let Lude = ../Deps/Lude.dhall

let Sdk = ../Deps/Sdk.dhall

let ImportSet = ../Structures/ImportSet.dhall

let Surface = ../Structures/Surface.dhall

-- A query's frozen Row dataclass plus its module-level decode function,
-- rendered directly into that query's own statement module (there is a
-- strict 1:1 relationship between a query and its Row -- no cross-statement
-- sharing -- so co-locating them costs nothing and removes the need for a
-- shared _rows.py import).
let RowDef =
      { className : Text
      , fieldsBlock : Text
      , decodeBlock : Text
      }

-- Prefix every line (including the first) with `n` spaces, leaving blank lines
-- untouched so trailing whitespace never appears.
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
        ++  "\n\n\n"
        ++  "def "
        ++  "_decode_row"
        ++  "(row: Mapping[str, object]) -> "
        ++  row.className
        ++  ":\n"
        ++  "    return "
        ++  row.className
        ++  "(\n"
        ++  indentAll 8 row.decodeBlock
        ++  "\n    )"

-- "" when the query returns no rows (Void/RowsAffected); otherwise the
-- rendered class + decode function, framed with the same "\n\n\n" (two
-- blank lines) PEP8 spacing _rows.py used between consecutive row defs, on
-- both sides -- matching the two-blank-lines-before/after convention for a
-- top-level class or function.
let renderRowBlock
    : Optional RowDef -> Text
    = \(rowDef : Optional RowDef) ->
        merge
          { None = ""
          , Some = \(row : RowDef) -> "\n" ++ renderRow row ++ "\n\n\n"
          }
          rowDef

let hasRow
    : Optional RowDef -> Bool
    = \(rowDef : Optional RowDef) ->
        merge { None = False, Some = \(_ : RowDef) -> True } rowDef

-- A canonical statement module owns its Row, decoder, SQL, async function, and
-- optional adjacent sync function. `imports` carries both the parameter
-- type imports and the result-column imports merged into one set
-- (Interpreters/Query.dhall combines them), since both now live in this one
-- file.
let Params =
      { functionName : Text
      , returnType : Text
      , helperName : Text
      , callsDecode : Bool
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

-- "from datetime import ..." collapses the four datetime members into one line.
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

let customImportLines
    : Text -> ImportSet.Type -> List Text
    = \(typesPrefix : Text) ->
      \(imports : ImportSet.Type) ->
        Prelude.List.map
          ImportSet.CustomImport
          Text
          ( \(c : ImportSet.CustomImport) ->
              "from ${typesPrefix}.${c.moduleName} import ${c.className}"
          )
          (ImportSet.sortedCustoms imports)

let renderImports
    : Params -> Text
    = \(params : Params) ->
        let imports = params.imports

        let rowIsPresent = hasRow params.rowDef

        let asyncSurface = params.asyncSurface

        let syncSurface = params.syncSurface

        let stdlibBlock =
                  importLineIf rowIsPresent "from collections.abc import Mapping"
                # importLineIf rowIsPresent "from dataclasses import dataclass"
                # datetimeImport imports
                # importLineIf imports.decimal "from decimal import Decimal"
                # importLineIf imports.needsCast "from typing import cast as _cast"
                # importLineIf imports.uuid "from uuid import UUID"

        let connectionNames =
                  [ asyncSurface.connType ]
                # (if params.emitSync then [ syncSurface.connType ] else [] : List Text)

        let psycopgBlock =
                  [ "from psycopg import " ++ Prelude.Text.concatSep ", " connectionNames ]
                # importLineIf
                    imports.json
                    "from psycopg.types.json import Json"
                # importLineIf
                    imports.jsonb
                    "from psycopg.types.json import Jsonb"

        let localBlock =
                  coreImport asyncSurface.corePrefix imports.jsonValue
                # importLineIf
                    imports.enumArray
                    "from ${asyncSurface.corePrefix} import require_array as _require_array"
                # [ runtimeImport asyncSurface params.helperName ]
                # ( if    params.emitSync
                    then  [ runtimeImport syncSurface params.helperName ]
                    else  [] : List Text
                  )
                # customImportLines asyncSurface.typesPrefix imports

        let groups =
              [ [ "from __future__ import annotations" ]
              , stdlibBlock
              , psycopgBlock
              , localBlock
              ]

        let nonEmptyGroups =
              Prelude.List.filter
                (List Text)
                ( \(g : List Text) ->
                    Prelude.Bool.not (Prelude.List.null Text g)
                )
                groups

        in  Prelude.Text.concatMapSep
              "\n\n"
              (List Text)
              (\(g : List Text) -> Prelude.Text.concatSep "\n" g)
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

-- Emit the dict multi-line with a magic trailing comma so ruff keeps it
-- expanded at any width, which keeps the generated file format-stable.
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
        let await = surface.awaitKw

        let helper = "_" ++ params.helperName ++ surface.helperSuffix

        in  if    params.callsDecode
            then  "return ${await}${helper}(conn, _SQL, params, _decode_row)"
            else  "return ${await}${helper}(conn, _SQL, params)"

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
          ++  "\n\n"
          ++  renderRowBlock params.rowDef
          -- The leading backslash after the opening quotes keeps the first SQL
          -- line flush (no blank line); the newline before the closing quotes is
          -- the only deviation from the raw text, a harmless trailing newline for
          -- psycopg.
          ++  "SQL = \"\"\"\\\n"
          ++  params.sqlLiteral
          -- Encode once at import; the helpers take bytes so each call skips a
          -- per-query str->bytes allocation (psycopg auto-prepare keys on the
          -- bytes value, so equal bytes still hit the prepared-statement cache).
          ++  "\n\"\"\"\n\n_SQL = SQL.encode()\n\n\n"
          ++  renderFunction params params.asyncSurface
          ++  ( if    params.emitSync
                then  "\n\n\n" ++ renderFunction params params.syncSurface
                else  ""
              )
          ++  "\n"
      )
    /\ { RowDef }
