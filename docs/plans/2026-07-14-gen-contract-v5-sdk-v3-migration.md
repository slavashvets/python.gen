# Plan: bump gen-contract/gen-sdk pins and retire `buildLookup`'s `Text/equal`

## Background

This implements steps 3-4 of the "Next steps" section in
`docs/plans/2026-07-14-detext-equal-branch-filter.md` (item 4 of that
document's decision table). That document is the record of *why*; this
document is the *how*, broken into two tasks for subagent-driven execution.
Read the background doc if you want the full history — it is not required
reading for either task below, which are self-contained.

Items 5-8 of the background doc (facade un-flattening, discarding collision
detection/rename mappings, dropping the ADR) are explicitly **out of scope**
for this plan — they need design work not yet done and are being handled
separately.

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
- Verification oracle for both tasks: `mise run test` (drives real `pgn`
  subprocesses against the local PostgreSQL server already running on
  `localhost:5432`; `pgn` v0.9.1 is already installed via `mise`). Also run
  `mise run lint`. Do **not** invent a separate `dhall` CLI invocation to
  typecheck `.dhall` files standalone — this repo's `Text/equal` usage
  (unrelated to this migration, e.g. in `PyIdent.dhall`,
  `PythonNamespace.dhall`, `PythonNameMapping.dhall`, and the
  `validateQueryMappings`/`validateCustomTypeMappings`/
  `validateCustomTypeIdentities` functions in `Project.dhall`) requires the
  pgn-fork Dhall evaluator, which only `pgn generate` (invoked by the mise
  tasks) provides locally.
- If `mise run test` fails because `pgn` v0.9.1 does not produce contract
  data compatible with gen-contract v5.0.0 (e.g. it doesn't yet emit a
  topologically-sorted `customTypes` list or the new `CustomTypeRef` shape),
  stop and report `BLOCKED` with the exact failure — do not try to
  work around a `pgn`-side incompatibility from the generator side.
- Do not touch decision-table items 1-3 (`emitSync`, custom-type
  registration/`sameOrder`/`order` field, `PyIdent.dhall`'s reserved-name
  disambiguation) — they are unrelated and already `Text/equal`-free.
- Do not touch `queryNameMappings`/`customTypeNameMappings` validation logic
  or `PythonNameMapping.dhall` — their `Text/equal` usage is unrelated to
  `buildLookup` and is scoped to items 6-7 (out of scope here).
- Regenerate the golden fixture (`mise run golden`) if `pgn generate` output
  changes at all (it should not — this migration changes only the Dhall
  generator's internals, not its emitted Python), and confirm
  `tests/golden` has no diff. If it does diff, treat that as a signal
  something changed unintentionally, not something to silently accept.
- Update the "Upcoming" section of `CHANGELOG.md` with one entry describing
  the pin bump and the elimination of `buildLookup`'s `Text/equal` (after
  Task 2). Follow the existing terse bullet style in that file.

---

## Task 1: Bump pins to gen-contract v5.0.0 / gen-sdk v3.0.0 and fix compile breakage

### Why this shape

Bumping the pin is a breaking change independent of the `buildLookup`
migration (Task 2). Two things changed in the contract:

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
   lookup mechanism, that is Task 2.

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
lookup replacement here — that is Task 2, and mixing the two makes either
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
Task 2). The only things in this file that might need attention from the
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

## Task 2: Replace `buildLookup`/`effectiveResolvedCustomTypes` with `Sdk.CustomTypes`

**Depends on Task 1** (needs the bumped pins and `Model.CustomTypeRef`
plumbing already in place). Do not start this task until Task 1's review is
clean.

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
