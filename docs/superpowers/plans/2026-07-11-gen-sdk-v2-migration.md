# python.gen: migrate to gen-contract v4.0.1 / gen-sdk v2.0.0, adopt architecture layout

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `python.gen` up to the same structural shape as `java.gen`'s
last release (`v1.1.0`): pin `gen-contract`/`gen-sdk` directly (no bundled
SDK), adopt `Sdk.Sigs` in place of the local `Algebras/` folder, and move to
the `src/`-rooted repo layout the normative architecture doc describes — with
**zero change to generated output**.

**Architecture:** Reference is
`gen-sdk/docs/generator-architecture.md` (already read in full) and
`java.gen`'s current `master` (tag `v1.1.0`, commit `658508c`). `python.gen`
is currently on pre-split `gen-sdk v0.11.0` (no `Sigs`, bundles `Project`
itself) with a hand-rolled `gen/Algebras/{Interpreter,Template}.dhall`, a
`gen/Deps/package.dhall` barrel, and the old `gen/` + `tests/Exhaustive.dhall`
layout — i.e. it has never done *any* of the steps `java.gen` went through
(`gen-migration-plan.md` at the pgenie repo root covers `rust.gen`/`haskell.gen`,
which already had `Sigs`; it does not cover `python.gen` at all). This plan
folds all of `java.gen`'s historical steps into one destination state, since
there is no reason to recreate `java.gen`'s intermediate commits.

**Tech Stack:** Dhall (fork `pgn`'s dhall, package name `dhll`, needed for the
`Text/equal` builtin and `as Source` import mode — see Global Constraints),
Python 3.12 / `uv` / `pytest` for the harness, `mise` for tool pinning.

## Global Constraints

- **No behavior change.** This is a dependency/layout migration, not a
  feature change. If `demos/Exhaustive.dhall` (see Task 5) produces different
  file paths or content than `tests/Exhaustive.dhall` did before the move,
  that is a bug in the migration, not an expected diff.
- **Do not touch interpreter algorithms.** `Interpreters/Project.dhall`'s
  `Skip`/`Fail` logic (`typeSucceeds`/`queryChecks`/`effectiveQueries`) is
  deliberately hand-rolled instead of using `Typeclasses.Classes.Alternative`
  the way `java.gen` does, per an explicit in-file comment: multiple
  `QueryGen.run`/`CustomTypeGen.run` call sites for the same query measurably
  multiplied Dhall normalization time (seconds → minutes), confirmed by wall-time
  bisection. This is orthogonal to the Deps/Sigs migration — leave it as is.
  Do **not** add `src/Deps/Typeclasses.dhall` since nothing will use it.
- **`Interpreters/Member.dhall` and `Interpreters/ParamsMember.dhall` keep
  their 3-argument `Run` type** (`Config -> CustomKind.Lookup -> Input ->
  Compiled Output`) instead of conforming to `Sdk.Sigs.interpreter`'s fixed
  2-argument shape (`Config -> Input -> Result`). `java.gen`'s own
  `Member.dhall` doesn't need a lookup table; `python.gen`'s does (custom-type
  name resolution — see the `buildLookup`/`IndexedCustomType` comments in
  `Interpreters/Project.dhall`). Bundling `Lookup` into `Config` or `Input`
  to force-fit the Sig is a bigger, separate refactor — out of scope here.
  These two files get the Deps-import and `Algebra.Config` → local `Config`
  changes (Task 2) but keep their existing bare `{ Input, Output, Run, run }`
  export, not `Sdk.Sigs.interpreter Config Input Output run`.
