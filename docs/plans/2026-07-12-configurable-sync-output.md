# Configurable Sync Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the additive `emitSync : Optional Bool` config knob (which always emits async and optionally bolts a second `sync/` tree on top) with an exclusive `sync : Optional Bool` knob, default `False`, that selects exactly one surface — async or sync — and emits it at the same unified file paths either way, so flipping the flag never changes the shape of the output tree or any import path, only file contents.

**Architecture:** `Interpreters/Project.dhall` picks one `Surface.Type` value (`Surface.async` when `config.sync` is `False`, `Surface.sync` when `True`) and threads it through a single render pass instead of today's two passes (always-async + conditionally-additive-sync). `Interpreters/Query.dhall`'s per-query `Output` collapses its `asyncModulePath`/`asyncContent`/`syncModulePath`/`syncContent` two-surface duplication down to one `modulePath`/`content` pair. `Structures/Surface.dhall`'s import-depth tokens (`rowsImport`, `corePrefix`, `typesPrefix`) collapse to the same value for both surfaces, since sync statement modules no longer live one package deeper under `sync/statements/` — they live at the exact path async statements use today. `_rows.py` and `types/` are untouched by this plan (still surface-agnostic, still emitted once); splitting `_rows.py` per statement is a separate, later plan (`docs/plans/2026-07-12-distribute-rows-per-statement.md`) that depends on this one landing first.

**Tech Stack:** Dhall (dhall-lang 1.42 vendored via `dhall` CLI; pgn's forked interpreter for the parts still using it), Python 3.12 generated output (psycopg3), basedpyright strict, pytest golden-file harness (`mise run test`, `mise run golden`), pgn 0.9.1 (mise-pinned).

## Global Constraints

- No behavior change to param/result type mapping, custom-type codecs, or SQL rendering — this plan is scoped to the sync/async surface-selection mechanism only.
- Default behavior when `config.sync` is omitted must be byte-identical to today's `emitSync` omitted/false default (async only, same paths) — verified by golden diff.
- Golden fixture output (`tests/golden/`, new `tests/golden_sync/`) must be regenerated via `mise run golden`, not hand-edited (per `tests/golden/README.md`).
- `mise run test` (pytest, includes `test_generated_passes_basedpyright_strict`) must pass after regeneration, for both the async and sync golden trees.
- Every Dhall file touched must independently type-check via the whole-generator check: `dhall type --file=src/package.dhall`.
- This is a breaking config change (the `emitSync` key stops existing). Per this repo's convention (see `CHANGELOG.md`'s "Upcoming" section and the "Drop the plans" precedent), document it there — no deprecation shim, no dual-key transition period.
- CI's memory-reduction script (`.github/workflows/ci.yml`, "Reduce the fixture project to the python artifact") truncates `tests/fixture-project/project1.pgn.yaml` at the `# The variants below` marker. Any new artifact that must run in CI (not just locally) has to be placed *before* that marker.

---

## File Structure

| File | Change |
|---|---|
| `src/package.dhall` | Public `Config`/`Config/default`: rename `emitSync` field to `sync`; rewrite doc comment. |
| `src/Interpreters/Project.dhall` | `Config`/`ResolvedConfig`: rename field. `run`: rename resolve binding. `combineOutputs`: replace always-async-plus-optional-sync emission with single-surface emission at unified paths. |
| `src/Interpreters/Query.dhall` | `Config`: rename field. `Output`: collapse `asyncModulePath`/`asyncContent`/`syncModulePath`/`syncContent` to `modulePath`/`content`. `render`: pick one surface, call `StatementModule.run` once instead of twice. |
| `src/Structures/Surface.dhall` | Collapse `sync`'s `rowsImport`/`corePrefix`/`typesPrefix` to the same depth as `async`'s (no more extra-dot nesting). Rewrite header comment. |
| `src/Templates/RuntimeModule.dhall` | Update the `syncContent` doc comment (no longer describes a `sync/_runtime.py` path). |
| `src/Interpreters/{Value,ResultColumns,Member,Scalar,QueryFragments,ParamsMember,CustomType,Primitive,Result}.dhall` | Mechanical rename: local `Config` type's `emitSync : Bool` field → `sync : Bool` (each is a narrowing projection of `ResolvedConfig`, never itself branches on the value except `Result.dhall`'s field-selection literal). |
| `demos/Exhaustive.dhall` | Rename `emitSync = Some True` → `sync = Some True`. |
| `tests/fixture-project/project1.pgn.yaml` | Main `python:` artifact: drop `emitSync: true` (default `sync: false` going forward). Add new `python-sync:` artifact (`sync: true`), placed before the CI truncation marker. Rename `emitSync` → `sync` in the `python-sync-only` and `python-null` variants. |
| `tests/golden_sync/` (new) | Hand-written shell (`pyproject.toml`, `README.md`, `src/specimen_sync_client/py.typed`) mirroring `tests/golden/`'s shell, for the new `python-sync` artifact's committed golden tree. |
| `tests/_harness.py` | Add `GOLDEN_DIR_SYNC` path constant. |
| `tests/conftest.py` | Add a `full_package_sync` fixture mirroring `full_package`, sourced from the `python_sync` artifact directory and `GOLDEN_DIR_SYNC`. |
| `tests/test_generated.py` | Drop `SYNC_FACADE_INIT` and the two-facade loop in `test_generated_matches_golden`. Add `test_generated_sync_matches_golden` and `test_generated_sync_passes_basedpyright_strict`. Delete `test_roundtrip_sync_and_cross_surface_identity` (cross-surface identity no longer exists once surfaces are exclusive); replace with `test_roundtrip_sync_surface` against `full_package_sync`. Move `test_roundtrip_single_field_composite_sync` onto `full_package_sync` with unified (non-`.sync.`) import paths. |
| `tests/test_config_variants.py` | Replace the `(package / "sync").exists()` presence check (no longer meaningful once paths are unified) with a content-based signal read from `_generated/_runtime.py`. Rename `emitSync` → `sync` throughout prose and assertions. |
| `mise.toml` | `golden` task: also generate and rsync the `python-sync` artifact into `tests/golden_sync/`. |
| `README.md` | Config reference table, quickstart example, "Key features," "Using the generated code" section. |
| `DESIGN.md` | Sections 1 ("What the generator emits"), 3 (runtime import example), 4 ("Surface mechanism"), 9 (facade), 10 (Config flow) — rewrite to describe exclusive single-surface selection at unified paths. |
| `CHANGELOG.md` | New "Upcoming" entry documenting the breaking config change. |

---

### Task 1: Rename `emitSync` to `sync` across the Config-threading chain (no behavior change)

Pure rename first, isolated from the behavior change in Task 2, so it is independently verifiable: after this task, generation is byte-identical to before, just keyed on a renamed config field.

**Files:**
- Modify: `src/package.dhall`
- Modify: `src/Interpreters/Project.dhall`
- Modify: `src/Interpreters/Query.dhall`
- Modify: `src/Interpreters/Value.dhall`, `ResultColumns.dhall`, `Member.dhall`, `Scalar.dhall`, `QueryFragments.dhall`, `ParamsMember.dhall`, `CustomType.dhall`, `Primitive.dhall`, `Result.dhall`
- Modify: `demos/Exhaustive.dhall`

