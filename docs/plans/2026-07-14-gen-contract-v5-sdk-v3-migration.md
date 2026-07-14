# Plan: bump gen-contract/gen-sdk pins and retire `buildLookup`'s `Text/equal`

## Background

This implements steps 3-4 of the "Next steps" section in
`docs/plans/2026-07-14-detext-equal-branch-filter.md` (item 4 of that
document's decision table). That document is the record of *why*; this
document is the *how*, broken into tasks for subagent-driven execution.
Read the background doc if you want the full history — it is not required
reading for any task below, which are self-contained.

**Scope grew mid-execution.** Task 1 (bumping gen-contract/gen-sdk pins)
could not be verified against `pgn` v0.9.1 — it rejects gen-contract major
version 5 outright. `pgn` v0.12.0 fixes that, but v0.11.0 (a prerequisite)
dropped the `Text/equal` builtin from its embedded Dhall evaluator entirely.
That forced a live investigation (documented in Task 2's "Why this exists"
and Task 3's "Why this shape") which found that `Text/equal`-free rework is
*impossible* (not just hard) for anything that makes a decision from
comparing two arbitrary runtime strings — which pulled decision-table items
6-7 (same-kind collision detection, rename mappings) and the ADR into scope
now, plus `PythonNamespace.dhall`'s collision detection more broadly (never
part of items 6-7). Task 3 covers all of that. Item 5 (facade
un-flattening) remains **out of scope** — it's unrelated to `Text/equal` and
still needs its own design pass.

## Global constraints

- New pins (`dhall hash`-computed, already verified in the background doc):
  ```
  -- src/Deps/Contract.dhall
  https://raw.githubusercontent.com/pgenie-io/gen-contract/v5.0.0/src/package.dhall
    sha256:a1b48fe025c5536b13907bcd2db307cd438f3ae0f67a59222b3aa39e4bdac9ef

  -- src/Deps/Sdk.dhall
  https://raw.githubusercontent.com/pgenie-io/gen-sdk/v3.0.0/src/package.dhall
    sha256:368e4ee1f7557e8a1713a0ac53db6bbfb476027b322d06a660842e5e22e18662
  ```
- Verification oracle for every task: `mise run test` (drives real `pgn`
  subprocesses against the local PostgreSQL server already running on
  `localhost:5432`). Also run `mise run lint`. Do **not** invent a separate
  `dhall` CLI invocation to typecheck `.dhall` files standalone — the
  pgn-fork Dhall evaluator (needed for anything using `Text/equal`, before
  Task 3 removes the remaining uses) is only available locally through
  `pgn generate` (invoked by the mise tasks).
- Task 1 was written and dispatched before Task 2/3 existed, when `pgn`
  v0.9.1 was still pinned — its own text still says "unrelated `Text/equal`
  usage" and "out of scope"; that was correct *at the time* for Task 1's
  own diff, but Tasks 2-3 below supersede those scoping notes for the
  branch as a whole. Follow each task's own instructions as written.
- Do not touch decision-table items 1-3 (`emitSync`, custom-type
  registration/`sameOrder`/`order` field, `PyIdent.dhall`'s reserved-name
  disambiguation) — they are unrelated and already `Text/equal`-free (aside
  from the `py-ident-fix` cleanup pulled in by Task 2, which keeps the same
  behavior).
- Regenerate the golden fixture (`mise run golden`) if `pgn generate` output
  changes at all (it should not — this migration changes only the Dhall
  generator's internals, not its emitted Python), and confirm
  `tests/golden` has no diff. If it does diff, treat that as a signal
  something changed unintentionally, not something to silently accept.
- Update the "Upcoming" section of `CHANGELOG.md` with one entry describing
  the pin bump and the elimination of `buildLookup`'s `Text/equal` (after
  Task 4). Follow the existing terse bullet style in that file.

---

## Task 1: Bump pins to gen-contract v5.0.0 / gen-sdk v3.0.0 and fix compile breakage

### Why this shape

Bumping the pin is a breaking change independent of the `buildLookup`
migration (Task 4). Two things changed in the contract:

1. `Scalar.Custom` changed from carrying a bare `Name` to carrying a
   `CustomTypeRef`:
   ```dhall
   let CustomTypeRef =
         { name : Name, pgSchema : Text, pgName : Text, index : Natural }

   let Scalar = < Primitive : Primitive | Custom : CustomTypeRef >
   ```
   `index` is a 0-based position into `Project.customTypes`, and the
   contract now *guarantees* that list is topologically sorted (every index
   reachable from `customTypes[i]` is `< i`). `CustomTypeRef` still carries
   `.name : Name`, so every site that only used the bare `Name` (e.g. to
   feed the *existing* `Text/equal`-based lookup) can keep doing exactly
   that by reading `.name` off the ref — this task does **not** change the
   lookup mechanism, that is Task 4.

2. `Value` flattened its optional array wrapper:
   ```dhall
   -- old (v4.0.1)
   let ArraySettings = { dimensionality : Natural, elementIsNullable : Bool }
   let Value = { arraySettings : Optional ArraySettings, scalar : Scalar }

   -- new (v5.0.0)
   let Value =
         { dimensionality : Natural
         , elementIsNullable : Bool
         , scalar : Scalar
         }
   ```
   `dimensionality = 0` now means "no array" (replacing
   `arraySettings = None ArraySettings`); `elementIsNullable` is meaningless
   when `dimensionality = 0`, same as before. There is no more
   `Model.ArraySettings` type at all.

This task's only job is: make every one of these sites compile again,
preserving current behavior exactly. Do not build the `List TypeKind`
lookup replacement here — that is Task 4, and mixing the two makes either
task hard to review independently.

### Exact changes

**`src/Deps/Contract.dhall`** — replace both lines with the new pin (URL and
hash both change):
```
https://raw.githubusercontent.com/pgenie-io/gen-contract/v5.0.0/src/package.dhall
  sha256:a1b48fe025c5536b13907bcd2db307cd438f3ae0f67a59222b3aa39e4bdac9ef
```

**`src/Deps/Sdk.dhall`** — replace both lines with the new pin:
```
https://raw.githubusercontent.com/pgenie-io/gen-sdk/v3.0.0/src/package.dhall
  sha256:368e4ee1f7557e8a1713a0ac53db6bbfb476027b322d06a660842e5e22e18662
```

**`src/Interpreters/Scalar.dhall`** — `Output.customRef` changes type from
`Optional Model.Name` to `Optional Model.CustomTypeRef`, and the `Custom`
branch now receives a `CustomTypeRef` instead of a bare `Name`:
```dhall
let Output =
      { pyType : Text
      , imports : ImportSet.Type
      , customRef : Optional Model.CustomTypeRef
      , decode : ScalarDecode
      }

let run =
      \(config : Config) ->
      \(input : Input) ->
        merge
          { Primitive =
              \(primitive : Model.Primitive) ->
                Lude.Compiled.map
                  Primitive.Output
                  Output
                  ( \(p : Primitive.Output) ->
                      { pyType = p.pyType
                      , imports = p.imports
                      , customRef = None Model.CustomTypeRef
                      , decode = ScalarDecode.Passthrough
                      }
                  )
                  (Primitive.run {=} primitive)
          , Custom =
              \(ref : Model.CustomTypeRef) ->
                Lude.Compiled.ok
                  Output
                  { pyType = ref.name.inPascalCase
                  , imports = ImportSet.empty
                  , customRef = Some ref
                  , decode = ScalarDecode.Custom
                  }
          }
          input
```
(Only the `customRef` field's type and the `Custom` branch's parameter
changed; `Primitive` branch changes only in the type annotation on
`None Model.CustomTypeRef`.)

**`src/Interpreters/Value.dhall`** — `input.arraySettings` (an
`Optional Model.ArraySettings`) becomes two plain fields directly on
`Input`. Replace the `Prelude.Optional.fold` over `arraySettings` with a
check on whether `input.dimensionality` is zero:
```dhall
let run =
      \(config : Config) ->
      \(input : Input) ->
        Lude.Compiled.map
          Scalar.Output
          Output
          ( \(scalar : Scalar.Output) ->
              if    Natural/isZero input.dimensionality
              then  { pyType = scalar.pyType
                    , imports = scalar.imports
                    , scalar
                    , dims = 0
                    , elementIsNullable = False
                    }
              else  let elementType =
                          if    input.elementIsNullable
                          then  "${scalar.pyType} | None"
                          else  scalar.pyType

                    let arrayType =
                          Natural/fold
                            input.dimensionality
                            Text
                            (\(inner : Text) -> "list[${inner}]")
                            elementType

                    in  { pyType = arrayType
                        , imports = scalar.imports
                        , scalar
                        , dims = input.dimensionality
                        , elementIsNullable = input.elementIsNullable
                        }
          )
          (Scalar.run {=} input.scalar)
```
`Output` (python.gen's own internal shape: `pyType`, `imports`, `scalar`,
`dims`, `elementIsNullable`) is unchanged — only how it's derived from
`Input` changes. `qualifyCustom` changes only its type annotation
(`Optional Model.Name` → `Optional Model.CustomTypeRef`) and reads
`.name.inPascalCase` off the ref instead of the bare name directly:
```dhall
let qualifyCustom
    : Text -> Text -> Output -> Text
    = \(prefix : Text) ->
      \(className : Text) ->
      \(value : Output) ->
        Prelude.Optional.fold
          Model.CustomTypeRef
          value.scalar.customRef
          Text
          ( \(ref : Model.CustomTypeRef) ->
              Text/replace
                ref.name.inPascalCase
                (prefix ++ className)
                value.pyType
          )
          value.pyType
```

**`src/Interpreters/Member.dhall`** — the `Custom` branch unwraps
`value.scalar.customRef` (now `Optional Model.CustomTypeRef`). Rename the
bound variable from `name` to `ref` for clarity and feed `ref.name` to
`lookup` (the lookup mechanism itself is untouched in this task — still
`Model.Name -> TypeKind`):
```dhall
, Custom =
    Prelude.Optional.fold
      Model.CustomTypeRef
      value.scalar.customRef
      (Lude.Compiled.Type Output)
      ( \(ref : Model.CustomTypeRef) ->
          let mkOutput = ... -- unchanged body, still uses `identity`
          ...
          in  merge
                { Enum = ...     -- unchanged
                , Composite = ... -- unchanged
                , Absent =
                    Lude.Compiled.report
                      Output
                      [ ref.name.inSnakeCase ]
                      "Custom type not found in project customTypes"
                }
                (lookup ref.name)
      )
      ( Lude.Compiled.report
          Output
          [ input.pgName ]
          "Custom scalar without a customRef name"
      )
```
Every other reference to the old `name : Model.Name` binding inside this
branch (the two `input.pgName, name.inSnakeCase` error-path lists) becomes
`input.pgName, ref.name.inSnakeCase`. Do not change anything about the
`Enum`/`Composite`/`Absent` merge arms themselves or the dims math.

**`src/Interpreters/ParamsMember.dhall`** — identical shape of change as
Member.dhall, in the `Prelude.Optional.fold Model.Name value.scalar.customRef
...` block (around line 255-326): rename the bound `name : Model.Name` to
`ref : Model.CustomTypeRef`, change the fold's type argument to
`Model.CustomTypeRef`, call `lookup ref.name`, and update the two
`[input.pgName, name.inSnakeCase]` error-path lists to
`[input.pgName, ref.name.inSnakeCase]`, and the `Absent` arm's
`[name.inSnakeCase]` to `[ref.name.inSnakeCase]`. Also check
`isJsonbScalar`/`isJsonScalar`/`valueIsArray`/`scalarIsJson` earlier in this
file (used to compute `needsJsonbImport`/`needsJsonImport`/
`isJsonArrayParam`) for any direct reads of `value.arraySettings` or
`Model.ArraySettings` — if present, adapt them the same way as Value.dhall
(`dimensionality`/`elementIsNullable` fields directly on `Model.Value`
instead of an `Optional Model.ArraySettings` wrapper). Read the full file
before editing; the excerpt in this brief only covered lines 200-339.

**`src/Interpreters/CustomType.dhall`** — two things:
1. The `Composite` branch's member loop matches on `m.value.scalar` with
   `Custom = \(name : Model.Name) -> ...` (checking
   `m.value.arraySettings` to reject "Custom array fields inside a
   composite type are not supported"). Update the merge arm's bound
   variable type to `Model.CustomTypeRef` (rename `name` to `ref`,
   references become `ref.name`/`ref.name.inSnakeCase`), and change the
   `Optional Model.ArraySettings`/`m.value.arraySettings` check to
   `Prelude.Bool.not (Natural/isZero m.value.dimensionality)` (i.e. "has at
   least one array dimension") in place of testing whether the `Optional`
   is `Some`.
2. `lookup input.name` (the self-consistency check, `input : Model.CustomType`)
   is unaffected — `Model.CustomType.name` is still a plain `Model.Name`,
   untouched by this contract version's breaking changes. Leave it as-is
   in this task.

**`src/Interpreters/Result.dhall`, `src/Interpreters/ResultColumns.dhall`,
`src/Interpreters/Query.dhall`** — these only carry `lookup : CustomKind.Lookup`
through as an opaque parameter (grep confirms no direct `Model.Name`/
`Model.ArraySettings` access in these three files). They should not need any
edits; if `dhall`/`pgn generate` reports an error originating in one of
these files, that means this brief's premise was wrong somewhere upstream —
investigate rather than patching around it here.

**`src/Interpreters/Project.dhall`** — do **not** touch `buildLookup`,
`effectiveResolvedCustomTypes`, or `CustomKind.Lookup` in this task (that's
Task 4). The only things in this file that might need attention from the
pin bump: grep the file yourself for any other `Model.Name`/
`Model.ArraySettings` reads this brief didn't enumerate (the `Custom` merge
arm inside `resolveCustomTypes`'s `kind` computation, for instance, matches
on `customType.definition`, not `Scalar.Custom`, so it should be unaffected
— confirm this rather than assuming it).

### Also check

Run `grep -rn "Model.ArraySettings\|arraySettings" src/` yourself after
reading each file above — this brief's line numbers may drift slightly from
exact current file content. Fix every site the grep turns up, not just the
ones enumerated here.

### Verification

1. `mise run test` — must pass (73 passed, 0 skipped per the README's
   documented baseline; note the exact count down if it differs and
   investigate why before treating that as a pass).
2. `mise run lint`.
3. `mise run golden`, then `git diff tests/golden` — expect **no diff**.
   If there is a diff, do not commit it silently; report it as a concern.
4. Report the exact commands run and their output in the task report.

### Report file

Write your report to the path given in the dispatch prompt. Include: which
files you touched beyond this brief's list (if any, and why), the full
`mise run test` summary line, and confirmation of a clean `git diff
tests/golden`.

---

## Task 2: Bump pgn to v0.12.0, pull in the `py-ident-fix` cleanup, re-verify Task 1

### Why this exists

Task 1 landed correctly (commit `d18398c`) but could not be verified:
`pgn` v0.9.1 (pinned in `mise.toml`) hard-rejects gen-contract major version 5
("Incompatible contract major version: 5. Expected 4."). `pgn` v0.12.0
(released 2026-07-14) adds gen-contract v5.0.0 support — confirmed via its
changelog: *"Bump the `gen-contract` dependency to v5.0.0... Add
`CustomTypeRef`... Flatten `Value`'s `arraySettings`..."*, exactly matching
Task 1's changes.

`pgn` v0.11.0 (a prerequisite of v0.12.0) is a breaking change:
*"Update to Dhall that lacks `Text/equal` to stay in line with the official
Dhall spec."* Confirmed empirically (both against the real `pgn` fork via a
throwaway `pgn generate` run, and against stock upstream `dhall` 1.42.3):
`Text/equal`, `Text/length`, and `Bool/equal` are all unavailable — there is
no way to produce a `Bool` or a differently-typed decision (e.g. an `Ok`/`Err`
union) from comparing two arbitrary runtime `Text` values using only
`Text/replace`. `Text/replace`-based tricks (this repo's old digit-marker
trick, and gen-sdk's own `Lude.Text.replaceIfEqual`/`replaceIfOneOf`) only
ever produce more `Text` — they can transform text, not decide anything. This
is why Task 3 (below) has to discard rather than "rework" several checks.

Branch `py-ident-fix` (already pushed, commit `7685c0a8794b0d4e20947c2ff6aa9c11b4dabd48`,
"python.gen: replace PyIdent's hand-rolled keyword equality with
Lude.Text.replaceIfOneOf") already did the one part of this that *is* just a
transform (not a decision): `PyIdent.dhall`'s Python-keyword-suffixing. Pull
that commit's change into this branch as part of this task — it is a strict
simplification of code Task 1 already touches, with the same public
interface and unchanged golden output per its own commit message.

### Exact changes

1. **Cherry-pick or manually reapply** commit `7685c0a8794b0d4e20947c2ff6aa9c11b4dabd48`
   from `py-ident-fix` onto this branch (`git log py-ident-fix` to find it;
   `git cherry-pick 7685c0a8794b0d4e20947c2ff6aa9c11b4dabd48` is the
   straightforward route — resolve any conflict against Task 1's changes by
   keeping Task 1's contract-type changes and `py-ident-fix`'s
   `sanitizeAgainst`/`Lude.Text.replaceIfOneOf` rewrite; they don't overlap
   in `PyIdent.dhall`, which Task 1 never touched).
2. **`mise.toml`**: change the pgn tool pin from `v0.9.1` to `v0.12.0`:
   ```toml
   "github:pgenie-io/pgenie" = { version = "v0.12.0", exe = "pgn" }
   ```
   Run `mise install` (or just let the next `mise run` task trigger it) to
   fetch the new binary.
3. Re-run Task 1's verification now that the environment is unblocked:
   `mise run test`, `mise run lint`, `mise run golden` + `git diff
   tests/golden` (expect no diff). Do not make further Dhall changes in this
   task beyond the cherry-pick above — if `mise run test` still fails for a
   reason unrelated to the pgn version (e.g. a genuine bug in Task 1's
   compile fixes), report it as a concern rather than silently patching
   Task 1's work under this task's commit.

### Verification

`mise run test`, `mise run lint`, `mise run golden` + `git diff
tests/golden` (expect no diff). Report the exact `mise run test` summary
(pass/fail counts) — this is the first time it can actually run end to end
since Task 1 started, so capture it precisely.

### Report file

`.superpowers/sdd/task-2-report.md`. State clearly: the cherry-picked commit
hash (or, if reapplied manually, why), the new `mise run test` result, and
confirmation of clean `git diff tests/golden`.

---

## Task 3: Discard `Text/equal`-dependent validation (mappings, identity check, namespace collision detection)

**Depends on Task 2** (needs `pgn` v0.12.0 actually working, so this task's
own verification is meaningful). Do not start until Task 2's review is clean.

### Why this shape

With `Text/equal` gone from `pgn`'s embedded Dhall evaluator (confirmed in
Task 2's background), every piece of this generator that makes a *decision*
by comparing two arbitrary runtime `Text` values is no longer expressible —
not "hard to rework," genuinely impossible in the target language (see
Task 2's background section for the proof). Three clusters of code do this:

1. **`queryNameMappings`/`customTypeNameMappings`** (the rename-mapping
   config feature): `PythonNameMapping.dhall`'s `resolveQuery`/
   `resolveCustomType` match a mapping's `source` against a query/type name
   via `Text/equal`. This is decision-table item 7 from the background doc
   (`docs/plans/2026-07-14-detext-equal-branch-filter.md`) — already marked
   **discard entirely**, independent of this new finding.
2. **`validateCustomTypeIdentities`** (`Interpreters/Project.dhall`, checks
   whether two different custom types collapse to the same unqualified
   contract `Name`): matches decision-table item 6's philosophy exactly —
   "pushed upstream instead," and
   [pgenie-io/pgenie#75](https://github.com/pgenie-io/pgenie/issues/75)
   (already filed) explicitly asks pgn to "guarantee unique custom-type
   identities at the source." Discard, same rationale as item 6.
3. **`PythonNamespace.dhall`'s `validate`** (4 call sites in
   `Interpreters/Project.dhall`: per-query local param/result-field
   namespace, per-custom-type local field namespace, the project-wide
   facade/module namespace, and per-type module-internal bindings): this
   goes beyond items 6-7 (the local audits were never proposed for
   discard), but it's equally impossible now. Confirmed there is a working
   safety net one layer down: `tests/test_generated.py`'s
   `test_generated_passes_basedpyright_strict` (and the same pattern in
   `test_identifier_collisions.py`, `test_psycopg_adapter_contract.py`,
   `test_unsupported_types.py`) already asserts
   `errorCount == 0 and warningCount == 0` on the generated package. Verified
   empirically: a duplicate dataclass field name triggers basedpyright's
   `reportRedeclaration` (warning — fails the gate), and a field name that
   shadows a type needed elsewhere triggers `reportInvalidTypeForm` (hard
   error). The tradeoff is real and accepted deliberately: today a collision
   fails fast at `pgn generate` with a message pointing at the SQL/schema
   source; after this task, the same collision still fails the test suite,
   just later (at basedpyright time) and less precisely attributed
   (pointing at generated Python, not SQL). This was an explicit, discussed
   tradeoff, not an oversight — do not try to preserve the old error
   messages by some other means.

### Exact changes

**Delete entirely:**
- `src/Structures/PythonNameMapping.dhall`
- `src/Structures/PythonNamespace.dhall`
- `docs/adr/0001-generated-python-name-collisions.md` (its entire content
  describes the mechanism being removed in this task — stale documentation
  actively describing a removed feature is worse than no doc at all; do not
  wait for item 8's broader doc pass)
- `tests/test_python_name_collisions.py` (this file, per the background
  doc, "specifically tests the collision-detection and rename-mapping
  mechanisms being discarded")

**`src/package.dhall`**: remove `queryNameMappings`/`customTypeNameMappings`
from `Config` and `Config/default`, and the `PythonNameMapping` import.

**`src/Interpreters/Project.dhall`**: remove
- `queryNameMappings`/`customTypeNameMappings` from `Config` and
  `ResolvedConfig`, and their resolution in `run`.
- `validateCustomTypeIdentities`, `validateQueryMappings`,
  `validateCustomTypeMappings`, `finishMappingValidation` (if nothing else
  uses it after the other three are gone — check), `QueryMappingState`,
  `CustomTypeMappingState`, `CustomTypeIdentity`, `CustomTypeIdentityState`,
  and the `mappingsValid`/`mappingsAndLocalsValid` wiring in `run` that
  chains them together (fold their removal into whatever the remaining
  validation chain becomes — read the full `run` function first to see
  what `mappingsAndLocalsValid`/`combined` looks like once
  `validateLocalNamespaces` is *also* gone, see next point, since both
  disappear in the same task).
- `validateLocalNamespaces`, `validateProjectNamespaces`, and the
  `moduleValidation` block inside it — all of `PythonNamespace.validate`'s
  4 call sites. Remove the `PythonNamespace` import.
- The `PythonNameMapping` import, and any leftover reference to the
  mapping/namespace types in this file's other functions (grep after
  editing to confirm nothing dangles).

**`src/Interpreters/Query.dhall`** and **`src/Interpreters/CustomType.dhall`**:
remove `queryNameMappings`/`customTypeNameMappings` from their `Config`
types, remove the `PythonNameMapping` import, and replace the
`PythonNameMapping.resolveQuery`/`resolveCustomType` call with the bare
default name directly — e.g. in `CustomType.dhall`:
```dhall
-- before
let pythonName =
      PythonNameMapping.resolveCustomType
        config.customTypeNameMappings
        { schema = input.pgSchema, name = input.pgName }
        { snakeCase = PyIdent.typeModuleSafeName input.name.inSnakeCase
        , pascalCase = PyIdent.pySafeName input.name.inPascalCase
        }

-- after
let pythonName =
      { snakeCase = PyIdent.typeModuleSafeName input.name.inSnakeCase
      , pascalCase = PyIdent.pySafeName input.name.inPascalCase
      }
```
and the analogous simplification in `Query.dhall` around its
`PythonNameMapping.resolveQuery` call. Read both call sites in full before
editing — this brief doesn't reproduce their exact surrounding code.

**`CustomType.dhall`'s `moduleBindings`/namespace-binding plumbing**
(`enumNamespaceBindings`, `compositeNamespaceBindings`, `moduleNamespace`,
`moduleBinding`, and the `Output.moduleBindings` field): these exist solely
to feed `PythonNamespace.validate`'s per-module check (now gone). Remove
them and the `moduleBindings` field from `CustomType.dhall`'s `Output`, and
its consumption in `Project.dhall`. Confirm nothing else reads
`moduleBindings` before deleting it (grep first).

**Also check** `Interpreters/ResultColumns.dhall`, `Result.dhall`,
`Member.dhall`, `ParamsMember.dhall` for any `PythonNamespace`/
`PythonNameMapping` references this brief didn't enumerate (expected: none,
but confirm).

### Tests

- Delete `tests/test_python_name_collisions.py` (see above).
- Read `tests/test_identifier_collisions.py` in full before touching it: it
  covers query-name-vs-implementation-global collisions (decision-table
  item 3's cluster, `PyIdent.dhall`'s reserved-name disambiguation — kept,
  not part of this task) and *also* uses basedpyright directly (lines
  ~282-290). Update only the parts of it that exercise the
  now-deleted `queryNameMappings`/`customTypeNameMappings`/
  `PythonNamespace`-based paths, if any — keep everything about reserved
  implementation-name disambiguation as-is.
- Read `tests/test_unsupported_types.py` in full — it references
  `PythonNameMapping`/mapping config (per the earlier grep). Update it to
  drop mapping-specific scenarios while keeping its `onUnsupported: Skip`
  coverage intact (that coverage matters for Task 4, next).
- **`tests/test_unsupported_types.py`'s `_write_contract_probe` helper**
  (around line 115, feeding the 6-case parametrized
  `test_custom_shape_contracts_fail_loudly`) hand-authors a synthetic Dhall
  wrapper module as a Python string, and needs updating for *this* task's
  changes specifically (Task 4 will need a second pass on the same helper
  for its own changes — see Task 4's Tests section below, don't try to
  anticipate that part here):
  - `interpreter_config` currently emits
    `{ customTypeNameMappings = [] : List PythonNameMapping.CustomType }`
    when `interpreter == "CustomType"` — `PythonNameMapping` no longer
    exists after this task. Since `CustomType.dhall`'s `Config` also drops
    `customTypeNameMappings` in this task (per the `Interpreters/*.dhall`
    changes above), the interpreter config becomes `{=}` unconditionally
    (same as the non-`CustomType` branch) — the `if interpreter ==
    "CustomType" else` branch can go entirely.
  - The wrapper's own `let PythonNameMapping = ./Structures/PythonNameMapping.dhall`
    import line must be removed.
  - This probe is still on the *old* contract shape from before Task 1 (it
    was never updated when Task 1 landed, since Task 1 didn't know test
    fixtures existed at this level — confirmed by code review): its
    `member.value` still builds `{ arraySettings = {array_settings}, scalar
    = Model.Scalar.Custom name }` where `array_settings` renders
    `"None Model.ArraySettings"` or `"Some { dimensionality = N,
    elementIsNullable = False }"`, and `Model.Scalar.Custom name` passes a
    bare `Model.Name`. Both no longer typecheck against the now-bumped
    gen-contract v5.0.0 pin (Task 1). Fix this probe to the new shape as
    part of *this* task (it's blocking verification regardless of which
    task's changes it's nominally testing): `value` becomes
    `{ dimensionality = {dimensionality}, elementIsNullable = False, scalar
    = Model.Scalar.Custom { name, pgSchema = "public", pgName =
    "probe_value", index = 0 } }` (drop the `array_settings` local
    entirely, inline `dimensionality` directly — `0` for the non-array
    case, same as today's `None` case). Confirm the probe still produces
    the same 6 pass/fail outcomes the test asserts.
  - Leave the probe's `CustomKind.Lookup` construction
    (`\(_ : Model.Name) -> {lookup}`) as-is in this task — that's Task 4's
    job, since `CustomKind.Lookup`'s shape doesn't change until then.
- Do **not** touch `tests/test_takeover_contract.py` — it's about the flat
  facade (item 5), out of scope for this whole plan.
- Run the full suite; if new failures appear that trace to bindings this
  task didn't anticipate removing, investigate rather than papering over
  them (e.g. with a stub mapping).

### Docs

- **`README.md`**: remove the `queryNameMappings`/`customTypeNameMappings`
  rows from the config table (lines ~46-47 as of this writing); remove the
  "Generated Python namespaces are audited..." paragraph and its YAML
  mapping example (~lines 62-96, read current content — line numbers will
  have drifted from Task 1/2's edits); remove the ADR 0001 link. Replace
  with a short, honest paragraph: namespace collisions are not detected at
  generation time; a colliding schema fails `basedpyright --strict` on the
  generated package instead (link to
  [pgenie-io/pgenie#75](https://github.com/pgenie-io/pgenie/issues/75) for
  the upstream ask to prevent custom-type identity collisions at the
  source). Don't overclaim — collisions are *possible*, just caught later.
- **`DESIGN.md`** section 5 ("Configuration, mapping, and unsupported
  shapes"): remove the mapping-specific config fields/description and the
  ADR reference; keep the `onUnsupported` description (unrelated). Section
  10 ("The pinned `Text/equal` constraint"): this section is also rewritten
  by Task 4 for `buildLookup` specifically — in *this* task, update it (or
  leave a marker for Task 4) to note that mapping/namespace/identity
  validation no longer uses `Text/equal` either, and enumerate what (if
  anything) still does after this task (check with a repo-wide grep for
  `Text/equal` once done — there should be very little, if anything, left
  outside `Interpreters/Project.dhall`'s `buildLookup`, which Task 4
  removes next).
- **`CHANGELOG.md`**: add an "Upcoming" bullet (matching the file's terse
  style) noting the removal of `queryNameMappings`/`customTypeNameMappings`
  and generation-time namespace-collision detection, with the basedpyright
  rationale, and a bullet for the pgn v0.12.0 bump (Task 2, if not already
  added there). Also fix the now-stale released-history bullet "Kept
  `PyIdent.dhall` independent of fork-only text equality by using its
  bounded `Text/replace` marker construction" (~line 82 as of this
  writing) — Task 2's cherry-pick already replaced that exact mechanism
  with `Lude.Text.replaceIfOneOf`. Don't rewrite released history in place;
  either amend that bullet's wording to describe the current mechanism
  accurately (it's still describing *current* behavior, just the wrong
  implementation detail) or add a one-line "Upcoming" bullet superseding it
  — whichever fits this file's existing convention for describing a
  changed implementation detail of already-released behavior.

### Verification

`mise run test`, `mise run lint`, `mise run golden` + `git diff
tests/golden` (a diff here IS expected in this task, since removing
mapping config could change nothing about default-path output, but confirm
this — if `tests/golden` changes, explain exactly why in the report).

### Report file

`.superpowers/sdd/task-3-report.md`. Include: full file list touched, the
`mise run test` summary, confirmation of `tests/golden` status (diff or no
diff, with explanation either way), and a repo-wide `grep -rn "Text/equal"
src/` output so the next task (Task 4) knows exactly what's left.

---

## Task 4: Replace `buildLookup`/`effectiveResolvedCustomTypes` with `Sdk.CustomTypes`

**Depends on Tasks 1-3** (needs the bumped pins, working `pgn` v0.12.0, and
`Model.CustomTypeRef` plumbing already in place). Do not start this task
until Task 3's review is clean.

### Why this shape

`gen-sdk` v3.0.0 ships a ready-made, `Text/equal`-free replacement for
python.gen's own removal-cascade, in `Sdk.CustomTypes`:

```dhall
-- List Bool: index i tells whether customTypes[i] is supported, given a
-- caller-supplied "is this kind of definition supported at all" predicate.
-- Composite/Domain members' own Custom refs are checked transitively via
-- List/fold over customTypes in order, since customTypes is topologically
-- sorted (every ref.index < the referencing type's own index).
supportedCustomTypes
    : (Contract.CustomTypeDefinition -> Bool) ->
      List Contract.CustomType -> List Bool

-- Same fold, but returns Some <root-cause CustomTypeRef> instead of False
-- for each unsupported index (useful for warning messages).
supportedCustomTypesReasoned
    : (Contract.CustomTypeDefinition -> Bool) ->
      List Contract.CustomType -> List (Optional Contract.CustomTypeRef)

customTypeIsSupported : List Bool -> Contract.CustomTypeRef -> Bool
queryIsSupported : List Bool -> Contract.Query -> Bool
```

This replaces the *removal-cascade* half of `buildLookup` +
`effectiveResolvedCustomTypes` (the repeated `Natural/fold` over
`Text/equal`-keyed lookups). It does **not** replace python.gen's own
rank-limit checks (array-of-enum >2 dims, array-of-composite >1 dim) —
those are python.gen-specific and stay, but they can now be expressed using
a referenced type's *kind* (Enum/Composite/Domain) obtained directly via
`ref.index`, instead of `Structures/CustomKind.dhall`'s
`Model.Name -> TypeKind` closure.

**The subtlety that makes this not a mechanical swap:** the *kind*
classification of a custom type (is it an Enum, a Composite, or a Domain)
never changes across removal passes — it's a fixed fact about each type's
own definition. The *old* `buildLookup` conflated two separate concerns by
shrinking its entry list each pass: (a) "what kind is this referenced type"
and (b) "is this referenced type still a survivor" — a lookup miss meant
`Absent` regardless of which of the two failed, and `Absent` is what causes
a downstream compile to reject the reference (`"Custom type not found in
project customTypes"`). The new design must keep producing that same
`Absent`-on-either-failure behavior, or a composite that depends on a
removed type will wrongly keep compiling (it would still find the removed
type's *real* kind via a fixed classification, silently referencing a type
that no longer gets emitted). Concretely: build the kind classification
once (fixed, never shrinks), build the supported/removed cascade once (via
`Sdk.CustomTypes`), then mask the two together — a reference to an index
that is not "supported" reads as `Absent` regardless of its real kind, only
in `Skip` mode (in `Fail` mode nothing is masked, matching current
behavior exactly: `Fail` never drops anything, so every input is looked up
at its real kind and only fails via one `CustomTypeGen.run`/`Member`/
`ParamsMember` error path, same as today).

### Exact changes

**`src/Structures/CustomKind.dhall`** — reshape `Lookup` from a closure to
an index-aligned list, and add an `at` accessor (mirrors gen-sdk's own
`optionalIndex` helper in `supportedCustomTypes.dhall`):
```dhall
let Model = ../Deps/Contract.dhall

let Prelude = ../Deps/Prelude.dhall

let Identity =
      { className : Text, moduleName : Text, order : Natural }

let TypeKind =
      < Enum : Identity
      | Composite : Identity
      | Absent
      >

let Lookup = List TypeKind

let at =
      \(lookup : Lookup) ->
      \(index : Natural) ->
        Prelude.Optional.fold
          TypeKind
          (Prelude.List.index index TypeKind lookup)
          TypeKind
          (\(kind : TypeKind) -> kind)
          TypeKind.Absent

in  { TypeKind, Lookup, Identity, at }
```

**Every call site that currently does `lookup <someName>` where the lookup
was keyed by a `Model.Name`** switches to `CustomKind.at lookup <index>`
where `<index>` comes from a `Model.CustomTypeRef.index` already in scope
(Task 1 already renamed the relevant bound variables to `ref`):

- `src/Interpreters/Member.dhall`: `(lookup ref.name)` → `(CustomKind.at lookup ref.index)`.
- `src/Interpreters/ParamsMember.dhall`: `(lookup ref.name)` → `(CustomKind.at lookup ref.index)`.
- `src/Interpreters/CustomType.dhall`:
  - The composite-member loop's `Custom = \(ref : Model.CustomTypeRef) -> ...` branch:
    `(lookup ref.name)` → `(CustomKind.at lookup ref.index)`.
  - The **self**-lookup (`lookup input.name`, appearing twice — once in the
    `Enum` merge arm, once in the `Composite` merge arm of `run`) needs the
    custom type's *own* index, which `Model.CustomType` does not carry
    directly (unlike a *reference* to one). Add an explicit `index : Natural`
    parameter to `CustomTypeGen.run`, threaded in by its caller
    (`Interpreters/Project.dhall`, see below), and use
    `CustomKind.at lookup index` in place of `lookup input.name` in both
    merge arms:
    ```dhall
    let run =
          \(config : Config) ->
          \(lookup : CustomKind.Lookup) ->
          \(index : Natural) ->
          \(input : Input) ->
            ...
                    in  merge
                          { Enum = \(identity : CustomKind.Identity) -> ...
                          , Composite = \(_ : CustomKind.Identity) -> ...
                          , Absent = ...
                          }
                          (CustomKind.at lookup index)
    ```
    (Both the `Enum`-definition branch's merge and the `Composite`-definition
    branch's merge get this same treatment — each currently ends with
    `(lookup input.name)`.)

**`src/Interpreters/Project.dhall`** — this is where the real restructuring
happens. Replace `buildLookup`, `lookupEntries`'s dependents, and
`effectiveResolvedCustomTypes` as follows. Keep `IndexedCustomType`,
`ResolvedCustomType`, `LookupEntry`, `LookupKind`, `resolveCustomTypes`, and
`lookupEntries` exactly as they are today (they still correctly compute,
per-type, its Python identity and Enum/Composite/Domain kind tag, in
`input.customTypes` order — `resolveCustomTypes` already builds this via
`Prelude.List.indexed Model.CustomType customTypes`, so `entry.index` is
already the same 0-based position space as the contract's `ref.index`,
confirmed same order since `resolveCustomTypes` is called directly with
`input.customTypes`, never a reordered copy).

Remove `buildLookup` entirely (lines ~590-611) and replace it with:

```dhall
let kindOf
    : List ResolvedCustomType -> CustomKind.Lookup
    = \(entries : List ResolvedCustomType) ->
        Prelude.List.map
          ResolvedCustomType
          CustomKind.TypeKind
          ( \(rt : ResolvedCustomType) ->
              merge
                { Composite = CustomKind.TypeKind.Composite rt.lookupEntry.identity
                , Enum = CustomKind.TypeKind.Enum rt.lookupEntry.identity
                , Domain = CustomKind.TypeKind.Absent
                }
                rt.lookupEntry.kind
          )
          entries

let dimsAtMostTwo =
      \(dims : Natural) -> Natural/isZero (Natural/subtract 2 dims)

let dimsAtMostOne =
      \(dims : Natural) -> Natural/isZero (Natural/subtract 1 dims)

-- Own-definition support check fed to Sdk.CustomTypes.supportedCustomTypesReasoned.
-- `fixedKindOf` is the *unmasked* kind classification (kindOf above) — always
-- present regardless of survivorship, since kind never changes across passes;
-- only the array-rank check depends on it here.
let rankChecked
    : CustomKind.Lookup -> Model.CustomTypeDefinition -> Bool
    = \(fixedKindOf : CustomKind.Lookup) ->
      \(definition : Model.CustomTypeDefinition) ->
        merge
          { Composite =
              \(members : List Model.Member) ->
                Prelude.List.all
                  Model.Member
                  ( \(member : Model.Member) ->
                      merge
                        { Primitive = \(_ : Model.Primitive) -> True
                        , Custom =
                            \(ref : Model.CustomTypeRef) ->
                              merge
                                { Enum =
                                    \(_ : CustomKind.Identity) ->
                                      dimsAtMostTwo member.value.dimensionality
                                , Composite =
                                    \(_ : CustomKind.Identity) ->
                                      dimsAtMostOne member.value.dimensionality
                                , Absent = True
                                }
                                (CustomKind.at fixedKindOf ref.index)
                        }
                        member.value.scalar
                  )
                  members
          , Enum = \(_ : List Model.EnumVariant) -> True
          , Domain = \(_ : Model.Value) -> False
          }
          definition

let boolAt =
      \(bools : List Bool) ->
      \(index : Natural) ->
        Prelude.Optional.fold
          Bool
          (Prelude.List.index index Bool bools)
          Bool
          (\(b : Bool) -> b)
          False
```

Then in `run`, replace the `effectiveResolvedCustomTypes`/
`effectiveCustomTypes`/`lookup` block (currently lines ~1166-1204) with:

```dhall
        let resolvedCustomTypes =
              resolveCustomTypes
                resolvedConfig.customTypeNameMappings
                input.customTypes

        let fixedKindOf = kindOf resolvedCustomTypes

        let supported
            : List Bool
            = if    skip
              then  Prelude.List.map
                      (Optional Model.CustomTypeRef)
                      Bool
                      (Prelude.Optional.null Model.CustomTypeRef)
                      ( Sdk.CustomTypes.supportedCustomTypesReasoned
                          (rankChecked fixedKindOf)
                          input.customTypes
                      )
              else  Prelude.List.map
                      ResolvedCustomType
                      Bool
                      (\(_ : ResolvedCustomType) -> True)
                      resolvedCustomTypes

        let lookup
            : CustomKind.Lookup
            = if    skip
              then  Prelude.List.map
                      { index : Natural, value : CustomKind.TypeKind }
                      CustomKind.TypeKind
                      ( \(e : { index : Natural, value : CustomKind.TypeKind }) ->
                          if boolAt supported e.index then e.value else CustomKind.TypeKind.Absent
                      )
                      (Prelude.List.indexed CustomKind.TypeKind fixedKindOf)
              else  fixedKindOf

        let indexedResolvedCustomTypes
            : List { index : Natural, value : ResolvedCustomType }
            = Prelude.List.indexed ResolvedCustomType resolvedCustomTypes

        let effectiveResolvedCustomTypes
            : List { index : Natural, value : ResolvedCustomType }
            = if    skip
              then  Prelude.List.filter
                      { index : Natural, value : ResolvedCustomType }
                      (\(e : { index : Natural, value : ResolvedCustomType }) -> boolAt supported e.index)
                      indexedResolvedCustomTypes
              else  indexedResolvedCustomTypes

        let effectiveCustomTypes
            : List { index : Natural, value : Model.CustomType }
            = Prelude.List.map
                { index : Natural, value : ResolvedCustomType }
                { index : Natural, value : Model.CustomType }
                ( \(e : { index : Natural, value : ResolvedCustomType }) ->
                    { index = e.index, value = e.value.value }
                )
                effectiveResolvedCustomTypes
```

This changes `effectiveCustomTypes`'s element type from
`List Model.CustomType` to `List { index : Natural, value : Model.CustomType }`
everywhere it's consumed further down in `run`, so update:

- `typesForCombine` — was
  `Lude.Compiled.traverseList Model.CustomType CustomTypeGen.Output (\(ct : Model.CustomType) -> CustomTypeGen.run customTypeConfig lookup ct) effectiveCustomTypes`
  becomes
  ```dhall
  Lude.Compiled.traverseList
    { index : Natural, value : Model.CustomType }
    CustomTypeGen.Output
    ( \(e : { index : Natural, value : Model.CustomType }) ->
        CustomTypeGen.run customTypeConfig lookup e.index e.value
    )
    effectiveCustomTypes
  ```
  (note the extra `e.index` argument, matching `CustomTypeGen.run`'s new
  signature from this task's `CustomType.dhall` change above).
- Anywhere else `effectiveCustomTypes` is used as a plain
  `List Model.CustomType` (check `combineOutputs`'s call and any other
  reference in `run` — read the current file to find every use before
  editing) needs either the same `{index,value}` shape or a
  `Prelude.List.map ... (\(e) -> e.value) effectiveCustomTypes` to recover
  the bare list, whichever the specific call site needs. `combineOutputs`
  itself takes `customTypes : List CustomTypeGen.Output` (already-compiled
  output, not `Model.CustomType`), which is unaffected — only the
  *pre-compile* `effectiveCustomTypes`/`typesForCombine` wiring changes.

**Remove entirely** (no longer needed, replaced by the above):
`typeSucceedsWith`, `typeWarningWith`'s use of a per-pass
`candidateLookup` parameter, and the `Natural/fold`-based
`effectiveResolvedCustomTypes` loop. If `skipWarnings` (further down in
`run`) still needs per-type warning `Report`s for `Skip` mode, rebuild it
using the *final* `lookup` (not a shrinking candidate) — i.e.
`typeWarningWith` becomes a plain function of `lookup` (no longer needing a
`candidateLookup` argument at all, since there is only one `lookup` now):
```dhall
let typeWarning =
      \(ct : Model.CustomType) ->
      \(index : Natural) ->
        merge
          { Ok =
              \(_ : { value : CustomTypeGen.Output, warnings : List Report }) ->
                None Report
          , Err =
              \(err : Report) -> Some { path = [ ct.name.inSnakeCase ] # err.path, message = err.message }
          }
          (CustomTypeGen.run customTypeConfig lookup index ct)
```
and its use in `skipWarnings` maps over the **indexed** `input.customTypes`
(so each type is checked at its own real index, not filtered) — mirror
whatever indexing helper you already introduced above rather than
duplicating `Prelude.List.indexed` a third time.

### Docs to update in this task

- `README.md`: the paragraph starting "`fixtures/Exhaustive.dhall` is the
  contract fixture. It and `buildLookup` rely on the pgn fork's `Text/equal`
  builtin..." — `buildLookup` no longer exists or uses `Text/equal`. Correct
  this paragraph to describe the current state: `fixtures/Exhaustive.dhall`
  itself doesn't use `Text/equal`, but the generator's mapping-validation
  code (`queryNameMappings`/`customTypeNameMappings`,
  `validateCustomTypeIdentities`, `PyIdent.dhall`) still does, which is why
  CI still needs the fork-aware evaluator. Don't claim `Text/equal` is gone
  from the repo — it isn't (that's items 6-7, out of scope here).
- `DESIGN.md` section 10, "The pinned `Text/equal` constraint" — this
  section specifically describes `buildLookup`'s mechanism, which this task
  deletes. Rewrite it to describe the new `Sdk.CustomTypes`-based cascade
  (or fold its content into a short note that `buildLookup` was replaced by
  `gen-sdk`'s `CustomTypes` module and point at the remaining `Text/equal`
  users listed above) — do not just delete the section silently; the
  surrounding sections may reference it.
- `DESIGN.md` around line 278/289 (the `-> buildLookup(custom types)` pseudo
  pipeline sketch, and "`onUnsupported: Skip` repeatedly rebuilds
  `buildLookup`...") — update to describe the new one-pass
  `Sdk.CustomTypes.supportedCustomTypesReasoned` mechanism instead of a
  repeated rebuild.
- `CHANGELOG.md`: the existing "Retained `buildLookup`..." bullet (in a
  past/released section, not "Upcoming") describes a past decision that no
  longer holds. Do not edit released history; instead add a new bullet under
  "Upcoming" (per Global Constraints) noting the v5.0.0/v3.0.0 bump and that
  `buildLookup` was replaced by `gen-sdk`'s `CustomTypes` module.
- Leave `docs/upstream-asks.md` alone unless you find it makes a factual
  claim about `buildLookup`'s *current* mechanism (as opposed to the
  upstream ask itself, which is unrelated to this task) — read it first to
  check.

### Tests

`tests/test_unsupported_types.py`'s `_write_contract_probe` helper (around
line 115, feeding the parametrized `test_custom_shape_contracts_fail_loudly`)
hand-authors a synthetic Dhall wrapper module as a Python string. Task 3
already updated it for the v5 contract shape and removed its
`PythonNameMapping` reference; this task needs one more pass, since
`CustomKind.Lookup` changes shape here:
- Its `let lookup : CustomKind.Lookup = \(_ : Model.Name) -> {lookup}`
  construction (a `Model.Name -> TypeKind` closure) must become a
  `List CustomKind.TypeKind` — for these probes there's exactly one custom
  type in play ("ProbeValue"), so `lookup` becomes a one-element list:
  `let lookup : CustomKind.Lookup = [ {lookup} ]`.
- `CustomType.dhall`'s `run` gained an explicit `index : Natural` parameter
  in this task (the self-lookup consistency check). The probe's call site
  (`Target.run interpreterConfig lookup {target_input}`) needs an index
  argument threaded in when `interpreter == "CustomType"` — `0` (matching
  the single-element `lookup` list above). For the `Member`-interpreter
  probes (`interpreter == "Member"`), `Member.dhall`'s `run` signature is
  unaffected by this task (it never needed a self-index, only the
  already-present `ref.index` off the value being looked up) — don't add
  an index argument there.
- Confirm all cases of `test_custom_shape_contracts_fail_loudly` still
  produce the same pass/fail outcomes and error messages after this
  change — this is the test most likely to catch a subtle regression in
  the new `Absent`-on-either-failure masking logic (see this task's "Why
  this shape" section above).

### Verification

Same as Task 1: `mise run test` (expect the same passing count as Task 1
left it at), `mise run lint`, `mise run golden` + `git diff tests/golden`
expecting no diff. Additionally: since this task touches the `Skip`-mode
cascade specifically, if this repo's test suite exercises
`onUnsupported: Skip` (check `tests/` for it), pay particular attention to
those tests passing — this is the behavior most at risk of a subtle
regression from this refactor (see the "Absent-on-either-failure" subtlety
above).

### Report file

Same contract as Task 1: report which files changed, the full `mise run
test` summary, confirmation of clean `git diff tests/golden`, and
explicitly confirm whether any `Skip`-mode-specific test exists and passed.