- **Config narrowing is deferred.** The architecture doc's ideal is each
  interpreter declaring only the `Config` fields it (and its children) needs.
  `java.gen` does this trivially (`{ useOptional : Bool }` everywhere, since
  that's its whole config). `python.gen`'s config has 4 fields
  (`packageName`, `importName`, `emitSync`, `onUnsupported`); auditing exactly
  which fields each of the 11 interpreters actually reads and narrowing each
  is real, separate work with real risk of missing a field some deeply nested
  path needs. This plan keeps the **same 4-field `Config` record, declared
  locally and verbatim in each interpreter module** (no more shared
  `Algebra.Config` alias) — this satisfies "`Config` is a parameter each
  module declares itself," just not narrowed. Note it as a follow-up, don't
  do it now.
- **Local verification gap.** This sandbox has a global `dhall`/`pgn` (cabal
  build, `dhll-1.42.3`) that is **not** the `mise`-pinned `pgn v0.9.1` this
  repo's CI/tests actually use — a plain `dhall type --file tests/Exhaustive.dhall`
  here fails on the *pre-migration* tree already, with an `as Source`
  hash-integrity mismatch on `gen/Deps/Sdk.dhall` (confirmed during planning:
  expected `8d43544e...`, actual `573b4655...`). This is a toolchain mismatch,
  not evidence of a real problem. **Whoever executes this plan must run
  verification through `mise x -- dhall ...` / `mise x -- pgn ...` / `mise x
  -- uv run pytest`**, matching `mise.toml`'s pin, not a bare global `dhall`.
  If `mise` isn't available in the execution environment either, at minimum
  run `dhall format --transitive` (syntax-only, tool-version-agnostic) and
  flag that deeper verification (`dhall type`, fixture diff, pytest,
  basedpyright) still needs to happen on a properly provisioned machine/CI
  before this is considered done.

---

## File Structure

```
src/                              (was gen/)
  package.dhall                   (was Gen.dhall — now built via Sdk.Sigs.generator)
  Config.dhall                    (unchanged content, moved)
  Interpret.dhall                 (was compile.dhall — Config no longer Optional at top)
  Deps/
    Contract.dhall                (NEW — gen-contract v4.0.1 pin)
    Sdk.dhall                     (bumped gen-sdk v0.11.0 → v2.0.0)
    Lude.dhall                    (unchanged content, moved)
    Prelude.dhall                 (unchanged content, moved)
    (package.dhall barrel REMOVED)
  Interpreters/                   (11 files: Deps.Sdk.Project → Deps.Contract, Algebra → Sdk.Sigs)
  Templates/                      (10 files: Algebra → Sdk.Sigs; 7 also de-barrel Deps)
  Structures/                     (CustomKind.dhall: Deps.Sdk.Project → Deps.Contract; others untouched)
  (Algebras/ REMOVED)
demos/
  Exhaustive.dhall                (was tests/Exhaustive.dhall — rewritten for Sdk.Output.toFileMap)
tests/                            (Python pytest harness — unchanged except any gen/-path references)
.github/workflows/{ci,release}.yml, .github/scripts/build-contract-shell.sh,
README.md, AGENTS.md, DESIGN.md, build.bash, bench/*.sh, mise.toml
                                   (path references updated: gen/ → src/, tests/Exhaustive.dhall → demos/Exhaustive.dhall)
```

---

### Task 1: Add the new Deps pins and remove the `Deps/package.dhall` barrel

**Files:**
- Create: `gen/Deps/Contract.dhall`
- Modify: `gen/Deps/Sdk.dhall`
- Delete: `gen/Deps/package.dhall`
- Modify (de-barrel): every file that currently has `let Deps = ../Deps/package.dhall` (see the full list in Tasks 2–3 — do this as part of those tasks, not twice)

This task only stages the new pins; Task 2 is where the fallout (broken
`Sdk.Project`/`Sdk.Fixtures` references, `Algebras/` removal) gets fixed. Do
not try to get `dhall type` green after this task alone — it won't be, and
that's expected (same as `gen-migration-plan.md`'s phase-0 commit 2 for
`java.gen`). Fold Task 1 and Task 2 into one commit if you'd rather not carry
a known-broken intermediate state.

- [ ] **Step 1: Create `gen/Deps/Contract.dhall`** — the exact pin `java.gen`
  and `gen-sdk` itself use:

```dhall
https://raw.githubusercontent.com/pgenie-io/gen-contract/v4.0.1/src/package.dhall
  sha256:4a130ba7fbaa152a776babbb1bf2994a4833931ca76bde9bf6930d354225651e
```

