# Distribute Rows Per Statement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the shared `_rows.py` god-module. Each query's Row dataclass and `decode_<query>` function move verbatim into that query's own statement module (`statements/<query_snake>.py`), since there is already a strict 1:1 relationship between a query and its Row (no cross-statement sharing, no deduplication — confirmed empirically: 227 queries, 227 distinct Row classes, one dataclass and one decode function per query, always named after the query itself).

**Architecture:** `Templates/RowsModule.dhall` is deleted; its `RowDef` type and `renderRow` function move into `Templates/StatementModule.dhall`, the file's sole remaining consumer. `StatementModule.dhall`'s `Params` gains `rowDef : Optional RowDef` (replacing the old `rowClassName`-only field, which existed just to build an `import ... from _rows` line that no longer exists) and renders the Row class + decode function inline, directly above the `SQL = ...` constant. `Interpreters/Query.dhall` merges its param-side and result-side `ImportSet`s into one combined set per statement file (previously kept separate: param imports fed the statement module, result/row imports fed a project-wide accumulator for `_rows.py`). `Interpreters/Project.dhall` drops the `rowDefs`/`rowImports`/`rowsFiles` machinery entirely. `Templates/FacadeModule.dhall`'s per-statement import line grows an optional Row-class alias, so the facade imports a query's Row class from that query's own statement module instead of a shared `_rows` import block.