**Interfaces:**
- Produces: every interpreter's `Config` type now has a `sync : Bool` field (was `emitSync : Bool`); `Project.dhall`'s public `Config`/`ResolvedConfig` and `src/package.dhall`'s `Config`/`Config/default` match. Task 2 reads `config.sync` / `resolvedConfig.sync`.

- [ ] **Step 1: Rename in `src/package.dhall`**

```dhall
let Sdk = ./Deps/Sdk.dhall

let OnUnsupported = ./Structures/OnUnsupported.dhall

let ProjectInterpreter = ./Interpreters/Project.dhall

-- User-facing config for this generator. `sync` picks which single surface
-- the generator emits: `False` (default) emits the async surface
-- (psycopg.AsyncConnection); `True` emits the sync surface
-- (psycopg.Connection) instead, at the exact same paths — flipping this
-- flag never changes the output tree's shape or any import path, only file
-- contents. `onUnsupported` picks Fail (default, abort loudly) or Skip (drop
-- the unsupported statement/type and its dependents, with a warning) when a
-- query or custom type hits a PG shape the generator cannot render; see
-- Structures/OnUnsupported.dhall. All fields are Optional so a project may
-- omit the whole config block or any subset of its keys;
-- Interpreters/Project.dhall's `run` supplies the defaults.
let Config =
      { packageName : Optional Text
      , sync : Optional Bool
      , onUnsupported : Optional OnUnsupported.Mode
      } : Type

let Config/default
    : Config
    = { packageName = None Text
      , sync = None Bool
      , onUnsupported = None OnUnsupported.Mode
      }

in  Sdk.Sigs.generator Config Config/default ProjectInterpreter.run
```

- [ ] **Step 2: Rename in `src/Interpreters/Project.dhall`**

Replace lines 35-53 (the `Config` and `ResolvedConfig` declarations):

```dhall
-- The generator's public Config: every field is independently Optional, so a
-- project may omit the whole `config:` block or any subset of its keys.
-- `run` below resolves the fallbacks itself (packageName from the project
-- name, sync off (async), onUnsupported Fail); there is no separate config
-- type or resolve step between package.dhall and here.
let Config =
      { packageName : Optional Text
      , sync : Optional Bool
      , onUnsupported : Optional OnUnsupported.Mode
      }

-- The fully-resolved shape every downstream interpreter (Query, CustomType,
-- and everything below them) actually declares as its own `Config`.
let ResolvedConfig =
      { packageName : Text
      , importName : Text
      , sync : Bool
      , onUnsupported : OnUnsupported.Mode
      }
```

Replace the `emitSync` resolve binding in `run` (around line 380-386):

```dhall
        let sync =
              Prelude.Optional.fold
                Bool
                config.sync
                Bool
                (\(b : Bool) -> b)
                False
```

And its use in building `resolvedConfig` (around line 398-400):

```dhall
        let resolvedConfig
            : ResolvedConfig
            = { packageName, importName, sync, onUnsupported }
```

Leave the rest of `combineOutputs`'s body as-is for this task — Task 2 rewrites that function's structure anyway — but rename the two literal occurrences of the field name inside it so Step 7's type-check passes. Line 272 (doc comment):

```dhall
        -- config.sync. It reuses the shared `_rows.py` and `types/`, so only
```

Line 325 (the conditional gating `syncFiles`):

```dhall
        let syncFiles =
              if    config.sync
              then    [ syncSubpackageInit
```

- [ ] **Step 3: Rename in `src/Interpreters/Query.dhall`**

Line 28 (`Config` record): `, emitSync : Bool` → `, sync : Bool`.

Line 40 comment ("emitted only when config.emitSync") → "emitted only when config.sync" (Task 2 rewrites this comment fully; this step is the minimal rename).

- [ ] **Step 4: Rename the narrowing `Config` field in the nine passthrough interpreters**

Each of these files declares a local `Config` type that is a narrowing projection of `ResolvedConfig`, purely so later Dhall record-selection syntax can pick the field out by name. None of them branch on the value except `Result.dhall`'s selection literal (next step). In each file, change the line `, emitSync : Bool` to `, sync : Bool`:

| File | Line |
|---|---|
| `src/Interpreters/Value.dhall` | 18 |
| `src/Interpreters/ResultColumns.dhall` | 20 |
| `src/Interpreters/Member.dhall` | 20 |
| `src/Interpreters/Scalar.dhall` | 16 |
| `src/Interpreters/QueryFragments.dhall` | 16 |
| `src/Interpreters/ParamsMember.dhall` | 18 |
| `src/Interpreters/CustomType.dhall` | 22 |
| `src/Interpreters/Primitive.dhall` | 14 |
| `src/Interpreters/Result.dhall` | 25 |

- [ ] **Step 5: Rename the field-selection literal in `src/Interpreters/Result.dhall`**

Line 94:

```dhall
                  config.{ packageName, importName, sync, onUnsupported }
```

- [ ] **Step 6: Rename in `demos/Exhaustive.dhall`**

Line 29:

```dhall
        { packageName = None Text
        , sync = Some True
        , onUnsupported = Some OnUnsupported.Mode.Skip
        }
```

- [ ] **Step 7: Type-check the whole generator**

Run: `cd python.gen && dhall type --file=src/package.dhall`
Expected: prints the generator's function type, no errors. (This alone proves every renamed `Config` record still lines up across every call site — Dhall's structural typing would reject a mismatched field name.)

- [ ] **Step 8: Confirm no `emitSync` references remain in `src/`**

Run: `cd python.gen && grep -rn "emitSync" src/ demos/`
Expected: no output.

- [ ] **Step 9: Commit**

```bash
git add src/package.dhall src/Interpreters/Project.dhall src/Interpreters/Query.dhall \
  src/Interpreters/Value.dhall src/Interpreters/ResultColumns.dhall src/Interpreters/Member.dhall \
  src/Interpreters/Scalar.dhall src/Interpreters/QueryFragments.dhall src/Interpreters/ParamsMember.dhall \
  src/Interpreters/CustomType.dhall src/Interpreters/Primitive.dhall src/Interpreters/Result.dhall \
  demos/Exhaustive.dhall
git commit -m "python.gen: rename emitSync config field to sync (no behavior change)"
```

---

### Task 2: Make `sync` exclusive — unify output paths, single-surface emission

**Files:**
- Modify: `src/Structures/Surface.dhall`
- Modify: `src/Interpreters/Query.dhall`
- Modify: `src/Interpreters/Project.dhall`
- Modify: `src/Templates/RuntimeModule.dhall` (comment only)
- Modify: `src/Templates/FacadeModule.dhall` (drop dead surface-selection params)

**Interfaces:**
- Consumes: `resolvedConfig.sync : Bool` (from Task 1).
- Produces: `Query.dhall`'s `Output` record now has `modulePath : Text` and `content : Text` (replacing the four async/sync-prefixed fields) — any code outside this task that referenced `query.asyncModulePath` etc. must be updated in this same task, since Dhall's structural typing will fail closed on the old field names.

