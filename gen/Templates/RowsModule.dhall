let Prelude = ../Deps/Prelude.dhall

let Lude = ../Deps/Lude.dhall

let Sdk = ../Deps/Sdk.dhall

let ImportSet = ../Structures/ImportSet.dhall

-- The shared row module: every query's frozen Row dataclass and its decode
-- function live here once, so the async and sync statement modules import the
-- same types (cross-surface identity) and decode logic. decodeName is unique per
-- query (decode_<fn>) since they now co-habit one module.
let RowDef =
      { className : Text
      , fieldsBlock : Text
      , decodeBlock : Text
      , decodeName : Text
      }

let Params = { rows : List RowDef, imports : ImportSet.Type }

let indentAll
    : Natural -> Text -> Text
    = \(n : Natural) ->
      \(text : Text) ->
        let pad = Prelude.Text.replicate n " "

        in  pad ++ Lude.Text.indentNonEmpty n text

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

-- Custom-type imports resolve from `_rows.py` (one level above `types/`), so the
-- prefix is `.types`, unlike a statement module's `..types`.
let customImportLines
    : ImportSet.Type -> List Text
    = \(imports : ImportSet.Type) ->
        Prelude.List.map
          ImportSet.CustomImport
          Text
          ( \(c : ImportSet.CustomImport) ->
              "from .types." ++ c.moduleName ++ " import " ++ c.className
          )
          (ImportSet.sortedCustoms imports)

let renderImports
    : ImportSet.Type -> Text
    = \(imports : ImportSet.Type) ->
        let stdlibBlock =
                  [ "from collections.abc import Mapping"
                  , "from dataclasses import dataclass"
                  ]
                # datetimeImport imports
                # importLineIf imports.decimal "from decimal import Decimal"
                # [ "from typing import cast" ]
                # importLineIf imports.uuid "from uuid import UUID"

        let localBlock =
                  importLineIf imports.jsonValue "from ._core import JsonValue"
                # importLineIf imports.enumArray "from ._core import require_array"
                # customImportLines imports

        let groups =
              [ [ "from __future__ import annotations" ], stdlibBlock, localBlock ]

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
        ++  row.decodeName
        ++  "(row: Mapping[str, object]) -> "
        ++  row.className
        ++  ":\n"
        ++  "    return "
        ++  row.className
        ++  "(\n"
        ++  indentAll 8 row.decodeBlock
        ++  "\n    )"

let run =
      \(params : Params) ->
            renderImports params.imports
        ++  "\n\n\n"
        ++  Prelude.Text.concatMapSep "\n\n\n" RowDef renderRow params.rows
        ++  "\n"

in  Sdk.Sigs.template Params run /\ { RowDef }