- [ ] **Step 2: Bump `gen/Deps/Sdk.dhall`** to `gen-sdk v2.0.0` (same pin
  `java.gen`'s `src/Deps/Sdk.dhall` uses). Preserve the existing `as Source`
  import mode (see `AGENTS.md`/CI comments on why `python.gen` uses it —
  `java.gen` doesn't, but that's an intentional `python.gen`-specific RAM
  optimization, not something this migration should undo):

```dhall
https://raw.githubusercontent.com/pgenie-io/gen-sdk/v2.0.0/src/package.dhall
  sha256:b9def6ab1179bc4aaae7fc6e91977f094f75934cd5755175c294a9e97ca71b15
  as Source
```

  If keeping `as Source` here, its hash is a *source*-text hash, not the
  semantic hash above copied from `java.gen` (which imports plainly). Verify
  with `dhall hash` against the raw URL using the repo's pinned toolchain
  (`mise x -- dhall hash <<< 'https://raw.githubusercontent.com/pgenie-io/gen-sdk/v2.0.0/src/package.dhall as Source'`
  or equivalent) before trusting the semantic hash verbatim in `as Source`
  mode — don't guess.

- [ ] **Step 3: Delete `gen/Deps/package.dhall`.**

- [ ] **Step 4: Commit** (or fold into Task 2's commit).

---

### Task 2: Rewire `Structures/CustomKind.dhall` and all 11 `Interpreters/*.dhall`

**Files:**
- Modify: `gen/Structures/CustomKind.dhall`
- Modify: `gen/Interpreters/{CustomType,Member,ParamsMember,Primitive,Project,Query,QueryFragments,Result,ResultColumns,Scalar,Value}.dhall`
- Delete: `gen/Algebras/` (all three files)

**The mechanical recipe, applied to every file above:**

1. Replace `let Deps = ../Deps/package.dhall` with direct imports of exactly
   what the file uses. Every one of these files uses `Deps.Sdk.Project`
   (→ becomes a direct `Deps/Contract.dhall` import) and `Deps.Lude`/`Deps.Prelude`
   (→ direct imports). Concretely, replace:
   ```dhall
   let Deps = ../Deps/package.dhall
   ```
   with (only the lines this particular file actually needs — check with
   `grep -n 'Deps\.' <file>` first):
   ```dhall
   let Lude = ../Deps/Lude.dhall

   let Prelude = ../Deps/Prelude.dhall

   let Model = ../Deps/Contract.dhall
   ```
   and change every remaining `Deps.Lude` → `Lude`, `Deps.Prelude` → `Prelude`
   in the body. `QueryFragments.dhall` additionally has an unused
   `let Sdk = Deps.Sdk` line (line 7) — drop it, nothing in the file
   references the `Sdk` binding.

2. Replace the line `let Model = Deps.Sdk.Project` (now redundant with step
   1's `Model` binding) — don't duplicate it, step 1 already introduces
   `Model` pointed at `Deps/Contract.dhall`.

3. Delete `let Algebra = ../Algebras/Interpreter.dhall`.

4. Add a local `Config` type declaration (same 4 fields everywhere per the
   Global Constraints note on deferred narrowing):
   ```dhall
   let Config =
         { packageName : Text
         , importName : Text
         , emitSync : Bool
         , onUnsupported : OnUnsupported.Mode
         }
   ```
   This needs `OnUnsupported = ../Structures/OnUnsupported.dhall` imported in
   any file that doesn't already import it (check first — `Project.dhall`
   already does).

5. Change every `\(config : Algebra.Config) ->` to `\(config : Config) ->`.

6. Change the tail:
   - **10 of the 11 files** (`CustomType`, `Primitive`, `Project`, `Query`,
     `QueryFragments`, `Result`, `ResultColumns`, `Scalar`, `Value` — 9 files,
     not 10; `Member`/`ParamsMember` are the exception below) end with
     `Algebra.module Input Output run` (or, for `Scalar.dhall`,
     `Algebra.module Input Output run /\ { ScalarDecode }`). Change to:
     ```dhall
     Sdk.Sigs.interpreter Config Input Output run
     ```
     (`Scalar.dhall`: `Sdk.Sigs.interpreter Config Input Output run /\ { ScalarDecode }`),
     which needs `let Sdk = ../Deps/Sdk.dhall` imported (it isn't currently,
     since `Deps.Sdk.Project` used to come through the barrel — add it).
   - **`Member.dhall` and `ParamsMember.dhall`** keep their existing tail
     verbatim: `in { Input, Output, Run, run }`, just with `Algebra.Config` →
     `Config` in the `Run` type alias line
     (`let Run = Config -> CustomKind.Lookup -> Input -> Lude.Compiled.Type Output`).
     No `Sdk.Sigs.interpreter` here — see Global Constraints.

7. `Interpreters/Project.dhall` specifically: its two `\(config : Algebra.Config) ->`
   occurrences (the `combineOutputs` and `run` functions) both become
   `\(config : Config) ->`; its `lookupConfig : Algebra.Config` type
   annotation (used to type-check `Value.run` calls for composite-field
   rendering) becomes `lookupConfig : Config`. No other logic in this file
   changes — the `Skip`/`Fail` machinery is untouched per Global Constraints.

- [ ] **Step 1: Apply the recipe to all 11 `Interpreters/*.dhall` files and `Structures/CustomKind.dhall`.**
- [ ] **Step 2: Delete `gen/Algebras/`.**
- [ ] **Step 3: Verify** (with the `mise`-pinned toolchain, not the bare local `dhall` — see Global Constraints):
  ```bash
  mise x -- dhall type --file gen/Interpreters/Project.dhall
  ```
  Expected: prints the interpreter's type (a record with `Input`, `Output`,
  `Result`, `Run`, `run` fields) with no error. This alone pulls in every
  other `Interpreters/*.dhall` transitively, so it's a full check of this task.
- [ ] **Step 4: Commit.**

---

### Task 3: Rewire the 10 `Templates/*.dhall` files

**Files:**
- Modify: `gen/Templates/{CompositeModule,CoreModule,EnumModule,FacadeModule,InitModule,RegisterModule,RowsModule,RuntimeModule,StatementModule,TypesInit}.dhall`

**Recipe:**

1. `CoreModule.dhall`, `InitModule.dhall`, `RuntimeModule.dhall` don't import
   `Deps` at all (no `Prelude`/`Lude` need) — only change: drop
   `let Algebra = ../Algebras/Template.dhall`, add `let Sdk = ../Deps/Sdk.dhall`,
   and change the tail. `CoreModule`/`RuntimeModule` end with
   `Algebra.module {} (\(_ : {}) -> content)` → `Sdk.Sigs.template {} (\(_ : {}) -> content)`.
   `InitModule` ends with `Algebra.module Params render` →
   `Sdk.Sigs.template Params render`.

2. The other 7 (`CompositeModule`, `EnumModule`, `FacadeModule`,
   `RegisterModule`, `RowsModule`, `StatementModule`, `TypesInit`) currently
   have `let Deps = ../Deps/package.dhall`, and only ever use
   `Deps.Prelude.*` (all seven) and, additionally, `Deps.Lude.Text.indentNonEmpty`
   (`RowsModule`, `StatementModule` only — confirmed by
   `grep -n 'Deps\.' gen/Templates/*.dhall` during planning). Replace the
   barrel import with:
   ```dhall
   let Prelude = ../Deps/Prelude.dhall
   ```
   adding `let Lude = ../Deps/Lude.dhall` only in `RowsModule.dhall` and
   `StatementModule.dhall`. Then replace `Deps.Prelude.` → `Prelude.` and
   `Deps.Lude.` → `Lude.` throughout each file's body. Drop
   `let Algebra = ../Algebras/Template.dhall`, add `let Sdk = ../Deps/Sdk.dhall`.

3. Tails for these 7: `Algebra.module Params run` →
   `Sdk.Sigs.template Params run` (`FacadeModule`, `RegisterModule`,
   `StatementModule`); with a combined record for the other 4:
   `Algebra.module Params run /\ { Field }` (`CompositeModule`) →
   `Sdk.Sigs.template Params run /\ { Field }`; `/\ { Variant }` (`EnumModule`);
   `/\ { StatementExport, TypeExport }` (`FacadeModule` — check which of
   `FacadeModule`/others actually has this combinator vs a plain
   `Algebra.module Params run`, per the earlier grep output, before editing —
   don't assume, re-`grep -n 'Algebra.module' gen/Templates/*.dhall` and
   match each file's exact current tail); `/\ { RowDef }` (`RowsModule`);
   `/\ { Export }` (`TypesInit`).

- [ ] **Step 1: Apply the recipe to all 10 files.**
- [ ] **Step 2: Verify:**
  ```bash
  mise x -- dhall type --file gen/Interpreters/Project.dhall
  ```
  (Templates are only reachable transitively through `Interpreters/Project.dhall`
  and its children, same as Task 2 — this single check covers both tasks once
  both are done. If running Task 2 and 3 as separate commits, this step will
  fail after Task 2 alone if any interpreter references a not-yet-updated
  template's old shape; if so, do Tasks 2 and 3 as one commit instead.)
- [ ] **Step 3: Commit.**

---

### Task 4: Rewrite the root entry point (`Config.dhall`, `compile.dhall` → `Interpret.dhall`, `Gen.dhall` → `package.dhall`)

**Files:**
- Modify (move, content unchanged): `gen/Config.dhall`
- Modify (move + rewrite): `gen/compile.dhall` → `gen/Interpret.dhall`
- Modify (move + rewrite): `gen/Gen.dhall` → `gen/package.dhall`

(Paths shown as `gen/...` here since Task 5 does the `gen/` → `src/` directory
move; do this task first, in place, then Task 5 is a pure `git mv` sweep with
no further content changes.)

**Interfaces:**
- Consumes: `Interpreters/Project.dhall`'s `run` (produced by Task 2,
  now `Sdk.Sigs.interpreter`-shaped: `.run : Config -> Contract.Project -> Compiled Output`).
- Produces: `package.dhall`'s `Sdk.Sigs.generator`-built value
  (`{ contractVersion, Config, compile }`), consumed by Task 5's
  `demos/Exhaustive.dhall` and by any pGenie project's `artifacts.<name>.gen` URL.

`Sdk.Sigs.generator`'s shape (from the architecture doc):
```dhall
\(Config : Type) ->
\(defaultConfig : Config) ->
\(interpret : Config -> Contract.Project -> Contract.Output) ->
  let compile = \(config : Optional Config) ->
        merge { None = interpret defaultConfig, Some = interpret } config
  in  Contract.module Config compile
```
Note `interpret` takes a **bare** `Config`, not `Optional Config` — the outer
"config block omitted entirely" case is handled once, by substituting
`defaultConfig`, not by `interpret` itself. `python.gen`'s current
`compile.dhall` handles *two* levels of optionality (the whole block, and
each field within it) with a doubled `Prelude.Optional.fold`. Only the outer
level goes away; each field inside `Config` stays individually `Optional` (so
a project can supply `emitSync: true` alone and still get default
`packageName`/`onUnsupported`) — that per-field defaulting is
`python.gen`-specific richness `java.gen` doesn't have (its `Config` has one
non-Optional `Bool` field), and this migration must not lose it.

- [ ] **Step 1: `gen/Config.dhall`** — content unchanged, just confirm it
  still reads (no edits needed here; listed for completeness since Task 5
  moves the file).

- [ ] **Step 2: Rewrite `gen/compile.dhall` as `gen/Interpret.dhall`** —
  drop the outer `Optional Config` unwrap (the two outermost
  `Prelude.Optional.fold Config config Text (\(c : Config) -> ...)` /
  `... Bool ...` / `... OnUnsupported.Mode ...` wrappers), keep everything
  else (the per-field defaults, `importName` derivation) as is:

```dhall
let Deps = ./Deps/package.dhall

-- NOTE: Task 5 changes this to ./Deps/Contract.dhall / ./Deps/Prelude.dhall
-- directly once the Deps barrel is gone (Task 1) — write it that way now,
-- don't reintroduce the barrel:
let Contract = ./Deps/Contract.dhall

let Prelude = ./Deps/Prelude.dhall

let Config = ./Config.dhall

let OnUnsupported = ./Structures/OnUnsupported.dhall

let ProjectInterpreter = ./Interpreters/Project.dhall

-- Entry point handed to gen-sdk's Sdk.Sigs.generator as `interpret`. Each
-- field of Config is independently Optional, so a project may omit the
-- whole config block (Sdk.Sigs.generator substitutes an all-None
-- defaultConfig, see package.dhall) or any subset of its keys; `defaults`
-- collects every fallback in one place (packageName from the project name in
-- kebab case, emitSync off, onUnsupported Fail). The async surface is always
-- emitted; emitSync adds the sync mirror.
in  \(config : Config) ->
    \(project : Contract.Project) ->
      let defaults =
            { packageName = project.name.inKebabCase
            , emitSync = False
            , onUnsupported = OnUnsupported.Mode.Fail
            }

      let packageName =
            Prelude.Optional.fold
              Text
              config.packageName
              Text
              (\(t : Text) -> t)
              defaults.packageName

      let emitSync =
            Prelude.Optional.fold
              Bool
              config.emitSync
              Bool
              (\(b : Bool) -> b)
              defaults.emitSync

      let onUnsupported =
            Prelude.Optional.fold
              OnUnsupported.Mode
              config.onUnsupported
              OnUnsupported.Mode
              (\(m : OnUnsupported.Mode) -> m)
              defaults.onUnsupported

      let importName = Prelude.Text.replace "-" "_" packageName

      let interpreterConfig = { packageName, importName, emitSync, onUnsupported }

      in  ProjectInterpreter.run interpreterConfig project
```

- [ ] **Step 3: Rewrite `gen/Gen.dhall` as `gen/package.dhall`:**

```dhall
let Sdk = ./Deps/Sdk.dhall

let OnUnsupported = ./Structures/OnUnsupported.dhall

let Config = ./Config.dhall

let Config/default
    : Config
    = { packageName = None Text
      , emitSync = None Bool
      , onUnsupported = None OnUnsupported.Mode
      }

let interpret = ./Interpret.dhall

in  Sdk.Sigs.generator Config Config/default interpret
```

- [ ] **Step 4: Verify:**
  ```bash
  mise x -- dhall type --file gen/package.dhall
  ```
  Expected type: a record with `contractVersion`, `Config`, `compile` fields
  (`compile : Optional Config -> Contract.Project -> Contract.Output`).
- [ ] **Step 5: Commit.**

---

### Task 5: Move `gen/` → `src/`, `tests/Exhaustive.dhall` → `demos/Exhaustive.dhall`

**Files:**
- Move: `gen/` → `src/` (whole tree, `git mv`)
- Move + rewrite: `tests/Exhaustive.dhall` → `demos/Exhaustive.dhall`

- [ ] **Step 1:**
  ```bash
  git mv gen src
  mkdir -p demos
  git mv tests/Exhaustive.dhall demos/Exhaustive.dhall
  ```
  All the `../Deps/...`, `./Interpreters/...`, `../Templates/...` style
  relative imports inside `src/` are untouched by this move (they're relative
  to their own file, not to the repo root), so no content changes are needed
  inside `src/` itself from the move alone.

- [ ] **Step 2: Rewrite `demos/Exhaustive.dhall`.** Its old body called
  `Gen.compileToFileMap config project` — `Sdk.Sigs.generator`-built modules
  don't have a `compileToFileMap` field (per the architecture doc: "there is
  no `compileToFileMap` on the module — turning an `Output` into files is the
  caller's job, via `Sdk.Output.toFileMap`"). New content:

```dhall
-- Applies this generator to gen-sdk's shared cross-backend fixture project
-- (the same "music_catalogue" project java.gen's own demos/Exhaustive.dhall
-- exercises), so a Python client compiles from it and passes basedpyright
-- strict. Pinned directly at gen-sdk's package.dhall, separately from
-- src/Deps/Sdk.dhall: that file only imports gen-sdk's `package.dhall` `as
-- Source` for RAM, and this fixture load doesn't need that mode.
--
-- The fixture project deliberately covers PG types this generator does not
-- support (box, inet, money, ranges, ...), so onUnsupported is set to Skip:
-- those statements/types are dropped with a warning instead of aborting the
-- whole compile.
--
-- Intended to be executed with:
--
-- ```bash
-- dhall to-directory-tree --file demos/Exhaustive.dhall --output <dir> --allow-path-separators
-- ```
let Sdk = ../src/Deps/Sdk.dhall

let Gen = ../src/package.dhall

let OnUnsupported = ../src/Structures/OnUnsupported.dhall

let project = Sdk.Fixtures.Exhaustive

let config =
      Some
        { packageName = None Text
        , emitSync = Some True
        , onUnsupported = Some OnUnsupported.Mode.Skip
        }

in  Sdk.Output.toFileMap (Gen.compile config project)
```

- [ ] **Step 3: Verify:**
  ```bash
  mise x -- dhall type --file demos/Exhaustive.dhall
  ```
  Expected: `List { mapKey : Text, mapValue : Text }` (or however this
  fork/version of Dhall renders `Prelude.Map.Type Text Text`), no error.
- [ ] **Step 4: Commit.**

---

### Task 6: Update every external reference to the old paths

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `.github/scripts/build-contract-shell.sh`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `DESIGN.md`
- Modify: `build.bash`
- Modify: `bench/generate.sh`, `bench/as-source.sh`
- Modify: `mise.toml` (the `golden` task)

**Path substitutions to apply everywhere they occur** (verify each hit with
`grep -rn` first — don't blind-sed across the whole repo, `tests/golden/`
contains generated Python that must NOT be touched):

| Old | New |
|---|---|
| `gen/Gen.dhall` | `src/package.dhall` |
| `gen/Deps/*.dhall` | `src/Deps/*.dhall` |
| `tests/Exhaustive.dhall` | `demos/Exhaustive.dhall` |
| `gen/` (prose/dir references) | `src/` |

Specific known hits (from `grep -rn "gen/Gen\.dhall\|gen/Deps\|tests/Exhaustive"`
run during planning):

- `.github/workflows/ci.yml`: the `contract` job's "Strip `as Source`..."
  step does `sed -i ... gen/Deps/*.dhall` → `src/Deps/*.dhall`; the
  "Generate output from Dhall" step's `dhall_file: tests/Exhaustive.dhall` →
  `demos/Exhaustive.dhall`.
- `.github/workflows/release.yml`: the "Resolve Dhall" step's
  `file: gen/Gen.dhall` → `file: src/package.dhall`.
- `.github/scripts/build-contract-shell.sh`: comment references
  `tests/Exhaustive.dhall` → `demos/Exhaustive.dhall` (comment only, verify
  no functional path argument needs changing — it's invoked with
  `contract-output` as a positional arg per `ci.yml`, not a hardcoded path).
- `README.md`: line ~38 `gen: https://raw.githubusercontent.com/slavashvets/python.gen/master/gen/Gen.dhall`
  → `.../src/package.dhall`; lines ~64-66, the three example URLs
  (`.../gen/Gen.dhall`) → `.../src/package.dhall`.
- `AGENTS.md`: line ~36 "`gen/` pins its remote imports by sha256
  (`gen/Deps/*.dhall`)" → "`src/` pins its remote imports by sha256
  (`src/Deps/*.dhall`)".
- `DESIGN.md`: line 4 (`gen/`), line 381 (`gen/Gen.dhall` "is the entry point
  handed to gen-sdk"), line 397 (`gen/` mirrors...), line 401 (the `gen/`
  tree diagram — replace with the new `src/` tree, matching Task 5's actual
  post-move layout), lines 632/636 (`tests/Exhaustive.dhall` → `demos/Exhaustive.dhall`).
- `build.bash`: this is a scratch/dev script (mostly commented-out lines) —
  update the live lines: `target=tests/Exhaustive.dhall` →
  `target=demos/Exhaustive.dhall`; the commented `# target=gen/Gen.dhall` and
  `# dhall freeze gen/Deps/*.dhall` lines → `src/` equivalents (keep them
  commented, just fix the paths so they're not stale if uncommented later).
- `bench/generate.sh`, `bench/as-source.sh`: both `cp -R "$root/gen" "$out/gen"` /
  `"$1/gen"` → `"$root/src" "$out/src"` (and update the `gen/Deps/*.dhall`
  perl substitutions to `src/Deps/*.dhall`). **The `as Source` → plain-import
  sha256 substitutions in both scripts' `strip_as_source` are pinned to the
  *old* `gen-sdk v0.11.0`/`lude v5.1.0` source-vs-normalized hash pairs**
  (`8d43544e...`→`b9f7bb84...` for Sdk, `46b527b0...`→`14c43eec...` for Lude).
  Since `Task 1` bumps `gen-sdk` to `v2.0.0`, these substitution pairs are now
  wrong and must be recomputed for the new pin using the repo's actual pinned
  toolchain (`mise x -- dhall hash` on the plain, non-`as-Source` import) —
  don't guess these; if the recompute can't happen in this pass, leave a
  `# TODO` in the script rather than shipping a silently-wrong benchmark.
- `mise.toml`'s `golden` task: the `python3 - ... "$root/gen/Gen.dhall"` arg
  and the fixture-project string replace target `"../../gen/Gen.dhall"` →
  `"../../src/package.dhall"`.

- [ ] **Step 1: Apply all substitutions above.**
- [ ] **Step 2: Confirm no stragglers:**
  ```bash
  grep -rn "gen/Gen\.dhall\|gen/Deps\|gen/Interpreters\|gen/Templates\|gen/Structures\|gen/Config\.dhall\|gen/compile\.dhall\|tests/Exhaustive" \
    --include="*.md" --include="*.yml" --include="*.yaml" --include="*.toml" --include="*.sh" --include="*.bash" .
  ```
  Expected: no output (everything left under `tests/golden/` or `tests/fixture-project/`
  that isn't a generator-path reference is fine and out of scope — check any
  hit manually rather than assuming).
- [ ] **Step 3: Commit.**

---

### Task 7: Format, verify end-to-end, update CHANGELOG

- [ ] **Step 1: Format everything:**
  ```bash
  mise x -- dhall format --transitive src/package.dhall
  mise x -- dhall format --transitive demos/Exhaustive.dhall
  ```

- [ ] **Step 2: Full type-check:**
  ```bash
  mise x -- dhall type --file src/package.dhall
  mise x -- dhall type --file demos/Exhaustive.dhall
  ```

- [ ] **Step 3: Regenerate the Exhaustive fixture and confirm no diff in
  output** (this is the load-bearing check — everything above only proves
  the Dhall type-checks, not that it still produces the same files):
  ```bash
  mise x -- dhall to-directory-tree --allow-path-separators --file demos/Exhaustive.dhall --output /tmp/pygen-after
  ```
  Compare against a snapshot taken from the pre-migration tree the same way
  (`git stash`, regenerate to `/tmp/pygen-before`, `git stash pop`, `diff -rq
  /tmp/pygen-before /tmp/pygen-after`). Expected: **no diff**. Any diff here
  is a migration bug, not an intentional update — per Global Constraints, go
  fix it rather than accepting the new output.

- [ ] **Step 4: Run the Python harness:**
  ```bash
  mise x -- uv sync
  mise x -- uv run pytest tests -v
  ```
  (Needs a reachable Postgres — `PGN_TEST_DATABASE_URL`, see `ci.yml` for the
  Docker Compose equivalent — and the `mise`-pinned `pgn 0.9.1`, since the
  harness shells out to it.) Expected: all green, no new failures relative to
  a pre-migration run.

- [ ] **Step 5: Add a CHANGELOG.md entry** under `# Upcoming` (the file
  already starts with that heading), non-breaking, modeled on `java.gen`'s
  own `v1.1.0` entry:
  ```markdown
  - Migrated the generator's internal dependencies to `gen-contract` v4.0.1
    and `gen-sdk` v2.0.0, adopting `Sdk.Sigs` in place of the local
    `Algebras/` module, and restructured the repository layout to match the
    pGenie generator architecture: implementation moved from `gen/` to
    `src/`, the public entry point renamed from `gen/Gen.dhall` to
    `src/package.dhall`, and the fixture driver moved from
    `tests/Exhaustive.dhall` to `demos/Exhaustive.dhall`. No change to
    generated output or the public Dhall interface (`artifacts.<name>.gen`
    URLs pointing at a previously-released `resolved.dhall` are unaffected;
    only the next release's URL path changes, from `.../gen/Gen.dhall` — the
    unresolved source path some projects may reference directly instead of a
    frozen release — to `.../src/package.dhall`).
  ```
  Adjust the last parenthetical if no project in practice points at the
  unresolved source path (check `README.md`'s own recommended usage — if it
  only ever recommends the frozen `resolved.dhall` release asset, simplify
  this to "no change to generated output or the public Dhall interface").

- [ ] **Step 6: Commit.**

## Deferred / explicitly out of scope (record as follow-ups, don't do now)

- Narrowing each interpreter's `Config` to only the fields it needs (see
  Global Constraints).
- Giving `Member.dhall`/`ParamsMember.dhall` a real `Sdk.Sigs.interpreter`
  shape by folding `CustomKind.Lookup` into `Config` or `Input` (see Global
  Constraints).
- Adding a `Name` interpreter (`java.gen` has `Interpreters/Name.dhall`
  centralizing identifier casing/escaping; `python.gen` calls
  `Structures/PyIdent.dhall` ad hoc from several interpreters instead). This
  is a real architecture-doc deviation but not something `java.gen`'s last
  release changed — separate task if wanted.
- Recomputing the `as Source` bench-script hash pairs for `gen-sdk v2.0.0` /
  `lude v5.1.0` (flagged inline in Task 6 — needs the real toolchain, not
  guessable).
