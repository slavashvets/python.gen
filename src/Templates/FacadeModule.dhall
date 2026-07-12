let Prelude = ../Deps/Prelude.dhall

let Sdk = ../Deps/Sdk.dhall

-- A statement's public surface: the function and, when the query returns rows,
-- its frozen Row dataclass. functionName doubles as the leaf module name.
let StatementExport =
      { functionName : Text, rowClassName : Optional Text }

-- A custom type re-exported from types/: the leaf module name plus the class.
let TypeExport = { moduleName : Text, className : Text }

-- The facade always lives at the package root, importing from `_generated`
-- (prefix `._generated`) and `_generated/statements` (statementsPath
-- `statements`) — both constant now that exactly one surface is emitted per
-- generate (Interpreters/Project.dhall picks it via config.sync).
let generatedPrefix = "._generated"
let statementsPath = "statements"

let Params =
      { statements : List StatementExport
      , types : List TypeExport
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
              "from ${generatedPrefix}._core import "
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
                    "from ${generatedPrefix}.types.${t.moduleName} import ${alias t.className}"
                )
                params.types

        let rows = rowNames params.statements

        let rowBlock =
                  "from ${generatedPrefix}._rows import (\n"
              ++  Prelude.Text.concatMap
                    Text
                    (\(name : Text) -> "    ${alias name},\n")
                    rows
              ++  ")"

        let statementBlock =
              Prelude.Text.concatMapSep
                "\n"
                StatementExport
                ( \(s : StatementExport) ->
                    "from ${generatedPrefix}.${statementsPath}.${s.functionName} import ${alias s.functionName}"
                )
                params.statements

        let importGroups =
                  [ runtimeBlock ]
                # ( if    Prelude.List.null TypeExport params.types
                    then  [] : List Text
                    else  [ typeBlock ]
                  )
                # (if Prelude.List.null Text rows then [] : List Text else [ rowBlock ])
                # ( if    Prelude.List.null StatementExport params.statements
                    then  [] : List Text
                    else  [ statementBlock ]
                  )

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
