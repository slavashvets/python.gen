let Prelude = ../Deps/Prelude.dhall

let Sdk = ../Deps/Sdk.dhall

-- A statement's public surface: the function and, when the query returns rows,
-- its frozen Row dataclass. functionName doubles as the leaf module name.
let StatementExport =
      { functionName : Text, rowClassName : Optional Text }

-- A custom type re-exported from types/: the leaf module name plus the class.
let TypeExport = { moduleName : Text, className : Text }

let Params =
      { statements : List StatementExport
      , types : List TypeExport
      , generatedPrefix : Text
      , functionSuffix : Text
      , registrationSource : Optional Text
      , includeSyncModule : Bool
      }

-- "x as x" re-export markers (PEP 484) so basedpyright strict and ruff treat the
-- names as exports of the package root, not unused imports.
let alias = \(name : Text) -> "${name} as ${name}"

let rowNames
    : List StatementExport -> List Text
    = \(statements : List StatementExport) ->
        Prelude.List.concatMap
          StatementExport
          Text
          ( \(s : StatementExport) ->
              merge
                { None = [] : List Text, Some = \(row : Text) -> [ row ] }
                s.rowClassName
          )
          statements

-- The core names that are part of the public surface: the JsonValue alias used
-- by callers typing jsonb columns, and the NoRowError raised by single-row
-- statements. _core.py is always emitted, so these are always re-exported.
let runtimeNames = [ "JsonValue", "NoRowError" ]

let run =
      \(params : Params) ->
        let runtimeBlock =
              "from ${params.generatedPrefix}._core import "
              ++  Prelude.Text.concatMapSep
                    ", "
                    Text
                    alias
                    runtimeNames

        let typeBlock =
              Prelude.Text.concatMapSep
                "\n"
                TypeExport
                ( \(t : TypeExport) ->
                    "from ${params.generatedPrefix}.types.${t.moduleName} import ${alias t.className}"
                )
                params.types

        let rows = rowNames params.statements

        -- A query's Row class now lives in that query's own statement
        -- module (there is no shared _rows module anymore), so the row
        -- alias, when present, rides on the same import line as the
        -- statement function itself: "from ...statements.fn import fn as
        -- fn, RowCls as RowCls" -- one line per statement, not two separate
        -- import blocks.
        let statementBlock =
              Prelude.Text.concatMapSep
                "\n"
                StatementExport
                ( \(s : StatementExport) ->
                    let rowSuffix =
                          merge
                            { None = "", Some = \(row : Text) -> ", ${alias row}" }
                            s.rowClassName

                    in      "from ${params.generatedPrefix}.statements.${s.functionName} import "
                        ++  s.functionName
                        ++  params.functionSuffix
                        ++  " as "
                        ++  s.functionName
                        ++  rowSuffix
                )
                params.statements

        let registrationBlock =
              merge
                { None = [] : List Text
                , Some =
                    \(source : Text) ->
                      [ "from ${params.generatedPrefix}._register import ${source} as register_types"
                      ]
                }
                params.registrationSource

        let syncBlock =
              if params.includeSyncModule then [ "from . import sync as sync" ] else [] : List Text

        let importGroups =
                  [ runtimeBlock ]
                # ( if    Prelude.List.null TypeExport params.types
                    then  [] : List Text
                    else  [ typeBlock ]
                  )
                # ( if    Prelude.List.null StatementExport params.statements
                    then  [] : List Text
                    else  [ statementBlock ]
                  )
                # registrationBlock
                # syncBlock

        let importSection = Prelude.Text.concatSep "\n\n" importGroups

        let allNames =
                  runtimeNames
                # Prelude.List.map
                    TypeExport
                    Text
                    (\(t : TypeExport) -> t.className)
                    params.types
                # rows
                # Prelude.List.map
                    StatementExport
                    Text
                    (\(s : StatementExport) -> s.functionName)
                    params.statements
                # ( merge
                      { None = [] : List Text
                      , Some = \(_ : Text) -> [ "register_types" ]
                      }
                      params.registrationSource
                  )
                # (if params.includeSyncModule then [ "sync" ] else [] : List Text)

        let allEntries =
              Prelude.Text.concatMap
                Text
                (\(name : Text) -> "    \"${name}\",\n")
                allNames

        in  ''
            ${importSection}

            __all__ = [
            ${allEntries}]
            ''

in  Sdk.Sigs.template Params run /\ { StatementExport, TypeExport }