**Tech Stack:** Dhall (dhall-lang 1.42 vendored via `dhall` CLI; pgn's forked interpreter for the parts still using it), Python 3.12 generated output (psycopg3), basedpyright strict, pytest golden-file harness (`mise run test`, `mise run golden`), pgn 0.9.1 (mise-pinned).

## Global Constraints

- **Depends on `docs/plans/2026-07-12-configurable-sync-output.md` landing first.** This plan assumes exactly one statement tree per generate at unified paths (`statements/<fn>.py`, no `sync/` nesting) — it touches the same statement-module template that plan collapsed to a single surface. Do not start this plan until that one is merged and both `tests/golden/` and `tests/golden_sync/` are green.
- No change to decode LOGIC (the `cast(...)` expressions, enum/composite decode bodies, field ordering) — this plan only relocates already-correct rendering code from one file to another. `Interpreters/Member.dhall`, `Result.dhall`, `ResultColumns.dhall` are untouched.
- Row class and decode function names are unchanged (`SelectMood000Row`, `decode_select_mood_0_0_0`, etc.) — this is a pure code-motion plan, not a renaming plan (renaming to something shorter given the new file-local context, e.g. `Row`/`decode`, is an explicitly deferred, separate concern).
- Golden fixture output (`tests/golden/`, `tests/golden_sync/`) must be regenerated via `mise run golden`, not hand-edited.
- `mise run test` must pass after regeneration, for both golden trees.
- Every Dhall file touched must independently type-check via `dhall type --file=src/package.dhall`.
- This is a breaking change for any consumer importing `from <pkg>._generated._rows import X` directly. The README already tells consumers not to do that ("Import from the flat facade, not from `_generated` directly"), so this is "you were told" breakage, not a silent one — still worth a CHANGELOG line since `_rows.py` is a real, previously-stable module path someone could have depended on anyway.

---

## File Structure

| File | Change |
|---|---|
| `src/Templates/StatementModule.dhall` | Absorb `RowDef`/`renderRow` from `RowsModule.dhall`. `Params`: replace `rowClassName : Optional Text` with `rowDef : Optional RowDef`. Drop `rowsImportLine`. Add row-driven stdlib imports (`Mapping`, `dataclass`, `cast`) and a `require_array` import line, both gated on whether the query has a row. Splice the rendered row block between the import section and the `SQL = ...` constant. |
| `src/Templates/RowsModule.dhall` | Delete. |
| `src/Interpreters/Query.dhall` | Drop the `RowsModule` import; merge param and result `ImportSet`s into one; retarget the row's type to `StatementModule.RowDef`; drop `rowDef`/`rowImports` from `Output` (both become `render`-internal only). |
| `src/Interpreters/Project.dhall` | Drop the `RowsModule` import and the `rowDefs`/`rowImports`/`rowsFiles` bindings; drop `# rowsFiles` from `allFiles`. |
| `src/Templates/FacadeModule.dhall` | Drop the separate `_rows` import block (`rowBlock`); fold each statement's Row-class alias onto its own statement import line. |
| `tests/test_unsupported_types.py` | Drop the `_rows.py` orphan-reference check and the `_rows` import-smoke-test line (row content is now private to each statement file, already covered by the existing "skipped statement file doesn't exist" checks). |
| `tests/golden/`, `tests/golden_sync/` | Regenerate via `mise run golden`; `_rows.py` disappears from both, its content redistributed into each `statements/*.py` file. |
| `README.md` | "Using the generated code" no longer needs updating (already says "import from the flat facade," unaffected by where Rows physically live) — no change needed; confirmed in Task 3. |
| `DESIGN.md` | Section "## 2. Shared type layer: `_rows.py` and `types/`" rewritten (rows are no longer shared/centralized); "Generated package layout" tree (as left by the sync-output plan) drops the `_rows.py` line; "Generator decomposition" file tree drops the `RowsModule.dhall` line and updates `StatementModule.dhall`'s description; the byte-offset example referencing `tests/golden/.../_rows.py`'s `moods` column is repointed at the new location. |
| `CHANGELOG.md` | New "Upcoming" entry documenting the removal of `_rows.py`. |

---

### Task 1: Move `RowDef`/`renderRow` into `StatementModule.dhall` and render the row inline

**Files:**
- Modify: `src/Templates/StatementModule.dhall`
- Delete: `src/Templates/RowsModule.dhall`

**Interfaces:**
- Produces: `StatementModule.RowDef = { className : Text, fieldsBlock : Text, decodeBlock : Text, decodeName : Text }` (moved verbatim from `RowsModule.RowDef`) and `StatementModule.Params.rowDef : Optional RowDef` (replacing `rowClassName : Optional Text`). Task 2 (`Query.dhall`) is the consumer.

- [ ] **Step 1: Read `src/Templates/RowsModule.dhall`'s `RowDef` and `renderRow` one more time to confirm the exact text being moved**

Run: `cat src/Templates/RowsModule.dhall`
Expected (for reference — this exact text is being relocated, not rewritten):

```dhall
let RowDef =
      { className : Text
      , fieldsBlock : Text
      , decodeBlock : Text
      , decodeName : Text
      }
```

```dhall
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
```

- [ ] **Step 2: Rewrite `src/Templates/StatementModule.dhall` in full**

```dhall
let Prelude = ../Deps/Prelude.dhall

let Lude = ../Deps/Lude.dhall

let Sdk = ../Deps/Sdk.dhall

let ImportSet = ../Structures/ImportSet.dhall

let Surface = ../Structures/Surface.dhall

-- A query's frozen Row dataclass plus its module-level decode function,
-- rendered directly into that query's own statement module (there is a
-- strict 1:1 relationship between a query and its Row — no cross-statement
-- sharing — so co-locating them costs nothing and removes the need for a
-- shared _rows.py import).
let RowDef =
      { className : Text
      , fieldsBlock : Text
      , decodeBlock : Text
      , decodeName : Text
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
        ++  row.decodeName
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
-- both sides — matching the two-blank-lines-before/after convention for a
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

-- A statement module is the thin per-surface I/O wrapper: it renders its own
-- Row dataclass and decode function (when the query returns rows) and one
-- `async def`/`def` over a connection. `imports` carries BOTH the parameter
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
      , decodeName : Text
      , paramSigLines : List Text
      , paramDictEntries : List Text
      , imports : ImportSet.Type
      , surface : Surface.Type
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

-- The I/O helper (fetch_*/execute_*) always comes from _runtime; JsonValue and
-- require_array, when used, come from _core via the surface's corePrefix.
let runtimeImport
    : Text -> Text
    = \(helperName : Text) -> "from .._runtime import " ++ helperName

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
          imports.customTypes

let renderImports
    : Params -> Text
    = \(params : Params) ->
        let imports = params.imports

        let rowIsPresent = hasRow params.rowDef

        let stdlibBlock =
                  importLineIf rowIsPresent "from collections.abc import Mapping"
                # importLineIf rowIsPresent "from dataclasses import dataclass"
                # datetimeImport imports
                # importLineIf imports.decimal "from decimal import Decimal"
                # importLineIf rowIsPresent "from typing import cast"
                # importLineIf imports.uuid "from uuid import UUID"

        let psycopgBlock =
                  [ "from psycopg import ${params.surface.connType}" ]
                # importLineIf
                    imports.json
                    "from psycopg.types.json import Json"
                # importLineIf
                    imports.jsonb
                    "from psycopg.types.json import Jsonb"

        let localBlock =
                  coreImport params.surface.corePrefix imports.jsonValue
                # importLineIf
                    imports.enumArray
                    "from ${params.surface.corePrefix} import require_array"
                # [ runtimeImport params.helperName ]
                # customImportLines params.surface.typesPrefix imports

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
    : Params -> Text
    = \(params : Params) ->
        let hasParams =
              Prelude.Bool.not (Prelude.List.null Text params.paramSigLines)

        let kwMarker = if hasParams then "    *,\n" else ""

        let paramBlock =
              Prelude.Text.concatMap
                Text
                (\(line : Text) -> "    " ++ line ++ ",\n")
                params.paramSigLines

        in      params.surface.defKeyword
            ++  " "
            ++  params.functionName
            ++  "(\n"
            ++  "    conn: ${params.surface.connType}[object],\n"
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
    : Params -> Text
    = \(params : Params) ->
        let await = params.surface.awaitKw

        in  if    params.callsDecode
            then  "return ${await}${params.helperName}(conn, _SQL, params, ${params.decodeName})"
            else  "return ${await}${params.helperName}(conn, _SQL, params)"

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
          ++  renderSignature params
          ++  "\n"
          ++  indentAll 4 (renderParamsDict params)
          ++  "\n"
          ++  indentAll 4 (renderCall params)
          ++  "\n"
      )
    /\ { RowDef }
```

Note the final `/\ { RowDef }` — `Query.dhall` (Task 2) needs to reference `StatementModule.RowDef` as a type, the same way it used to reference `RowsModule.RowDef`, so `RowDef` must be exported from the module's record the same way `RowsModule.dhall` did (`Sdk.Sigs.template Params run /\ { RowDef }`).

- [ ] **Step 3: Delete `src/Templates/RowsModule.dhall`**

Run: `git rm src/Templates/RowsModule.dhall`

- [ ] **Step 4: Confirm the file is self-contained**

Run: `cd python.gen && grep -n "RowsModule" src/Templates/StatementModule.dhall`
Expected: no output (the new file must not reference the deleted module).

- [ ] **Step 5: Commit**

```bash
git add src/Templates/StatementModule.dhall
git commit -m "python.gen: move RowDef/renderRow into StatementModule, render rows inline"
```

(This task alone does not yet type-check the whole generator — `Query.dhall` and `Project.dhall` still reference the now-deleted `RowsModule` and the old `Params.rowClassName` field. Task 2 fixes that; run `dhall type --file=src/package.dhall` at the end of Task 2, not this one.)

---

### Task 2: Merge imports and retarget `Query.dhall` and `Project.dhall`

**Files:**
- Modify: `src/Interpreters/Query.dhall`
- Modify: `src/Interpreters/Project.dhall`

**Interfaces:**
- Consumes: `StatementModule.RowDef` (Task 1).
- Produces: `Query.dhall`'s `Output` shrinks to `{ functionName : Text, rowClassName : Optional Text, modulePath : Text, content : Text }` (drops `rowDef` and `rowImports`, both now `render`-internal only). `Project.dhall`'s `combineOutputs` no longer builds `_rows.py`.

- [ ] **Step 1: Rewrite `src/Interpreters/Query.dhall` in full**

```dhall
let Lude = ../Deps/Lude.dhall

let Prelude = ../Deps/Prelude.dhall

let Model = ../Deps/Contract.dhall

let Sdk = ../Deps/Sdk.dhall

let ImportSet = ../Structures/ImportSet.dhall

let PyIdent = ../Structures/PyIdent.dhall

let Surface = ../Structures/Surface.dhall

let OnUnsupported = ../Structures/OnUnsupported.dhall

let ResultModule = ./Result.dhall

let QueryFragmentsModule = ./QueryFragments.dhall

let ParamsMember = ./ParamsMember.dhall

let StatementModule = ../Templates/StatementModule.dhall

let Config =
      { packageName : Text
      , importName : Text
      , sync : Bool
      , onUnsupported : OnUnsupported.Mode
      }

let Compiled = Lude.Compiled

let Input = Model.Query

-- A query renders to one thin statement module: its own Row dataclass and
-- decode function (when it returns rows) plus the I/O wrapper for whichever
-- surface config.sync picked. rowClassName is still surfaced here (not just
-- internal to the rendered content) because Project.dhall's facade needs the
-- name to build the re-export line; the Row's full definition does not
-- leave this module.
let Output =
      { functionName : Text
      , rowClassName : Optional Text
      , modulePath : Text
      , content : Text
      }

let render =
      \(config : Config) ->
      \(input : Input) ->
      \(result : ResultModule.Output) ->
      \(fragments : QueryFragmentsModule.Output) ->
      \(params : List ParamsMember.Output) ->
        -- The function name is also the module filename and the facade import name;
        -- a query named like a Python keyword would emit `def class(...)`, a module
        -- `class.py`, and `from ... import class` (all SyntaxErrors), so sanitize it
        -- like params and result columns. SQL/dict/row lookups key off raw names.
        let functionName = PyIdent.pySafeName input.name.inSnakeCase

        let decodeName = "decode_${functionName}"

        let paramSigLines =
              Prelude.List.map
                ParamsMember.Output
                Text
                (\(p : ParamsMember.Output) -> p.fieldName ++ ": " ++ p.pyType)
                params

        let paramDictEntries =
              Prelude.List.map
                ParamsMember.Output
                Text
                ( \(p : ParamsMember.Output) ->
                    "\"" ++ p.pgName ++ "\": " ++ p.bindExpr
                )
                params

        let paramImports =
              ImportSet.combineAll
                ( Prelude.List.map
                    ParamsMember.Output
                    ImportSet.Type
                    (\(p : ParamsMember.Output) -> p.imports)
                    params
                )

        let rowClassName =
              Prelude.Optional.map
                ResultModule.RowClass
                Text
                (\(rc : ResultModule.RowClass) -> rc.name)
                result.rowClass

        let rowDef =
              Prelude.Optional.map
                ResultModule.RowClass
                StatementModule.RowDef
                ( \(rc : ResultModule.RowClass) ->
                    { className = rc.name
                    , fieldsBlock = rc.fieldsBlock
                    , decodeBlock = rc.decodeBlock
                    , decodeName
                    }
                )
                result.rowClass

        -- The Row's own imports (JsonValue, Decimal, custom types, ...) and
        -- the parameters' imports both land in this one file now, so they
        -- merge into a single ImportSet instead of flowing to two separate
        -- consumers (the statement module and, formerly, _rows.py).
        let mergedImports = ImportSet.combine paramImports result.imports

        let surface = if config.sync then Surface.sync else Surface.async

        let content =
              StatementModule.run
                { functionName
                , returnType = result.returnType
                , helperName = result.helperName
                , callsDecode = result.callsDecode
                , sqlLiteral = fragments.sqlLiteral
                , rowDef
                , decodeName
                , paramSigLines
                , paramDictEntries
                , imports = mergedImports
                , surface
                }

        in  { functionName
            , rowClassName
            , modulePath = "statements/${functionName}.py"
            , content
            }

let run =
      \(config : Config) ->
      \(input : Input) ->
        let rowClassName = input.name.inPascalCase ++ "Row"

        in  Compiled.nest
              Output
              input.srcPath
              ( Compiled.map3
                  ResultModule.Output
                  QueryFragmentsModule.Output
                  (List ParamsMember.Output)
                  Output
                  (render config input)
                  ( Compiled.nest
                      ResultModule.Output
                      "result"
                      (ResultModule.run (config /\ { rowClassName }) input.result)
                  )
                  ( Compiled.nest
                      QueryFragmentsModule.Output
                      "sql"
                      (QueryFragmentsModule.run config input.fragments)
                  )
                  ( Compiled.nest
                      (List ParamsMember.Output)
                      "params"
                      ( Compiled.traverseList
                          Model.Member
                          ParamsMember.Output
                          ( \(member : Model.Member) ->
                              Compiled.nest
                                ParamsMember.Output
                                member.pgName
                                (ParamsMember.run config member)
                          )
                          input.params
                      )
                  )
              )

in  Sdk.Sigs.interpreter Config Input Output run
```

- [ ] **Step 2: Drop the `RowsModule` import and the `_rows.py` machinery from `src/Interpreters/Project.dhall`**

Delete line 25 (`let RowsModule = ../Templates/RowsModule.dhall`).

Delete the `rowDefs`, `rowImports`, and `rowsFiles` bindings from `combineOutputs` (these sat between the `runtimeModule`/`statementsInit` bindings and `statementFiles`, per the sync-output plan's Task 2 Step 3 rewrite):

```dhall
        let rowDefs =
              Prelude.List.concatMap
                QueryGen.Output
                RowsModule.RowDef
                ( \(query : QueryGen.Output) ->
                    Prelude.Optional.toList RowsModule.RowDef query.rowDef
                )
                queries

        let rowImports =
              ImportSet.combineAll
                ( Prelude.List.map
                    QueryGen.Output
                    ImportSet.Type
                    (\(query : QueryGen.Output) -> query.rowImports)
                    queries
                )

        let rowsFiles =
              if    Prelude.List.null RowsModule.RowDef rowDefs
              then  [] : List Lude.File.Type
              else  [ { path = srcPrefix ++ "_rows.py"
                      , content =
                          RowsModule.run { rows = rowDefs, imports = rowImports }
                      }
                    ]

```

(all three bindings, deleted in full — `statementFiles` becomes the very next binding after `statementsInit`.)

Update `allFiles` to drop the now-nonexistent `rowsFiles`:

```dhall
        let allFiles =
                staticFiles
              # registerFiles
              # typesInitFiles
              # typeFiles
              # statementFiles
```

- [ ] **Step 3: Type-check the whole generator**

Run: `cd python.gen && dhall type --file=src/package.dhall`
Expected: prints the generator's function type, no errors.

- [ ] **Step 4: Confirm no `RowsModule` references remain**

Run: `cd python.gen && grep -rn "RowsModule" src/`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add src/Interpreters/Query.dhall src/Interpreters/Project.dhall
git commit -m "python.gen: merge row and param imports per statement, delete _rows.py emission"
```

---

### Task 3: Update `FacadeModule.dhall`'s Row re-export

**Files:**
- Modify: `src/Templates/FacadeModule.dhall`
- Modify: `src/Templates/CoreModule.dhall` (comment only)

- [ ] **Step 0: Fix the stale `_rows.py` mention in `src/Templates/CoreModule.dhall`'s header comment**

Line 9, "and _rows.py, the statement modules, and the facades import these" → "and the statement modules and facades import these" (the full comment, lines 3-10):

```dhall
-- The surface-agnostic core of a generated package, emitted once at
-- _generated/_core.py. It owns the names shared by every module and by both the
-- async and sync surfaces: the JsonValue alias, the NoRowError/DecodeError
-- exceptions, and the require_array decode guard. It performs no I/O, so there is
-- exactly one copy regardless of surface. The two _runtime.py modules re-export
-- JsonValue/NoRowError/require_array from here so off-contract imports keep
-- working, and the statement modules and facades import these names from
-- _core directly.
```

- [ ] **Step 1: Fold the Row-class alias onto each statement's own import line**

Replace the body of `run` (everything from `let runtimeBlock = ...` through `let allNames = ...`, i.e. lines 49-112 of the pre-this-plan file):

```dhall
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

        -- A query's Row class now lives in that query's own statement
        -- module (there is no shared _rows module anymore), so the row
        -- alias, when present, rides on the same import line as the
        -- statement function itself: "from ...statements.fn import fn as
        -- fn, RowCls as RowCls" — one line per statement, not two separate
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

                    in      "from ${generatedPrefix}.${statementsPath}.${s.functionName} import "
                        ++  alias s.functionName
                        ++  rowSuffix
                )
                params.statements

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
```

Note `rowNames`/`rowNames params.statements` (the `rows` binding) is still needed — it still feeds `allNames` for `__all__` — only the separate `rowBlock` import section it used to also build is gone. Leave the `rowNames` function definition itself untouched.

- [ ] **Step 2: Type-check the whole generator**

Run: `cd python.gen && dhall type --file=src/package.dhall`
Expected: prints the generator's function type, no errors.

- [ ] **Step 3: Commit**

```bash
git add src/Templates/FacadeModule.dhall src/Templates/CoreModule.dhall
git commit -m "python.gen: facade imports each Row class from its own statement module"
```

---

### Task 4: Regenerate both golden trees and fix the unsupported-types test

**Files:**
- Modify: `tests/test_unsupported_types.py`
- Regenerate: `tests/golden/`, `tests/golden_sync/`

**Interfaces:**
- Consumes: `mise run golden` (unchanged mechanism from the sync-output plan's Task 4 — that plan already made it regenerate both trees in one pass).

- [ ] **Step 1: Delete the stale freeze file**

Run: `rm -f tests/fixture-project/freeze1.pgn.yaml`

- [ ] **Step 2: Update `tests/test_unsupported_types.py`**

Delete the `rows = (src / "_rows.py").read_text()` line and its assertion. Before:

```python
    facade = (package_src / "__init__.py").read_text()
    rows = (src / "_rows.py").read_text()
    register = (src / "_register.py").read_text()
    types_init = (src / "types" / "__init__.py").read_text()
    for orphan in (
        "probe_unsupported",
        "probe_json_array",
        "probe_nested_composite",
        "wrapped_point",
        "WrappedPoint",
    ):
        assert orphan not in facade, f"facade references skipped {orphan}"
        assert orphan not in rows, f"_rows references skipped {orphan}"
        assert orphan not in register, f"_register references skipped {orphan}"
        assert orphan not in types_init, f"types/__init__ references skipped {orphan}"
```

After:

```python
    facade = (package_src / "__init__.py").read_text()
    register = (src / "_register.py").read_text()
    types_init = (src / "types" / "__init__.py").read_text()
    for orphan in (
        "probe_unsupported",
        "probe_json_array",
        "probe_nested_composite",
        "wrapped_point",
        "WrappedPoint",
    ):
        assert orphan not in facade, f"facade references skipped {orphan}"
        assert orphan not in register, f"_register references skipped {orphan}"
        assert orphan not in types_init, f"types/__init__ references skipped {orphan}"
```

(A skipped query's Row now lives only inside that query's own statement file, which the adjacent assertion at line 171 — `assert not (src / "statements" / f"{name}.py").exists()` — already proves never got written; there is no longer a shared file where an orphaned Row reference could leak.)

Delete the `importlib.import_module("fixture._generated._rows")` line. Before:

```python
        importlib.import_module("fixture")
        importlib.import_module("fixture._generated._register")
        importlib.import_module("fixture._generated._rows")
        for name in kept_statements:
            importlib.import_module(f"fixture._generated.statements.{name}")
```

After:

```python
        importlib.import_module("fixture")
        importlib.import_module("fixture._generated._register")
        for name in kept_statements:
            importlib.import_module(f"fixture._generated.statements.{name}")
```

- [ ] **Step 3: Run the golden refresh**

Run: `cd python.gen && mise run golden`
Expected: exits 0. Needs a reachable Postgres (`PGN_TEST_DATABASE_URL`).

- [ ] **Step 4: Review the diff**

Run: `cd python.gen && git status tests/golden tests/golden_sync && git diff --stat tests/golden tests/golden_sync`
Expected: `tests/golden/src/specimen_client/_generated/_rows.py` and `tests/golden_sync/src/specimen_sync_client/_generated/_rows.py` are deleted. Every `_generated/statements/*.py` file in both trees grows (gains its own Row dataclass + decode function, plus the new `Mapping`/`dataclass`/`typing.cast` imports where it returns rows). `src/specimen_client/__init__.py` and `src/specimen_sync_client/__init__.py` (the facades) change: each statement's import line grows a `, RowCls as RowCls` suffix, and the old separate `from ._generated._rows import (...)` block disappears. No SQL, param, or decode-expression content should differ from before this plan — only file placement and import statements.

- [ ] **Step 5: Spot-check one regenerated statement file**

Run: `cat tests/golden/src/specimen_client/_generated/statements/get_specimen.py`
Expected: imports (including `from collections.abc import Mapping`, `from dataclasses import dataclass`, `from typing import cast`), then `@dataclass(frozen=True, slots=True)\nclass GetSpecimenRow:`, then `def decode_get_specimen(row: Mapping[str, object]) -> GetSpecimenRow:`, then two blank lines, then `SQL = """...`, then `async def get_specimen(...)`. No `from .._rows import` line anywhere in the file.

- [ ] **Step 6: Commit**

```bash
git add tests/golden tests/golden_sync tests/test_unsupported_types.py
git commit -m "python.gen: regenerate golden trees with rows distributed per statement"
```

---

### Task 5: Run the full pytest harness

**Files:** none (verification only — Tasks 1-4 already touched every file the harness exercises; this task's job is to confirm they cohere).

- [ ] **Step 1: Run the full harness**

Run: `cd python.gen && mise run test`
Expected: all tests pass, including `test_generated_matches_golden`, `test_generated_sync_matches_golden`, both basedpyright-strict tests, all round-trip tests, and `test_unsupported_types.py`'s skip-mode tests.

- [ ] **Step 2: Confirm no stray `_rows`/`RowsModule` references remain in source or tests**

Run: `cd python.gen && grep -rln "_rows\|RowsModule" src/ tests/*.py demos/ 2>/dev/null`
Expected: no output.

- [ ] **Step 3: Commit if Steps 1-2 required any fixes**

If the full-suite run surfaced anything Tasks 1-4 missed, fix it here and commit; otherwise this task is a clean pass-through and needs no commit of its own.

---

### Task 6: Update documentation

**Files:**
- Modify: `DESIGN.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Rewrite `DESIGN.md`'s "Generated package layout" tree**

Starting from the tree the sync-output plan (`docs/plans/2026-07-12-configurable-sync-output.md`, Task 7 Step 5) already left behind, drop the `_rows.py` line:

```text
src/<pkg>/__init__.py                       # generated facade (re-exports everything)
src/<pkg>/_generated/__init__.py
src/<pkg>/_generated/_core.py               # surface-agnostic: JsonValue, NoRowError, require_array
src/<pkg>/_generated/_runtime.py            # I/O helpers for whichever surface config.sync picked
src/<pkg>/_generated/_register.py           # only if composites or enums
src/<pkg>/_generated/statements/__init__.py
src/<pkg>/_generated/statements/<query_snake>.py   # one wrapper per query: its own Row + decode + def, def or async def
src/<pkg>/_generated/types/__init__.py      # only if custom types exist
src/<pkg>/_generated/types/<type_snake>.py
```

- [ ] **Step 2: Rewrite `## 2. Shared type layer: `_rows.py` and `types/`` (renumber/retitle to "## 2. Per-statement rows and the shared `types/` layer")**

```markdown
## 2. Per-statement rows and the shared `types/` layer

Decode is LOCAL to each statement now, not centralized. For each query that
returns rows, its own statement module holds one
`@dataclass(frozen=True, slots=True)` Row plus a module-level
`decode_<query>(row: Mapping[str, object]) -> <Row>` function, immediately
above the `SQL = ...` constant. There is a strict 1:1 relationship between a
query and its Row (no two queries share a Row class, even when their result
shapes are identical), so co-locating them costs nothing:

```python
# statements/get_specimen.py
from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import cast

from psycopg import AsyncConnection

from .._runtime import fetch_single


@dataclass(frozen=True, slots=True)
class GetSpecimenRow:
    ...


def decode_get_specimen(row: Mapping[str, object]) -> GetSpecimenRow:
    return GetSpecimenRow(...)


SQL = """..."""

_SQL = SQL.encode()


async def get_specimen(conn: AsyncConnection[object], *, id: int) -> GetSpecimenRow | None:
    ...
    return await fetch_single(conn, _SQL, params, decode_get_specimen)
```

`Templates/StatementModule.dhall` renders both the Row and the wrapper in one
pass; `Interpreters/Query.dhall` merges the parameter-side and result-side
`ImportSet`s into one set per file, since both now live in the same module.
The package-root facade re-exports every Row from its own statement module
(`from ._generated.statements.get_specimen import get_specimen as
get_specimen, GetSpecimenRow as GetSpecimenRow`), not from a shared module.

`types/<snake>.py` still holds the enum / composite class, unchanged by this
— custom types genuinely are shared across every query that references them,
unlike Rows. A statement module's custom-type imports (whether the type
appears in a param or a result column) all use the same `${typesPrefix}`
prefix (`..types`) now, since both originate from the same file.
```

- [ ] **Step 3: Update the "Generator decomposition" file tree**

Drop the `RowsModule.dhall` line and update `StatementModule.dhall`'s description:

```text
  Templates/
    CoreModule.dhall         # shared _core.py: JsonValue, NoRowError/DecodeError, require_array
    RuntimeModule.dhall      # async + sync _runtime.py bodies
    StatementModule.dhall    # one wrapper per query: its own Row dataclass + decode fn, plus the I/O def
    RegisterModule.dhall     # _register.py (per surface)
    FacadeModule.dhall       # the flat package-root facade
    EnumModule.dhall / CompositeModule.dhall / TypesInit.dhall / InitModule.dhall
```

- [ ] **Step 4: Repoint the byte-offset example that referenced `_rows.py`**

Run: `grep -n "_rows.py" DESIGN.md` and update the surrounding sentence (around what was originally line 600, describing the `moods` column) to reference `tests/golden/src/specimen_client/_generated/statements/list_specimens_by_moods.py` (or whichever statement file the example was illustrating) instead of `_rows.py`.

- [ ] **Step 5: Add a `CHANGELOG.md` "Upcoming" entry**

```markdown
- **Breaking:** `_rows.py` is gone. Each query's Row dataclass and
  `decode_<query>` function now live directly in that query's own statement
  module (`statements/<query_snake>.py`), rendered immediately above the
  `SQL = ...` constant, instead of in one shared, project-wide file. This
  only affects code importing `from <pkg>._generated._rows import ...`
  directly — the README has always said to import from the flat facade
  instead, and the facade's re-exported names (`GetSpecimenRow`,
  `decode_get_specimen`, etc.) are unchanged. See
  `docs/plans/2026-07-12-distribute-rows-per-statement.md` for the full
  rationale.
```

- [ ] **Step 6: Commit**

```bash
git add DESIGN.md CHANGELOG.md
git commit -m "python.gen: document per-statement row distribution"
```