- [ ] **Step 1: Collapse the import-depth tokens in `src/Structures/Surface.dhall`**

Sync statement modules no longer live one package deeper (`sync/statements/`) — they live at the exact same `statements/` path async uses. Both surfaces now reach `_rows`, `_core`, and `types/` at the same relative depth.

```dhall
-- A code-generation surface: the async or sync flavour of a statement module.
-- Exactly one surface is emitted per generate (Interpreters/Project.dhall
-- picks async or sync from config.sync and renders everything at the same
-- unified paths), so the two Surface values differ only in the tokens that
-- vary between `async def`/`def`, `AsyncConnection`/`Connection`, and
-- `await `/``. Both reach the shared `_rows`/`_core`/`types` modules at the
-- same relative import depth, since neither surface is nested under a
-- surface-named subdirectory.
let Surface =
      { defKeyword : Text
      , connType : Text
      , awaitKw : Text
      , rowsImport : Text
      , corePrefix : Text
      , typesPrefix : Text
      }

let async
    : Surface
    = { defKeyword = "async def"
      , connType = "AsyncConnection"
      , awaitKw = "await "
      , rowsImport = ".._rows"
      , corePrefix = ".._core"
      , typesPrefix = "..types"
      }

let sync
    : Surface
    = { defKeyword = "def"
      , connType = "Connection"
      , awaitKw = ""
      , rowsImport = ".._rows"
      , corePrefix = ".._core"
      , typesPrefix = "..types"
      }

in  { Type = Surface, async, sync }
```

- [ ] **Step 2: Collapse `Query.dhall`'s per-surface duplication**

Replace the `Output` record (lines 42-51):

```dhall
-- A query contributes a shared Row (assembled into `_rows.py` by Project) plus
-- one thin statement module, rendered for whichever surface config.sync picked.
let Output =
      { functionName : Text
      , rowClassName : Optional Text
      , rowDef : Optional RowsModule.RowDef
      , rowImports : ImportSet.Type
      , modulePath : Text
      , content : Text
      }
```

Replace the tail of `render` (from `let mkModule = ...` through the end of the function, lines 112-136):

```dhall
        let surface = if config.sync then Surface.sync else Surface.async

        let content =
              StatementModule.run
                { functionName
                , returnType = result.returnType
                , helperName = result.helperName
                , callsDecode = result.callsDecode
                , sqlLiteral = fragments.sqlLiteral
                , rowClassName
                , decodeName
                , paramSigLines
                , paramDictEntries
                , imports = paramImports
                , surface
                }

        in  { functionName
            , rowClassName
            , rowDef
            , rowImports = result.imports
            , modulePath = "statements/${functionName}.py"
            , content
            }
```

- [ ] **Step 3: Rewrite `Project.dhall`'s `combineOutputs` for single-surface emission**

Replace the whole body from the `let asyncFacade = ...` binding (line 157) through `let allFiles = ...` (line 347) with:

```dhall
        let surface = if config.sync then Surface.sync else Surface.async

        let facade =
              { path = packagePrefix ++ "__init__.py"
              , content =
                  FacadeModule.run
                    { generatedPrefix = "._generated"
                    , statementsPath = "statements"
                    , statements = facadeStatements
                    , types = facadeTypes
                    }
              }

        -- Surface-agnostic; performs no I/O, so exactly one copy is emitted
        -- regardless of surface. Both runtime bodies re-export from it.
        let coreModule =
              { path = srcPrefix ++ "_core.py", content = CoreModule.run {=} }

        let runtimeModule =
              { path = srcPrefix ++ "_runtime.py"
              , content =
                  if config.sync then RuntimeModule.runSync {=} else RuntimeModule.run {=}
              }

        let statementsInit =
              { path = srcPrefix ++ "statements/__init__.py"
              , content =
                  InitModule.run { docstring = "Generated SQL statements." }
              }

        -- The shared Row dataclasses + decode functions, imported by the
        -- statement modules of whichever surface was selected.
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

        let statementFiles =
              Prelude.List.map
                QueryGen.Output
                Lude.File.Type
                ( \(query : QueryGen.Output) ->
                    { path = srcPrefix ++ query.modulePath
                    , content = query.content
                    }
                )
                queries

        let typeFiles =
              Prelude.List.map
                CustomTypeGen.Output
                Lude.File.Type
                ( \(ct : CustomTypeGen.Output) ->
                    { path = srcPrefix ++ ct.modulePath
                    , content = ct.moduleContent
                    }
                )
                customTypes

        let typesInitExports =
              Prelude.List.map
                CustomTypeGen.Output
                TypesInit.Export
                (\(ct : CustomTypeGen.Output) -> { moduleName = ct.moduleName, typeName = ct.typeName })
                customTypes

        let typesInitFiles =
              if    Prelude.List.null CustomTypeGen.Output customTypes
              then  [] : List Lude.File.Type
              else  [ { path = srcPrefix ++ "types/__init__.py"
                      , content = TypesInit.run { exports = typesInitExports }
                      }
                    ]

        let compositeNames = compositePgNames customTypes

        let enumNames = enumPgNames customTypes

        let hasCustomRegistration =
              Prelude.Bool.not
                ( Prelude.Bool.and
                    [ Prelude.List.null Text compositeNames
                    , Prelude.List.null Text enumNames
                    ]
                )

        let registerFiles =
              if    hasCustomRegistration
              then  [ { path = srcPrefix ++ "_register.py"
                      , content =
                          RegisterModule.run { compositeNames, enumNames, surface }
                      }
                    ]
              else  [] : List Lude.File.Type

        let staticFiles =
              [ facade, topInit, coreModule, runtimeModule, statementsInit ]

        let allFiles =
                staticFiles
              # registerFiles
              # rowsFiles
              # typesInitFiles
              # typeFiles
              # statementFiles

        in  Prelude.List.map Lude.File.Type Lude.File.Type withHeader allFiles
          : Output
```

Note `topInit` (the `_generated/__init__.py` facade docstring file, defined earlier in the function and unchanged) is still referenced in `staticFiles` — leave its definition (around line 128-135 in the original) exactly as-is; only the block below it changes.

- [ ] **Step 4: Drop `FacadeModule.dhall`'s dead surface-selection parameters**

`generatedPrefix` and `statementsPath` exist only because the old design called `FacadeModule.run` twice with different values (once for the async facade at the package root, once for the sync facade one level down at `sync/__init__.py`). Now there is exactly one facade, always at the package root, so both become constants — hardcode them and drop them from `Params`.

Replace the header comment and `Params` declaration (lines 13-24):

```dhall
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
```

Replace every remaining `params.generatedPrefix` with `generatedPrefix` and every `params.statementsPath` with `statementsPath` in the rest of the file (the `runtimeBlock`, `typeBlock`, `rowBlock`, and `statementBlock` bindings inside `run`).

Then, back in `Interpreters/Project.dhall`, simplify the `facade` binding from Step 3 above to drop the now-nonexistent fields:

```dhall
        let facade =
              { path = packagePrefix ++ "__init__.py"
              , content =
                  FacadeModule.run
                    { statements = facadeStatements, types = facadeTypes }
              }
```

