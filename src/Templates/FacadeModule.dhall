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

let importBlock =
      \(source : Text) ->
      \(entry : Text) ->
            "from ${source} import (\n"
        ++  "    ${entry},\n"
        ++  ")"

let importBlocks =
      \(source : Text) ->
      \(entries : List Text) ->
        Prelude.Text.concatMapSep
          "\n"
          Text
          (\(entry : Text) -> importBlock source entry)
          entries

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
              importBlocks
                "${params.generatedPrefix}._core"
                (Prelude.List.map Text Text alias runtimeNames)

        let typeBlock =
              Prelude.Text.concatMapSep
                "\n"
                TypeExport
                ( \(t : TypeExport) ->
                    importBlock
                      "${params.generatedPrefix}.types.${t.moduleName}"
                      (alias t.className)
                )
                params.types

        let rows = rowNames params.statements

        -- A query's Row class lives in its statement module. Keep the row
        -- alias before the function alias, matching the canonical import order.
        let statementBlock =
              Prelude.Text.concatMapSep
                "\n"
                StatementExport
                ( \(s : StatementExport) ->
                    let rowEntries =
                          merge
                            { None = [] : List Text
                            , Some = \(row : Text) -> [ alias row ]
                            }
                            s.rowClassName

                    let functionEntry =
                              s.functionName
                          ++  params.functionSuffix
                          ++  " as "
                          ++  s.functionName

                    in  importBlocks
                          "${params.generatedPrefix}.statements.${s.functionName}"
                          (rowEntries # [ functionEntry ])
                )
                params.statements

        let registrationBlock =
              merge
                { None = [] : List Text
                , Some =
                    \(source : Text) ->
                      [ importBlock
                          "${params.generatedPrefix}._register"
                          "${source} as register_types"
                      ]
                }
                params.registrationSource

        let syncBlock =
              if    params.includeSyncModule
              then  [ importBlock "." "sync as sync" ]
              else  [] : List Text

        let importGroups =
                  syncBlock
                # [ runtimeBlock ]
                # registrationBlock
                # ( if    Prelude.List.null StatementExport params.statements
                    then  [] : List Text
                    else  [ statementBlock ]
                  )
                # ( if    Prelude.List.null TypeExport params.types
                    then  [] : List Text
                    else  [ typeBlock ]
                  )

        let importSection = Prelude.Text.concatSep "\n" importGroups

        let renderAllBlock =
              \(operator : Text) ->
              \(names : List Text) ->
                    "__all__ ${operator} [\n"
                ++  Prelude.Text.concatMap
                      Text
                      (\(name : Text) -> "    \"${name}\",\n")
                      names
                ++  "]"

        let typeNames =
              Prelude.List.map
                TypeExport
                Text
                (\(t : TypeExport) -> t.className)
                params.types

        let functionNames =
              Prelude.List.map
                StatementExport
                Text
                (\(s : StatementExport) -> s.functionName)
                params.statements

        let registrationNames =
              merge
                { None = [] : List Text
                , Some = \(_ : Text) -> [ "register_types" ]
                }
                params.registrationSource

        let syncNames =
              if params.includeSyncModule then [ "sync" ] else [] : List Text

        let extraAllGroups =
              Prelude.List.filter
                (List Text)
                (\(group : List Text) -> Prelude.Bool.not (Prelude.List.null Text group))
                [ typeNames, rows, functionNames, registrationNames, syncNames ]

        let allBlocks =
                  [ renderAllBlock "=" runtimeNames ]
                # Prelude.List.map
                    (List Text)
                    Text
                    (renderAllBlock "+=")
                    extraAllGroups

        in  ''
            ${importSection}

            ${Prelude.Text.concatSep "\n" allBlocks}
            ''

in  Sdk.Sigs.template Params run /\ { StatementExport, TypeExport }