- [ ] **Step 5: Update the `syncContent` doc comment in `src/Templates/RuntimeModule.dhall`**

Replace the comment at lines 84-88:

```dhall
-- The sync surface's body, selected in place of `content` at the same
-- `_runtime.py` path when config.sync is True (Interpreters/Project.dhall).
-- The five helpers are the same shape with `def`/`Connection`/`with`/no-
-- `await`. JsonValue/NoRowError/require_array are re-exported from _core so
-- both surfaces share one canonical identity rather than two equal-but-
-- distinct definitions.
```

- [ ] **Step 6: Type-check the whole generator**

Run: `cd python.gen && dhall type --file=src/package.dhall`
Expected: prints the generator's function type, no errors.

- [ ] **Step 7: Delete the stale freeze file so the next `pgn generate` re-resolves the working tree**

Run: `rm -f tests/fixture-project/freeze1.pgn.yaml`
Expected: file removed (pgn's freeze cache does not know the generator source changed underneath a stable relative path; a stale freeze would silently keep emitting the old two-tree output).

- [ ] **Step 8: Commit**

```bash
git add src/Structures/Surface.dhall src/Interpreters/Query.dhall src/Interpreters/Project.dhall \
  src/Templates/RuntimeModule.dhall src/Templates/FacadeModule.dhall
git commit -m "python.gen: make sync/async mutually exclusive at unified output paths"
```

(This task intentionally does not update `tests/fixture-project/project1.pgn.yaml` yet — the main `python:` artifact still has `sync: true` from before Task 1's rename, so at this point in the plan, generating against it produces sync-surface content at the paths async used to occupy, and `tests/golden/` has not been refreshed yet, so `test_generated_matches_golden` and the sync-specific round-trip tests are expected to fail until Task 3 and Task 4 land. This is fine mid-plan; the full suite is the gate at the end, not after every task.)

---

### Task 3: Update the fixture project config

**Files:**
- Modify: `tests/fixture-project/project1.pgn.yaml`

**Interfaces:**
- Produces: a `python-sync` artifact (packageName `specimen-sync-client`) alongside the existing `python` artifact (now `sync` omitted, i.e. async by default), both ahead of the CI truncation marker. Task 4/5 consume `artifacts/python_sync` and the `specimen_sync_client` package name.

- [ ] **Step 1: Rewrite `tests/fixture-project/project1.pgn.yaml`**

```yaml
space: python-gen
name: fixture
version: 0.0.0
postgres: 18
artifacts:
  python:
    gen: ../../src/package.dhall
    config:
      packageName: specimen-client
  python-sync:
    gen: ../../src/package.dhall
    config:
      packageName: specimen-sync-client
      sync: true
  # The variants below pin pgn's actual YAML->Dhall decode semantics for the
  # Optional Config knobs (undocumented by pgn itself); see
  # tests/test_config_variants.py for the assertions.
  python-name-only:
    gen: ../../src/package.dhall
    config:
      packageName: name-only-client
  python-sync-only:
    gen: ../../src/package.dhall
    config:
      sync: true
  python-empty:
    gen: ../../src/package.dhall
    config: {}
  python-bare:
    gen: ../../src/package.dhall
  python-unknown-key:
    gen: ../../src/package.dhall
    config:
      packageName: unknown-key-client
      bogusField: 1
  python-null:
    gen: ../../src/package.dhall
    config:
      packageName: null-client
      sync: null
```

Note `python:` drops the `emitSync: true` key entirely (was: `packageName: specimen-client`, `emitSync: true`) — the primary golden fixture now represents the default (`sync` omitted → async), matching what most of `tests/test_generated.py` exercises. `python-sync` is new and sits *before* the `# The variants below` marker, so CI's truncation step (`.github/workflows/ci.yml`) keeps it alongside `python`.

- [ ] **Step 2: Commit**

```bash
git add tests/fixture-project/project1.pgn.yaml
git commit -m "python.gen: add python-sync fixture artifact, drop emitSync from main artifact"
```

---

### Task 4: Add the `tests/golden_sync/` shell and wire up golden regeneration for both artifacts

**Files:**
- Create: `tests/golden_sync/pyproject.toml`
- Create: `tests/golden_sync/README.md`
- Create: `tests/golden_sync/src/specimen_sync_client/py.typed`
- Modify: `tests/_harness.py`
- Modify: `mise.toml`
- Modify: `tests/golden/pyproject.toml` (drop the now-absent `emitSync`-driven `sync/` package reference — see Step 5)

**Interfaces:**
- Produces: `GOLDEN_DIR_SYNC` (a `Path` constant in `tests/_harness.py`), importable by `tests/conftest.py` and `tests/test_generated.py`.

- [ ] **Step 1: Create `tests/golden_sync/pyproject.toml`**

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "specimen-sync-client"
version = "0.0.0"
requires-python = ">=3.12"
dependencies = ["psycopg>=3.2"]

[tool.hatch.build.targets.wheel]
packages = ["src/specimen_sync_client"]

[tool.ruff]
exclude = ["src/specimen_sync_client/_generated"]
```

- [ ] **Step 2: Create `tests/golden_sync/src/specimen_sync_client/py.typed`**

Empty file (PEP 561 marker, matching `tests/golden/src/specimen_client/py.typed`).

```bash
mkdir -p tests/golden_sync/src/specimen_sync_client
touch tests/golden_sync/src/specimen_sync_client/py.typed
```

- [ ] **Step 3: Create `tests/golden_sync/README.md`**

```markdown
# Golden files (sync surface)

The sync-surface counterpart of `tests/golden/`: a committed full fixture
package generated with `config: { sync: true }`, package name
`specimen_sync_client`. Same structure and purpose as `tests/golden/README.md`
describes for the async (default) surface — the hand-written shell here
(`pyproject.toml`, `py.typed`) plus the generated `_generated/` subtree and
the generated package-root facade `src/specimen_sync_client/__init__.py`.

`test_generated_sync_matches_golden` regenerates the `python-sync` fixture
artifact into a temp tree and asserts every file under the fresh
`_generated/` plus the facade equals its golden twin here, both ways (no
missing, no extra). `test_generated_sync_passes_basedpyright_strict` runs
basedpyright strict on this full golden package.

## Updating the golden

Run only when a generator change legitimately alters the sync surface's
output, and review the resulting diff before committing.

```bash
mise run golden
```

`mise run golden` refreshes both `tests/golden/` (the `python` artifact) and
this directory (the `python-sync` artifact) in one pass — see `mise.toml`.
```

- [ ] **Step 4: Add `GOLDEN_DIR_SYNC` to `tests/_harness.py`**

Line 28, immediately after `GOLDEN_DIR = HERE / "golden"`:

```python
GOLDEN_DIR = HERE / "golden"
GOLDEN_DIR_SYNC = HERE / "golden_sync"
```

- [ ] **Step 5: Confirm `tests/golden/pyproject.toml` needs no change**

`tests/golden/pyproject.toml`'s `[tool.ruff] exclude` and `packages` entries already reference only `src/specimen_client` (not a `sync/` sub-path), so this file needs no edit — the sync surface's shell lives entirely under the new `tests/golden_sync/`, a sibling directory, not nested inside the existing golden tree. (Listed in File Structure above out of caution; this step is a no-op confirmation, not an edit.)

- [ ] **Step 6: Rewrite the `golden` task in `mise.toml`**

Replace the `[tasks.golden]` block:

```toml
# Regenerates the "python" and "python-sync" artifacts: a full 7-artifact
# generate peaks at ~31 GB RSS (memory goes to normalizing the generator
# closure per artifact, see ci.yml), so this keeps only the two artifacts
# golden actually needs instead of all 7.
[tasks.golden]
description = "Refresh tests/golden and tests/golden_sync from the working-tree src/"
run = '''
#!/usr/bin/env bash
set -euo pipefail
root="$(pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -R "$root/tests/fixture-project/." "$tmp/fixture"
rm -f "$tmp/fixture/freeze1.pgn.yaml"
rm -rf "$tmp/fixture/artifacts"
python3 - "$tmp/fixture/project1.pgn.yaml" "$root/src/package.dhall" <<'EOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
head, sep, _ = p.read_text().partition("  # The variants below")
assert sep, "variants marker not found in project1.pgn.yaml"
_ = p.write_text(head.rstrip().replace("../../src/package.dhall", sys.argv[2]) + "\n")
EOF
cd "$tmp/fixture"
pgn --database-url "${PGN_TEST_DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/postgres?sslmode=disable}" generate
rsync -a --delete artifacts/python/src/specimen_client/_generated/ "$root/tests/golden/src/specimen_client/_generated/"
cp artifacts/python/src/specimen_client/__init__.py "$root/tests/golden/src/specimen_client/__init__.py"
rsync -a --delete artifacts/python_sync/src/specimen_sync_client/_generated/ "$root/tests/golden_sync/src/specimen_sync_client/_generated/"
cp artifacts/python_sync/src/specimen_sync_client/__init__.py "$root/tests/golden_sync/src/specimen_sync_client/__init__.py"
echo "golden refreshed; review with: git diff tests/golden tests/golden_sync"
'''
```

Note the `cp .../sync/__init__.py` line from the original task is gone (no sync facade sub-path exists anymore); the sync surface's facade is now at the same top-level `__init__.py` position as async's, just in the sibling `python_sync` artifact directory.

- [ ] **Step 7: Run the golden refresh**

Run: `cd python.gen && mise run golden`
Expected: exits 0, prints `golden refreshed; review with: git diff tests/golden tests/golden_sync`. Needs a reachable Postgres (`PGN_TEST_DATABASE_URL`, default `postgresql://postgres:postgres@localhost:5432/postgres?sslmode=disable`).

- [ ] **Step 8: Review the diff**

Run: `cd python.gen && git status tests/golden tests/golden_sync && git diff tests/golden`
Expected: `tests/golden/src/specimen_client/_generated/sync/` and `tests/golden/src/specimen_client/sync/__init__.py` are deleted (14 files: `sync/__init__.py`, `sync/_register.py`, `sync/_runtime.py`, `sync/statements/__init__.py`, 10 `sync/statements/*.py`, package-root `sync/__init__.py`). `tests/golden_sync/src/specimen_sync_client/_generated/` is new and structurally mirrors what `tests/golden/src/specimen_client/_generated/` looked like *before* this plan minus the `sync/` nesting, with `def`/`Connection`/no-`await` content instead of `async def`/`AsyncConnection`/`await `. No other content in either tree should have changed (params, SQL, custom types, row shapes are untouched by this plan).

- [ ] **Step 9: Commit**

```bash
git add tests/golden tests/golden_sync tests/_harness.py mise.toml
git commit -m "python.gen: add tests/golden_sync, regenerate both golden trees for exclusive sync"
```

---

### Task 5: Update the pytest harness for two independent golden trees

**Files:**
- Modify: `tests/conftest.py`
- Modify: `tests/test_generated.py`

**Interfaces:**
- Consumes: `GOLDEN_DIR_SYNC` (Task 4), `artifacts/python_sync` (Task 3), package name `specimen_sync_client`.
- Produces: `full_package_sync` fixture (mirrors `full_package`), usable by any test needing an importable sync-surface package.

- [ ] **Step 1: Add a `generated_tree_sync`-adjacent path helper and `full_package_sync` fixture to `tests/conftest.py`**

Add after the existing `full_package` fixture (end of file):

```python
@pytest.fixture(scope="session")
def full_package_sync(generated_tree: Path, tmp_path_factory: pytest.TempPathFactory) -> Path:
    """The sync-surface counterpart of `full_package`.

    `generated_tree` already ran `pgn generate` against the full project
    (all artifacts, including `python-sync`), so this reuses that one
    subprocess call rather than invoking pgn again: it just points at the
    sibling `python_sync` artifact directory instead of `python`.
    """
    generated_tree_sync = generated_tree.parent.parent / "artifacts" / "python_sync"
    root = tmp_path_factory.mktemp("pkg-sync")
    shell_src = GOLDEN_DIR_SYNC / "src"
    generated_src = generated_tree_sync / "src"
    _ = shutil.copytree(shell_src, root / "src", ignore=shutil.ignore_patterns("_generated", "__init__.py"))
    for pkg_dir in generated_src.iterdir():
        dest_pkg = root / "src" / pkg_dir.name
        _ = shutil.copytree(pkg_dir / "_generated", dest_pkg / "_generated")
        _ = shutil.copy2(pkg_dir / "__init__.py", dest_pkg / "__init__.py")
    return root
```

Add `GOLDEN_DIR_SYNC` to the existing `from tests._harness import (...)` block at the top of the file:

```python
from tests._harness import (
    FIXTURE_PROJECT,
    GOLDEN_DIR,
    GOLDEN_DIR_SYNC,
    HERE,
    SRC_DIR,
    admin_database_url,
    effective_database_name,
    run_pgn,
)
```

- [ ] **Step 2: Update `tests/test_generated.py`'s module-level constants**

Replace lines 33-39:

```python
# The generator emits the <pkg>/_generated subtree plus the package-root
# __init__.py facade; the rest of the shell (pyproject.toml, py.typed) is
# hand-written and lives in golden as a committed fixture, not produced by
# generate.
GENERATED_SUBTREE = Path("src/specimen_client/_generated")
FACADE_INIT = Path("src/specimen_client/__init__.py")
GENERATED_SUBTREE_SYNC = Path("src/specimen_sync_client/_generated")
FACADE_INIT_SYNC = Path("src/specimen_sync_client/__init__.py")
```

Update the import line to include `GOLDEN_DIR_SYNC`:

```python
from tests._harness import FIXTURE_PROJECT, GOLDEN_DIR, GOLDEN_DIR_SYNC, HERE, ensure_droppable, run_pgn
```

- [ ] **Step 3: Simplify `test_generated_matches_golden`, add its sync counterpart**

Replace the `for facade in (FACADE_INIT, SYNC_FACADE_INIT):` loop (lines 116-118) with a single check:

```python
    if (generated_tree / FACADE_INIT).read_text() != (GOLDEN_DIR / FACADE_INIT).read_text():
        mismatched.append(str(FACADE_INIT))
```

Add a new test after `test_generated_matches_golden`:

```python
def test_generated_sync_matches_golden(generated_tree: Path) -> None:
    """Sync-surface counterpart of test_generated_matches_golden.

    generated_tree points at the "python" artifact; the sync surface's
    output lives in the sibling "python_sync" artifact directory produced by
    the same pgn generate call (see the generated_tree fixture).
    """
    generated_tree_sync = generated_tree.parent.parent / "artifacts" / "python_sync"
    produced_root = generated_tree_sync / GENERATED_SUBTREE_SYNC
    golden_root = GOLDEN_DIR_SYNC / GENERATED_SUBTREE_SYNC

    produced = _relative_files(produced_root)
    golden = _relative_files(golden_root)

    missing = sorted(str(p) for p in golden - produced)
    extra = sorted(str(p) for p in produced - golden)
    assert not missing, f"golden files not produced by the generator: {missing}"
    assert not extra, f"generator emitted files absent from golden: {extra}"

    mismatched: list[str] = []
    for rel in sorted(produced, key=str):
        if (produced_root / rel).read_text() != (golden_root / rel).read_text():
            mismatched.append(str(rel))

    if (generated_tree_sync / FACADE_INIT_SYNC).read_text() != (GOLDEN_DIR_SYNC / FACADE_INIT_SYNC).read_text():
        mismatched.append(str(FACADE_INIT_SYNC))

    assert not mismatched, (
        "generated sync output drifted from golden in: "
        + ", ".join(mismatched)
        + "\nupdate via: mise run golden (see tests/golden_sync/README.md)"
    )
```

- [ ] **Step 4: Add `test_generated_sync_passes_basedpyright_strict`**

Add after `test_generated_passes_basedpyright_strict`:

```python
def test_generated_sync_passes_basedpyright_strict(tmp_path: Path) -> None:
    """basedpyright strict on the full sync-surface golden package."""
    config = tmp_path / "pyrightconfig.json"
    _ = config.write_text(
        json.dumps(
            {
                "pythonVersion": "3.12",
                "typeCheckingMode": "strict",
                "include": [str(GOLDEN_DIR_SYNC / "src")],
                "venvPath": str(HARNESS_ROOT),
                "venv": ".venv",
                "reportMissingModuleSource": False,
            }
        )
    )
    result = subprocess.run(
        ["basedpyright", "--project", str(config), "--outputjson"],
        capture_output=True,
        text=True,
    )

    if not result.stdout.strip():
        pytest.fail(f"basedpyright produced no JSON (exit {result.returncode}):\n{result.stderr}")

    summary = json.loads(result.stdout)["summary"]
    assert summary["filesAnalyzed"] > 0, f"basedpyright analyzed no files; bad include path?\n{result.stdout}"
    assert summary["errorCount"] == 0 and summary["warningCount"] == 0, (
        f"basedpyright strict reported issues: {summary}\n{result.stdout}"
    )
```

- [ ] **Step 5: Delete `test_roundtrip_sync_and_cross_surface_identity`, replace with `test_roundtrip_sync_surface`**

Delete the whole function (lines 392-479 in the original — cross-surface identity is not a meaningful concept once each surface is its own independent generate with its own `_rows.py`/package). Replace with:

```python
def test_roundtrip_sync_surface(full_package_sync: Path, roundtrip_db: str) -> None:
    """The sync surface, generated independently with config.sync = true.

    Drives the generated sync functions (psycopg.Connection, no await) end
    to end, at the same unified paths the async surface uses (no `.sync.`
    sub-path) — this package was generated standalone, not alongside async.
    """
    _apply_migrations(roundtrip_db)
    import_module = _import_client_sync(full_package_sync)

    register = import_module("specimen_sync_client._generated._register")
    mood_mod = import_module("specimen_sync_client._generated.types.mood")
    point_mod = import_module("specimen_sync_client._generated.types.point_2_d")
    insert = import_module("specimen_sync_client._generated.statements.insert_specimen")
    get = import_module("specimen_sync_client._generated.statements.get_specimen")
    by_moods = import_module("specimen_sync_client._generated.statements.list_specimens_by_moods")
    bump = import_module("specimen_sync_client._generated.statements.bump_specimen_revision")

    Mood = mood_mod.Mood
    Point2D = point_mod.Point2D

    conn = psycopg.connect(roundtrip_db, autocommit=True)
    try:
        register.register_types(conn)

        inserted = insert.insert_specimen(
            conn,
            doc_jsonb={"k": "v", "n": 1},
            feeling=Mood.HAPPY,
            origin=Point2D(x=1.5, y=2.5),
            flag=True,
            small=1,
            medium=2,
            large=3,
            ratio=0.5,
            precise=0.25,
            title="alpha",
            code="C-1",
            letter="x",
            born_on=date(2020, 1, 2),
            amount=Decimal("12.34"),
            blob=b"\x00\x01",
            doc_json=[1, 2, 3],
            maybe_text=None,
            maybe_int=None,
            maybe_uuid=None,
            maybe_ts=None,
            maybe_num=None,
            tags=["a", None, "b"],
            related_ids=None,
            grid=None,
            moods=[Mood.HAPPY, None, Mood.SAD],
        )
        assert isinstance(inserted.feeling, Mood)
        assert inserted.feeling is Mood.HAPPY
        assert isinstance(inserted.origin, Point2D)
        assert inserted.doc_jsonb == {"k": "v", "n": 1}
        assert inserted.moods == [Mood.HAPPY, None, Mood.SAD]
        assert inserted.moods is not None
        assert inserted.moods[0] is Mood.HAPPY

        specimen_id = inserted.id
        hit = get.get_specimen(conn, id=specimen_id)
        assert hit is not None
        assert hit.id == specimen_id
        assert get.get_specimen(conn, id=specimen_id + 10_000) is None

        mood_rows = by_moods.list_specimens_by_moods(conn, moods=[Mood.HAPPY])
        assert [r.id for r in mood_rows] == [specimen_id]
        assert by_moods.list_specimens_by_moods(conn, moods=[Mood.SAD]) == []

        affected = bump.bump_specimen_revision(conn, id=specimen_id)
        assert affected == 1
        bumped = get.get_specimen(conn, id=specimen_id)
        assert bumped is not None
        assert bumped.rev == 2
    finally:
        conn.close()
```

Add the `_import_client_sync` helper next to `_import_client` (same shape, different module-name prefix so `sys.modules` cache invalidation targets the right package):

```python
def _import_client_sync(full_package_sync: Path):  # noqa: ANN202 - dynamic module set
    src = str(full_package_sync / "src")
    if src not in sys.path:
        sys.path.insert(0, src)
    for name in list(sys.modules):
        if name == "specimen_sync_client" or name.startswith("specimen_sync_client."):
            del sys.modules[name]
    return importlib.import_module
```

- [ ] **Step 6: Move `test_roundtrip_single_field_composite_sync` onto the sync-only package**

Replace the function body:

```python
def test_roundtrip_single_field_composite_sync(full_package_sync: Path, roundtrip_db: str) -> None:
    """Sync-surface counterpart of test_roundtrip_single_field_composite."""
    _apply_migrations(roundtrip_db)
    import_module = _import_client_sync(full_package_sync)

    register = import_module("specimen_sync_client._generated._register")
    tag_mod = import_module("specimen_sync_client._generated.types.tag_value")
    insert = import_module("specimen_sync_client._generated.statements.insert_tagged_item")
    get = import_module("specimen_sync_client._generated.statements.get_tagged_item")

    TagValue = tag_mod.TagValue

    conn = psycopg.connect(roundtrip_db, autocommit=True)
    try:
        register.register_types(conn)

        inserted = insert.insert_tagged_item(conn, name="widget", tag=TagValue(value="blue"))
        assert isinstance(inserted.tag, TagValue)
        assert inserted.tag == TagValue(value="blue")

        hit = get.get_tagged_item(conn, id=inserted.id)
        assert hit is not None
        assert hit.tag == TagValue(value="blue")
    finally:
        conn.close()
```

- [ ] **Step 7: Run the generated-output test module**

Run: `cd python.gen && mise run test -- tests/test_generated.py -v`
Expected: all tests pass, including the new `test_generated_sync_matches_golden`, `test_generated_sync_passes_basedpyright_strict`, `test_roundtrip_sync_surface`, and `test_roundtrip_single_field_composite_sync`.

- [ ] **Step 8: Commit**

```bash
git add tests/conftest.py tests/test_generated.py
git commit -m "python.gen: split sync-surface tests onto their own golden fixture"
```

---

### Task 6: Fix the config-variant tests' sync-detection signal

**Files:**
- Modify: `tests/test_config_variants.py`

**Interfaces:**
- Consumes: `_generated/_runtime.py` content (Task 2 made `def fetch_many`/`async def fetch_many` the sync/async tell, since there is no more `sync/` subdirectory to check for existence).

- [ ] **Step 1: Rewrite `tests/test_config_variants.py`**

```python
"""Pins pgn's actual YAML->Dhall decode semantics for the Optional Config knobs.

pgn's decode behavior for record types is undocumented, so each artifact in
project1.pgn.yaml drives a different subset of `config` keys through the same
compile.dhall and the assertions below record what pgn 0.6.5 was observed to do,
not a documented contract. These variants are pinned by the directory/package
name and which surface (sync or async) they produce, not a full golden tree.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    os.environ.get("HARNESS_CI_REDUCED") == "1",
    reason=(
        "variant decode semantics are pinned locally; CI runs the reduced "
        "single-artifact project because pgn generate of all 7 artifacts "
        "exhausts GitHub-hosted runner memory"
    ),
)


def _artifact_src(generated_tree: Path, artifact_key: str) -> Path:
    # generated_tree is <project>/artifacts/python; artifact directories are
    # named after the artifact key with "-" replaced by "_" (pgn's own doing,
    # independent of the Dhall config below).
    project_root = generated_tree.parent.parent
    artifact_dir = artifact_key.replace("-", "_")
    return project_root / "artifacts" / artifact_dir / "src"


def _package_dir(generated_tree: Path, artifact_key: str) -> Path:
    src = _artifact_src(generated_tree, artifact_key)
    packages = [p for p in src.iterdir() if p.is_dir()]
    assert len(packages) == 1, f"expected exactly one package under {src}, found {packages}"
    return packages[0]


def _is_sync(package: Path) -> bool:
    """Whether the generated package's runtime module is the sync surface.

    There is no `sync/` subdirectory to check anymore (config.sync selects
    which content is rendered at the *same* `_runtime.py` path); the async
    body defines `async def fetch_many`, the sync body defines `def
    fetch_many` with no `async`.
    """
    runtime = (package / "_generated" / "_runtime.py").read_text()
    return "async def fetch_many" not in runtime


def test_name_only_config_derives_package_and_defaults_sync_off(generated_tree: Path) -> None:
    package = _package_dir(generated_tree, "python-name-only")
    assert package.name == "name_only_client"
    assert not _is_sync(package)


def test_sync_only_config_defaults_package_name_from_project(generated_tree: Path) -> None:
    package = _package_dir(generated_tree, "python-sync-only")
    assert package.name == "fixture"
    assert _is_sync(package)


def test_empty_config_object_defaults_both_fields(generated_tree: Path) -> None:
    package = _package_dir(generated_tree, "python-empty")
    assert package.name == "fixture"
    assert not _is_sync(package)


def test_absent_config_key_defaults_both_fields(generated_tree: Path) -> None:
    """No `config:` key at all decodes the same as `config: {}` (None Config)."""
    package = _package_dir(generated_tree, "python-bare")
    assert package.name == "fixture"
    assert not _is_sync(package)


def test_unknown_config_key_is_ignored_not_rejected(generated_tree: Path) -> None:
    """An extra key not in the generator's Config type (bogusField) does not fail generation."""
    package = _package_dir(generated_tree, "python-unknown-key")
    assert package.name == "unknown_key_client"
    assert not _is_sync(package)


def test_null_value_decodes_as_absent_field(generated_tree: Path) -> None:
    """`sync: null` decodes to None, same as omitting the key (default False)."""
    package = _package_dir(generated_tree, "python-null")
    assert package.name == "null_client"
    assert not _is_sync(package)
```

- [ ] **Step 2: Run the config-variant tests**

Run: `cd python.gen && mise run test -- tests/test_config_variants.py -v`
Expected: all six tests pass (unless `HARNESS_CI_REDUCED=1` is set locally, in which case they skip — matches existing behavior).

- [ ] **Step 3: Commit**

```bash
git add tests/test_config_variants.py
git commit -m "python.gen: fix config-variant sync detection for unified output paths"
```

---

### Task 7: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `DESIGN.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Update `README.md`'s config reference table**

Replace the table at lines 76-80:

```markdown
| key             | type               | default                        |
| --------------- | ------------------ | ------------------------------ |
| `packageName`   | `Text`              | the project name, kebab-cased  |
| `sync`          | `Bool`              | `False`                         |
| `onUnsupported` | `"Fail" \| "Skip"`  | `"Fail"`                        |
```

- [ ] **Step 2: Update the quickstart example (lines 36-42)**

```yaml
artifacts:
  python:
    gen: https://raw.githubusercontent.com/slavashvets/python.gen/master/src/package.dhall
    config:
      packageName: my-db-client
      sync: true
```

- [ ] **Step 3: Update "Key features" (line 21-23)**

```markdown
- **Async or sync client over psycopg 3.** `config.sync` (default `False`)
  picks exactly one surface — the async client (`psycopg.AsyncConnection`) or
  the sync one (`psycopg.Connection`) — at the same output paths either way;
  install `psycopg[binary]` for the fast C implementation.
```

- [ ] **Step 4: Update "Using the generated code" (lines 220-240)**

Replace the closing paragraph and code block:

```markdown
## Using the generated code

Import from the flat facade, not from `_generated` directly:

```python
from my_db_client import get_specimen, GetSpecimenRow, Mood
```

The facade re-exports every Row dataclass, every enum/composite, and every
statement function with `X as X` markers and a matching `__all__`. If the
project has composites or enums, call `register_types(conn)` once per
connection before relying on native composite decode or enum-array results;
scalar enums do not need it.

With `sync: true`, the entire client is generated against
`psycopg.Connection` instead — same import path, same facade shape, only the
function signatures and I/O become synchronous:

```python
from my_db_client import get_specimen, GetSpecimenRow, Mood

def handler(conn):
    row = get_specimen(conn, id=42)
```

A project that needs both an async backend and a sync consumer (e.g. a
Dagster pipeline) generates two artifacts pointed at this same `gen:`, one
with `sync: true` and one without, each with its own `packageName` — not one
artifact with both surfaces bundled together.
```

- [ ] **Step 5: Update `DESIGN.md` sections describing the surface mechanism**

Rewrite the "What the generator emits" / "What the generator adds when `emitSync`" split (roughly lines 43-71) into a single section describing unconditional, surface-selected emission:

```markdown
### What the generator emits

```
src/<pkg>/__init__.py                       # generated facade (re-exports everything)
src/<pkg>/_generated/__init__.py
src/<pkg>/_generated/_core.py               # surface-agnostic: JsonValue, NoRowError, require_array
src/<pkg>/_generated/_runtime.py            # I/O helpers for whichever surface config.sync picked
src/<pkg>/_generated/_register.py           # only if composites or enums
src/<pkg>/_generated/_rows.py               # shared Row dataclasses + decode functions
src/<pkg>/_generated/statements/__init__.py
src/<pkg>/_generated/statements/<query_snake>.py   # one thin wrapper per query, def or async def
src/<pkg>/_generated/types/__init__.py      # only if custom types exist
src/<pkg>/_generated/types/<type_snake>.py
```

Exactly one surface is emitted per generate, picked by `config.sync`
(`False`, the default, emits async; `True` emits sync) — the tree shape and
every import path are identical either way; only the statement modules'
`def`/`async def`, `Connection`/`AsyncConnection`, and `_runtime.py`'s body
change. A project that needs both surfaces generates two artifacts against
this same `gen:` with different `packageName`s, one with `sync: true` and
one without.
```

Rewrite the "Surface mechanism" section (roughly lines 192-217) to drop the "emits both, gated by config.emitSync" framing:

```markdown
## 4. Surface mechanism (async / sync)

```dhall
{ defKeyword : Text   -- "async def" | "def"
, connType   : Text   -- "AsyncConnection" | "Connection"
, awaitKw    : Text   -- "await " | ""
, rowsImport : Text   -- ".._rows" (same depth for both surfaces)
, corePrefix : Text   -- ".._core" (same depth for both surfaces)
, typesPrefix : Text  -- "..types" (same depth for both surfaces)
}
```

`Surface.async` and `Surface.sync` are the two values. `Interpreters/
Project.dhall` picks one — `if config.sync then Surface.sync else
Surface.async` — and threads it through a single render pass:
`Interpreters/Query.dhall` calls the statement-module template once per
query (not twice), and `Interpreters/Project.dhall` picks the matching
`_runtime.py` body and, when custom types exist, the matching `_register.py`
body. `_rows.py` and `types/` are surface-agnostic and always render exactly
once, so switching `config.sync` costs only the thin I/O wrappers.
```

Update the facade section (roughly lines 400-409) to remove the two-facade description:

```markdown
- every statement function from `_generated/statements/<fn>`.

The facade lives at `<pkg>/__init__.py` (prefix `._generated`, statements
under `statements`) regardless of which surface `config.sync` selected.
```

Update the Config-flow section's example (roughly lines 427-429, 503-509) to use `sync` in place of `emitSync`, matching Task 1/2's rename, e.g.:

```dhall
let Config = { packageName : Optional Text, sync : Optional Bool, onUnsupported : Optional OnUnsupported.Mode }

let Config/default = { packageName = None Text, sync = None Bool, onUnsupported = None OnUnsupported.Mode }
```

And the prose right below the second code block (roughly lines 500-514, "### Config flow"): replace every `emitSync` with `sync`, and `` `emitSync` to `False` `` with `` `sync` to `False` ``.

Also update the "Generator decomposition" file-tree block (roughly lines 450-480): `Structures/Surface.dhall`'s comment changes from "async/sync token table (section 4)" to "async/sync token table, both surfaces at the same import depth (section 4)"; `Interpreters/Query.dhall`'s comment changes from "assemble one query: shared rowDef + async/sync statement modules" to "assemble one query: shared rowDef + one statement module for whichever surface config.sync picked".

- [ ] **Step 6: Add a `CHANGELOG.md` "Upcoming" entry**

Add to the top of the `# Upcoming` section:

```markdown
- **Breaking:** `emitSync` is gone. In its place, `sync : Optional Bool`
  (default `False`) picks exactly one surface per generate — async or sync —
  emitted at the same unified paths either way (no more `sync/` subdirectory,
  no more second package-root facade). Previously `emitSync: true` added a
  second, nested sync tree alongside the always-emitted async one; a project
  that needs both surfaces now generates two artifacts against this same
  `gen:` with different `packageName`s, one with `sync: true` and one
  without. See `docs/plans/2026-07-12-configurable-sync-output.md` for the
  full rationale and migration shape. `tests/golden_sync/` is a new committed
  golden fixture (`specimen_sync_client`) exercising the sync surface
  end-to-end (basedpyright strict + round-trip), alongside the existing
  `tests/golden/` (`specimen_client`, now async-only).
```

- [ ] **Step 7: Commit**

```bash
git add README.md DESIGN.md CHANGELOG.md
git commit -m "python.gen: document the exclusive sync/async config change"
```

---

### Task 8: Full verification pass

**Files:** none (verification only).

- [ ] **Step 1: Run the full harness**

Run: `cd python.gen && mise run test`
Expected: all tests pass (allow ~10 minutes; most of it is pgn's own type inference against Postgres).

- [ ] **Step 2: Confirm no stray `emitSync` references anywhere in the repo**

Run: `cd python.gen && grep -rn "emitSync" . --include="*.dhall" --include="*.md" --include="*.py" --include="*.yaml" --include="*.toml" | grep -v "^CHANGELOG.md:"`
Expected: no output (the `CHANGELOG.md` exclusion is because older, already-shipped entries legitimately still mention the old field name as history — only today's new entry from Task 7 should be free of it going forward, and that new entry doesn't mention `emitSync` at all so the grep with the exclusion is really just a safety margin, not an expected hit).

- [ ] **Step 3: Confirm both golden trees are internally consistent with the new fixture config**

Run: `cd python.gen && git status --short tests/golden tests/golden_sync`
Expected: clean (everything from Task 4's regeneration already committed).

- [ ] **Step 4: Manually skim one generated statement file from each surface**

Run: `head -30 tests/golden/src/specimen_client/_generated/statements/get_specimen.py tests/golden_sync/src/specimen_sync_client/_generated/statements/get_specimen.py`
Expected: the async file shows `from psycopg import AsyncConnection` and `async def get_specimen(...)`; the sync file shows `from psycopg import Connection` and `def get_specimen(...)` (no `async`), both importing from `.._rows`/`.._core` (not `..._rows`/`..._core`) — confirming Task 2's depth collapse took effect.
