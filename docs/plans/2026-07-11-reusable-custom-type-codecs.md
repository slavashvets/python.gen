# Reusable Custom-Type Codecs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete `buildLookup`/`CustomKind.Lookup` — and with it python.gen's last dependency on pgn's forked `Text/equal` builtin (DESIGN.md section 12) — by generating one `_decode`/`_encode` codec per custom type in `types/<module>.py`, called by name from every reference site, instead of re-deriving decode/encode logic (field types, Composite-vs-Enum classification) at each call site.

**Architecture:** `CustomType.dhall` already visits every custom type once with its full definition in hand (composite fields or enum variants) and emits `types/<module>.py`. Today it stops at the dataclass/enum class. This plan makes it also emit a `_decode` staticmethod (and, for composites, an `_encode` instance method) on that same class. Every column/param reference site (`Member.dhall`, `ParamsMember.dhall`) currently has to search `project.customTypes` by name to find out whether it's looking at a composite or an enum, because it re-derives the decode/encode expression inline. Once decode/encode is a named method reachable from the `Name` the reference site already carries (`name.inPascalCase`), the reference site just calls it — no search, no classification, no `Text/equal`.

**Tech Stack:** Dhall (dhall-lang 1.42 vendored via `dhall` CLI; pgn's forked interpreter for the parts still using it), Python 3.12 generated output (psycopg3), basedpyright strict, pytest golden-file harness (`mise run test`, `mise run golden`).

## Global Constraints

- No behavior change to non-custom-type (primitive) decode/encode paths.
- Golden fixture output (`tests/golden/`) must be regenerated and diffed, not hand-edited (per `tests/golden/README.md`).
- `mise run test` (pytest, includes `test_generated_passes_basedpyright_strict`) must pass after regeneration.
- Every Dhall file touched must independently type-check: `dhall type --file=<path>`.
- Don't touch `Primitive.dhall`, `Scalar.dhall`, `Value.dhall`, or the `Model`/`Contract` dependency — this plan is scoped to what python.gen can do unilaterally, with the current, unmodified `Scalar = < Primitive : Primitive | Custom : Name >` contract.

---

## Design decision needed before Task 3: array-of-custom-type behavior

Today, `Member.dhall`'s Custom branch treats arrays differently by kind, because it already knows the kind from `lookup name`:
- **Enum arrays (1-D):** supported — `enumArrayDecode` emits an element-wise list comprehension.
- **Composite arrays:** rejected at generation time — `"Array of a composite type is not supported (element-wise decode is unimplemented)"` (Member.dhall:219) and, for params, `"Array of a composite type as a parameter is not supported"` (ParamsMember.dhall:359).

Once decode/encode become named methods called unconditionally (no classification at the call site), there's no Dhall-level way to keep rejecting *only* composite arrays without reintroducing some form of lookup. Two ways forward:

- **A — Recommended: uniform array codec, kind-specific availability.** Every custom type's template *may* define `_decode_array` (a staticmethod that turns the raw array value into a `list[...]`); `EnumModule.dhall` defines it, `CompositeModule.dhall` does not. `Member.dhall` always emits `f"{typeName}._decode_array({src})"` for a 1-D custom-type array, regardless of kind. If that's ever generated against a composite, `basedpyright strict` (already gating `mise run test`, see `tests/golden/README.md`) fails on the missing attribute — a real check, just moved from `pgn generate` time to CI time. Composite-array *params* work the same way: encode always calls `f"{fieldName}._encode()"`; if `fieldName`'s inferred type is `list[Point2D]`, basedpyright flags the missing `._encode` on `list`. This is a genuine, if later, safety net — not a silent hole. The `"Absent"` case (a `customRef` name matching no generated module) degrades the same way: the emitted `from ..types.<name> import <Name>` fails as an unresolved import, also caught by basedpyright strict.
- **B — Preserve today's exact rejection.** Keep a minimal kind signal alive somewhere reachable without a name search — no such source was found during design (see the exploration notes below); the only ones available (project-wide `customTypes` list, or a `Scalar.Custom` contract change) reintroduce either the search or the upstream ask this plan is explicitly trying to avoid. Pick this only if lifting the composite-array restriction is unacceptable without a live Postgres verification first.

This plan is written for **Option A**. Composite-array support was never tested (DESIGN.md and the fixture corpus have no composite-array column — verified via `grep -rn "^from \.\.types\." tests/golden/`, no file references the same custom type twice, and none of the fixture's composite columns are arrays), so Task 8 includes adding one to the fixture project specifically to exercise this path before it ships. If that Postgres test reveals composite-array decode genuinely doesn't work end-to-end (not just an assumption), fall back to Option B and keep the `"not supported"` report, sourced from a small dedicated check rather than full `buildLookup` (open a follow-up plan; don't block this one on it).

---

## File Structure

| File | Change |
|---|---|
| `src/Templates/CompositeModule.dhall` | Add `_decode` (staticmethod) and `_encode` (instance method) to the generated dataclass. |
| `src/Templates/EnumModule.dhall` | Add `_decode` and `_decode_array` (staticmethods) and `_encode` (instance method, identity) to the generated `StrEnum`. |
| `src/Interpreters/Member.dhall` | Custom branch calls `{typeName}._decode(...)` / `{typeName}._decode_array(...)` unconditionally; drop the `lookup` parameter and the `Enum`/`Composite`/`Absent` merge. |
| `src/Interpreters/ParamsMember.dhall` | Custom branch calls `{fieldName}._encode()` unconditionally; drop `lookup` and the merge. |
| `src/Interpreters/ResultColumns.dhall`, `src/Interpreters/Result.dhall`, `src/Interpreters/Query.dhall` | Drop the `lookup : CustomKind.Lookup` parameter they only thread through. |
| `src/Interpreters/CustomType.dhall` | Drop `nestedLookup` (nothing left to pass it to). |
| `src/Interpreters/Project.dhall` | Delete `buildLookup`, `IndexedCustomType`, `compositeFields`, `memberPyType`, `lookupConfig` — all exist only to feed `buildLookup`. |
| `src/Structures/CustomKind.dhall` | Delete the file; nothing imports it after the above. |
| `python.gen/DESIGN.md` | Rewrite section 12 (no longer an accepted risk — resolved) and section 13 (unchanged content, but cross-reference updates). |
| `python.gen/docs/upstream-asks.md` | Remove ask 3 (resolved without the upstream change) or mark it withdrawn. |
| `tests/golden/` | Regenerate via `mise run golden`. |

---

### Task 1: Add `_decode`/`_encode` to `CompositeModule.dhall`

**Files:**
- Modify: `src/Templates/CompositeModule.dhall`

**Interfaces:**
- Consumes: same `Params = { typeName : Text, extraImports : List Text, fields : List Field }` as today, `Field = { fieldName : Text, fieldType : Text }` — no signature change.
- Produces: the rendered module text now defines `_decode(src: object) -> "<TypeName>"` (staticmethod) and `_encode(self) -> tuple[...]` (instance method) on the dataclass, callable by any generator downstream as `TypeName._decode(x)` / `value._encode()`.

This was prototyped and verified against `dhall type` and `dhall text` (rendered output checked with `python3 -c "compile(...)"` for both a two-field and a one-field composite — the one-field case needs the trailing-comma tuple, same edge case `compositeBind` already handles today).

- [ ] **Step 1: Replace the template body**

```dhall
let Prelude = ../Deps/Prelude.dhall

let Sdk = ../Deps/Sdk.dhall

let Field = { fieldName : Text, fieldType : Text }

-- extraImports are the extra import lines a field type needs (e.g.
-- "from uuid import UUID"). They sit between the dataclass import and the class,
-- separated by one blank line; when empty only the dataclass import is emitted.
let Params = { typeName : Text, extraImports : List Text, fields : List Field }

let run =
      \(params : Params) ->
        let fieldLines =
              Prelude.Text.concatMapSep
                "\n"
                Field
                ( \(field : Field) ->
                    "    ${field.fieldName}: ${field.fieldType}"
                )
                params.fields

        let fieldCount = Prelude.List.length Field params.fields

        let fieldTypesJoined =
              Prelude.Text.concatMapSep
                ", "
                Field
                (\(field : Field) -> field.fieldType)
                params.fields

        let selfFieldsJoined =
              Prelude.Text.concatMapSep
                ", "
                Field
                (\(field : Field) -> "self.${field.fieldName}")
                params.fields

        -- Python only treats trailing-comma parens as a 1-tuple; concatMapSep
        -- never emits an internal comma for a single-element list, so force one
        -- here. Mirrors ParamsMember.dhall's existing compositeBind trick.
        let encodeTupleExpr =
              if    Prelude.Natural.equal fieldCount 1
              then  "(${selfFieldsJoined},)"
              else  "(${selfFieldsJoined})"

        -- _decode/_encode are emitted as literal lines (not a nested multi-line
        -- ''...'' block) because Dhall dedents a multi-line literal against its
        -- OWN source indentation before splicing it into the outer literal; a
        -- nested block loses its intended 4/8-space class-body indentation.
        -- Verified against `dhall text` during design.
        let codecMethods =
                "\n"
              ++ "    @staticmethod\n"
              ++ "    def _decode(src: object) -> \"${params.typeName}\":\n"
              ++ "        return ${params.typeName}(*cast(tuple[${fieldTypesJoined}], src))\n"
              ++ "\n"
              ++ "    def _encode(self) -> tuple[${fieldTypesJoined}]:\n"
              ++ "        return ${encodeTupleExpr}"

        let imports =
              if    Prelude.List.null Text params.extraImports
              then  "from dataclasses import dataclass\nfrom typing import cast"
              else  ''
                    from dataclasses import dataclass
                    from typing import cast

                    ${Prelude.Text.concatSep "\n" params.extraImports}''

        in  ''
            ${imports}


            @dataclass(frozen=True, slots=True)
            class ${params.typeName}:
                """Decoding/encoding this composite requires register_types(conn) first.

                Without per-connection registration psycopg returns the value as a
                raw string, which the generated _decode cannot splat into the dataclass.
                """

            ${fieldLines}
            ${codecMethods}
            ''

in  Sdk.Sigs.template Params run /\ { Field }
```

- [ ] **Step 2: Type-check**

Run: `dhall type --file=src/Templates/CompositeModule.dhall`
Expected: prints the `{ Field : Type, Params : Type, Run : Type, run : ... }` signature, no error.

- [ ] **Step 3: Spot-render and validate as Python**

```bash
cat > /tmp/render_composite.dhall <<'EOF'
let CompositeModule = ./src/Templates/CompositeModule.dhall
in  CompositeModule.run
      { typeName = "Point2D"
      , extraImports = [] : List Text
      , fields =
        [ { fieldName = "x", fieldType = "int" }
        , { fieldName = "y", fieldType = "int" }
        ]
      }
EOF
dhall text --file=/tmp/render_composite.dhall | python3 -c "import sys; compile(sys.stdin.read(), 'point2d.py', 'exec')" && echo OK
```
Expected: `OK`, and eyeballing the output shows `_decode`/`_encode` indented as class members (4 spaces), not module-level.

- [ ] **Step 4: Commit**

```bash
git add src/Templates/CompositeModule.dhall
git commit -m "python.gen: emit _decode/_encode on generated composite dataclasses"
```

---

### Task 2: Add `_decode`/`_decode_array`/`_encode` to `EnumModule.dhall`

**Files:**
- Modify: `src/Templates/EnumModule.dhall`

**Interfaces:**
- Consumes: same `Params = { typeName : Text, variants : List Variant }` — no signature change.
- Produces: `_decode(src: object) -> "<TypeName>"`, `_decode_array(src: object) -> list["<TypeName>"]`, `_encode(self) -> "<TypeName>"` (identity — psycopg binds the `StrEnum` instance directly, matching today's `defaultBind`).

The scalar/array decode bodies are copied verbatim from `Member.dhall`'s current `enumDecode`/`enumArrayDecode` (Member.dhall:61-82), just moved from "Dhall builds inline Python text at every call site" to "Dhall builds it once, into the class."

- [ ] **Step 1: Replace the template body**

```dhall
let Prelude = ../Deps/Prelude.dhall

let Sdk = ../Deps/Sdk.dhall

let Variant = { memberName : Text, pgValue : Text }

let Params = { typeName : Text, variants : List Variant }

let run =
      \(params : Params) ->
        -- pgValue is interpolated into a single-line double-quoted Python literal; a
        -- label may legally contain a backslash, quote, or control character, so
        -- escape them to keep the literal valid and value-equal to the DB label.
        -- Order is load-bearing: backslash first (so the escapes added below are not
        -- re-escaped), then the control chars, then the closing quote.
        let escapeLabel
            : Text -> Text
            = \(raw : Text) ->
                Prelude.Function.composeList
                  Text
                  [ Prelude.Text.replace "\\" "\\\\"
                  , Prelude.Text.replace "\r" "\\r"
                  , Prelude.Text.replace "\n" "\\n"
                  , Prelude.Text.replace "\t" "\\t"
                  , Prelude.Text.replace "\"" "\\\""
                  ]
                  raw

        let memberLines =
              Prelude.Text.concatMapSep
                "\n"
                Variant
                ( \(variant : Variant) ->
                    "    ${variant.memberName} = \"${escapeLabel variant.pgValue}\""
                )
                params.variants

        let codecMethods =
                "\n"
              ++ "    @staticmethod\n"
              ++ "    def _decode(src: object) -> \"${params.typeName}\":\n"
              ++ "        return ${params.typeName}(cast(str, src))\n"
              ++ "\n"
              ++ "    @staticmethod\n"
              ++ "    def _decode_array(src: object) -> list[\"${params.typeName}\"]:\n"
              ++ "        return [\n"
              ++ "            ${params.typeName}(v)\n"
              ++ "            for v in cast(list[str], require_array(src))\n"
              ++ "        ]\n"
              ++ "\n"
              ++ "    def _encode(self) -> \"${params.typeName}\":\n"
              ++ "        return self"

        in  ''
            from enum import StrEnum
            from typing import cast

            from .._runtime import require_array


            class ${params.typeName}(StrEnum):
            ${memberLines}
            ${codecMethods}
            ''

in  Sdk.Sigs.template Params run /\ { Variant }
```

> `require_array` must already be importable from `.._runtime` relative to `types/<module>.py` — confirm the relative import depth matches `types/`'s actual nesting (one level under the package root per `CustomType.dhall`'s `modulePath = "types/${moduleName}.py"`) before running Step 2; adjust to `.._runtime` vs `..._runtime` to match what `Member.dhall`'s current `enumArrayDecode` assumes at its own call sites (check `ImportSet.dhall`'s handling of `require_array` imports today for the exact existing relative path convention, since this moves an existing import from call sites into the shared module).

- [ ] **Step 2: Type-check**

Run: `dhall type --file=src/Templates/EnumModule.dhall`
Expected: signature prints, no error.

- [ ] **Step 3: Spot-render and validate as Python**

```bash
cat > /tmp/render_enum.dhall <<'EOF'
let EnumModule = ./src/Templates/EnumModule.dhall
in  EnumModule.run
      { typeName = "Mood"
      , variants =
        [ { memberName = "HAPPY", pgValue = "happy" }
        , { memberName = "SAD", pgValue = "sad" }
        ]
      }
EOF
dhall text --file=/tmp/render_enum.dhall | python3 -c "import sys; compile(sys.stdin.read(), 'mood.py', 'exec')" && echo OK
```
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add src/Templates/EnumModule.dhall
git commit -m "python.gen: emit _decode/_decode_array/_encode on generated enum classes"
```

---

### Task 3: Simplify `Member.dhall`'s Custom branch

**Files:**
- Modify: `src/Interpreters/Member.dhall`

**Interfaces:**
- Consumes: `value.scalar.customRef : Optional Model.Name` (unchanged — still comes straight off `Scalar.run`, see `src/Interpreters/Scalar.dhall:44-52`), `value.dims : Natural` (unchanged).
- Produces: `Run = Config -> Input -> Lude.Compiled.Type Output` — **drops the `CustomKind.Lookup` parameter**. Every caller (`ResultColumns.dhall`, `CustomType.dhall`) updates in Task 5/6.

- [ ] **Step 1: Replace the Custom branch (Member.dhall:129-232) and the `Run` alias (Member.dhall:245)**

Delete the `merge { Enum = ...; Composite = ...; Absent = ... } (lookup name)` block and the `CustomKind.CompositeField`-typed `compositeDecode` helper (lines 100-116, now dead — the same logic lives in `CompositeModule.dhall`'s `_decode` now). Replace with:

```dhall
                      , Custom =
                          Prelude.Optional.fold
                            Model.Name
                            value.scalar.customRef
                            (Lude.Compiled.Type Output)
                            ( \(name : Model.Name) ->
                                let typeName = name.inPascalCase

                                let customImport =
                                      { className = typeName, moduleName = name.inSnakeCase }

                                let mkOutput =
                                      \(customImports : ImportSet.Type) ->
                                      \(decodeExpr : Text -> Text) ->
                                        { fieldName
                                        , pgName = input.pgName
                                        , pyType
                                        , isNullable = input.isNullable
                                        , imports =
                                            ImportSet.combine baseImports customImports
                                        , decodeExpr
                                        }

                                let wrapNullable =
                                      \(call : Text -> Text) ->
                                      \(src : Text) ->
                                        if    input.isNullable
                                        then  "None if ${src} is None else ${call src}"
                                        else  call src

                                let dimsIsOne =
                                      Natural/isZero (Natural/subtract 1 value.dims)

                                in  if    Natural/isZero value.dims
                                    then  Lude.Compiled.ok
                                            Output
                                            ( mkOutput
                                                (ImportSet.custom customImport)
                                                ( wrapNullable
                                                    (\(src : Text) -> "${typeName}._decode(${src})")
                                                )
                                            )
                                    else  if    dimsIsOne
                                    then  Lude.Compiled.ok
                                            Output
                                            ( mkOutput
                                                (ImportSet.custom customImport)
                                                ( wrapNullable
                                                    ( \(src : Text) ->
                                                        "${typeName}._decode_array(${src})"
                                                    )
                                                )
                                            )
                                    else  Lude.Compiled.report
                                            Output
                                            [ input.pgName, name.inSnakeCase ]
                                            "Array of dimensionality > 1 is not supported"
                            )
                            ( Lude.Compiled.report
                                Output
                                [ input.pgName ]
                                "Custom scalar without a customRef name"
                            )
```

Note this drops the `Enum`/`Composite` import-set split (`ImportSet.customEnum`/`ImportSet.customComposite`) in favor of one `ImportSet.custom` call — see Doc 2 (`2026-07-11-encounter-order-custom-imports.md`) for why `ImportSet.customEnum`/`customComposite` collapse into a single `ImportSet.custom` once `order` no longer exists. **Land Doc 2 in the same branch as this task, or `dhall type` will fail here** — Task 3 depends on `ImportSet.CustomImport` no longer requiring a `dedupKey`/`order` field.

- [ ] **Step 2: Drop the `lookup` parameter from `Run`**

Change:
```dhall
let Run = Config -> CustomKind.Lookup -> Input -> Lude.Compiled.Type Output
```
to:
```dhall
let Run = Config -> Input -> Lude.Compiled.Type Output
```
and the `run` definition's `\(lookup : CustomKind.Lookup) ->` (Member.dhall:40) — delete that line entirely, since `run` no longer takes it.

- [ ] **Step 3: Delete the now-dead `CustomKind` import (Member.dhall:9) and the dead `compositeDecode` helper (Member.dhall:100-116)**

- [ ] **Step 4: Type-check**

Run: `dhall type --file=src/Interpreters/Member.dhall`
Expected: fails until Task 5 updates `ResultColumns.dhall` (Member's only caller) to stop passing `lookup` — that's fine, type-check `Member.dhall` standalone by temporarily checking `Sdk.Sigs.interpreter Config Input Output run` in isolation, or proceed straight to Task 5 and type-check the pair together. Don't commit Task 3 alone; commit Tasks 3+5+6 together (they're one type-checking unit — Dhall won't let you land a signature change without updating every call site in the same change).

---

### Task 4: Simplify `ParamsMember.dhall`'s Custom branch

**Files:**
- Modify: `src/Interpreters/ParamsMember.dhall`

**Interfaces:**
- Consumes: same as Task 3.
- Produces: `Run = Config -> Input -> Lude.Compiled.Type Output` — drops `CustomKind.Lookup`.

- [ ] **Step 1: Replace the Custom branch (ParamsMember.dhall:311-367)**

Delete `compositeBind` (lines 258-288, now dead — logic moved into `CompositeModule.dhall`'s `_encode`) and the `merge { Enum = ...; Composite = ...; Absent = ... } (lookup name)` block. Replace with:

```dhall
                in  Prelude.Optional.fold
                      Model.Name
                      value.scalar.customRef
                      (Lude.Compiled.Type Output)
                      ( \(name : Model.Name) ->
                          let customImport =
                                { className = name.inPascalCase
                                , moduleName = name.inSnakeCase
                                }

                          let encodeExpr =
                                if    input.isNullable
                                then  "None if ${fieldName} is None else ${fieldName}._encode()"
                                else  "${fieldName}._encode()"

                          in  Lude.Compiled.ok
                                Output
                                ( mkOutput
                                    (ImportSet.combine value.imports (ImportSet.custom customImport))
                                    encodeExpr
                                )
                      )
                      ( if    isJsonArrayParam
                        then  Lude.Compiled.report
                                Output
                                [ input.pgName ]
                                "json/jsonb array as a parameter is not supported"
                        else  Lude.Compiled.ok
                                Output
                                (mkOutput value.imports defaultBind)
                      )
```

This drops the `Natural/isZero value.dims` guard that used to reject composite-array params — per the Design decision above (Option A), an array-of-composite param now generates `{fieldName}._encode()` where `fieldName`'s type is `list[Point2D]`; `list` has no `._encode`, so `basedpyright strict` catches it. Confirm this in Task 8's basedpyright run specifically, not just eyeball it.

- [ ] **Step 2: Drop the `lookup` parameter from `Run` (ParamsMember.dhall:387) and `run`'s `\(lookup : CustomKind.Lookup) ->` (ParamsMember.dhall:235)**

- [ ] **Step 3: Delete the dead `CustomKind` import (ParamsMember.dhall:9)**

- [ ] **Step 4: Type-check together with Task 3**

Run: `dhall type --file=src/Interpreters/ParamsMember.dhall`
Expected: same caveat as Task 3 Step 4 — its caller (`Query.dhall`) still passes `lookup` until Task 5.

---

### Task 5: Drop `lookup` threading from `ResultColumns.dhall`, `Result.dhall`, `Query.dhall`

**Files:**
- Modify: `src/Interpreters/ResultColumns.dhall`, `src/Interpreters/Result.dhall`, `src/Interpreters/Query.dhall`

**Interfaces:**
- Each of these only forwards `lookup` to a callee; none inspect it. Removing it is mechanical.

- [ ] **Step 1: `ResultColumns.dhall`** — delete `\(lookup : CustomKind.Lookup) ->` (line 62) and change `Member.run config lookup member` (line 76) to `Member.run config member`. Delete the `CustomKind` import (line 9) if nothing else in the file uses it — verify with `grep -n CustomKind src/Interpreters/ResultColumns.dhall` after editing.

- [ ] **Step 2: `Result.dhall`** — delete both `\(lookup : CustomKind.Lookup) ->` occurrences (lines 66, 93), change `ResultColumns.run config lookup rowClassName columns` (line 89) to `ResultColumns.run config rowClassName columns`, and `rowsOutput config lookup rowClassName` (line 100) to `rowsOutput config rowClassName` — check `rowsOutput`'s own definition for a `lookup` parameter to drop too (it wasn't in the earlier grep excerpt; read the file before editing to confirm). Delete the `CustomKind` import (line 9) if unused after.

- [ ] **Step 3: `Query.dhall`** — delete `\(lookup : CustomKind.Lookup) ->` (line 140), change `ResultModule.run config lookup rowClassName input.result` (line 156) to drop `lookup`, and `ParamsMember.run config lookup member` (line 173) to `ParamsMember.run config member`. Delete the `CustomKind` import (line 7) if unused after.

- [ ] **Step 4: Type-check each file standalone**

Run: `dhall type --file=src/Interpreters/ResultColumns.dhall && dhall type --file=src/Interpreters/Result.dhall && dhall type --file=src/Interpreters/Query.dhall`
Expected: all three print their signatures. `Query.dhall` will still fail until `Project.dhall` (Task 6) stops passing `lookup` to `QueryGen.run` — that's the last link.

---

### Task 6: Delete `buildLookup` and its support code from `Project.dhall`

**Files:**
- Modify: `src/Interpreters/Project.dhall`

- [ ] **Step 1: Delete dead helpers**

Delete, in order (they only exist to feed `buildLookup`, confirmed by re-reading the file top to bottom — nothing else calls `lookupConfig`, `memberPyType`, `compositeFields`, `IndexedCustomType`, or `buildLookup` itself):
- `lookupConfig` (lines 74-80)
- `memberPyType` (lines 85-96)
- `compositeFields` (lines 98-108)
- The local `CompositeField = { fieldName : Text, pyType : Text }` (line 7) — dead once `compositeFields`/`memberPyType` are gone
- `IndexedCustomType` (line 142)
- `buildLookup` (lines 147-181)

- [ ] **Step 2: Update the call site**

Find `let lookup = buildLookup effectiveCustomTypes` (line 479) — delete it, and change both call sites that pass `lookup`:
- `QueryGen.run config lookup query` (line 503) → `QueryGen.run config query`
- `(\(query : Model.Query) -> QueryGen.run config lookup query)` (line 524) → `(\(query : Model.Query) -> QueryGen.run config query)`

- [ ] **Step 3: Delete the dead `CustomKind` import (line 9)**

- [ ] **Step 4: Type-check the whole chain**

Run: `dhall type --file=src/Interpreters/Project.dhall`
Expected: prints the module signature with no error — this is the point where Tasks 3-6 all click together (Project → Query → Result/ParamsMember → ResultColumns/Member all now agree on the lookup-free signatures).

- [ ] **Step 5: Commit Tasks 3-6 together**

```bash
git add src/Interpreters/Member.dhall src/Interpreters/ParamsMember.dhall \
        src/Interpreters/ResultColumns.dhall src/Interpreters/Result.dhall \
        src/Interpreters/Query.dhall src/Interpreters/Project.dhall
git commit -m "python.gen: call custom-type codecs by name instead of resolving via buildLookup"
```

---

### Task 7: Drop `nestedLookup` from `CustomType.dhall`, delete `CustomKind.dhall`

**Files:**
- Modify: `src/Interpreters/CustomType.dhall`
- Delete: `src/Structures/CustomKind.dhall`

- [ ] **Step 1: `CustomType.dhall`** — delete `nestedLookup` (lines 51-53) and its comment, and change `MemberGen.run config nestedLookup m` (line 127) to `MemberGen.run config m`. Delete the `CustomKind` import (line 11).

- [ ] **Step 2: Confirm nothing else references `CustomKind`**

Run: `grep -rln "CustomKind" src`
Expected: no output.

- [ ] **Step 3: Delete the file**

```bash
git rm src/Structures/CustomKind.dhall
```

- [ ] **Step 4: Type-check the full package entry point**

Run: `dhall type --file=src/package.dhall`
Expected: prints the top-level module signature, no error. (This is the first point a full-package check is meaningful — earlier steps only checked individual interpreter files.)

- [ ] **Step 5: Commit**

```bash
git add src/Interpreters/CustomType.dhall
git commit -m "python.gen: delete CustomKind.dhall, the last remnant of buildLookup"
```

---

### Task 8: Regenerate golden fixtures, verify, update docs

**Files:**
- Modify: `tests/fixture-project/` (add a composite-array column per the Design decision above)
- Regenerate: `tests/golden/`
- Modify: `python.gen/DESIGN.md`, `python.gen/docs/upstream-asks.md`, `python.gen/CHANGELOG.md`

- [ ] **Step 1: Add a composite-array test column to the fixture project**

Find the fixture's composite-type column definitions under `tests/fixture-project/` (query/table SQL referencing a composite type, e.g. the `Point2D`-typed column used in `insert_specimen`/`get_specimen` per the golden output). Add one query or column that selects/inserts an *array* of that composite type — this is the first real exercise of the Option A fallback path (`basedpyright strict` should catch it if `_decode_array`/`_encode` aren't defined on `Point2D`, since Task 1 deliberately didn't add them to `CompositeModule.dhall`).

Confirm the expected failure mode first:

Run: `mise run golden` (needs `PGN_TEST_DATABASE_URL` pointing at a live Postgres — see `tests/golden/README.md`)
Expected: generation succeeds (no Dhall-level rejection — that's the point of Option A), but the regenerated file calls `Point2D._decode_array(...)` or `list[Point2D]._encode()`-shaped code that doesn't exist.

Run: `mise run test`
Expected: `test_generated_passes_basedpyright_strict` FAILS, citing the missing attribute. This confirms the safety net from the Design decision actually fires. Once confirmed, either:
  - revert the fixture addition (if you don't want composite arrays in the committed golden corpus yet), or
  - implement `_decode_array`/an array-aware `_encode` on `CompositeModule.dhall` for real and keep the fixture (a follow-up, out of this plan's scope — flag it, don't scope-creep this task).

- [ ] **Step 2: Remove the composite-array addition (unless implementing it for real per Step 1)**

- [ ] **Step 3: Regenerate golden for real**

Run: `mise run golden`
Expected: succeeds, rewrites `tests/golden/src/specimen_client/_generated/**` and both facades.

- [ ] **Step 4: Review the diff**

Run: `git diff tests/golden`
Expected: every composite/enum decode/encode call site now reads `TypeName._decode(...)`/`TypeName._decode_array(...)`/`value._encode()` instead of the old inlined `cast(tuple[...], ...)`/`(x.a, x.b)` expressions; `types/point_2_d.py`, `types/mood.py`, `types/tag_value.py` each gain the new methods. No unrelated files change.

- [ ] **Step 5: Run the full test suite**

Run: `mise run test`
Expected: all pass, including `test_generated_passes_basedpyright_strict`.

- [ ] **Step 6: Update `DESIGN.md`**

Rewrite section 12 (`## 12. Forked-Dhall (Text/equal) dependency risk`) — it's no longer an accepted risk for python.gen; state plainly that `buildLookup` is gone and `Text/equal` is no longer used anywhere in this generator's own Dhall source (grep to confirm: `grep -rn "Text/equal" src` returns nothing). Keep a short note that `demos/Exhaustive.dhall`/`mise run golden` still needs the pinned pgn binary regardless, because `gen-sdk`'s own `Fixtures` module independently uses the fork builtin — this plan doesn't touch that, and it isn't blocked on it. Cross-reference section 13 (unchanged — `PyIdent.dhall`'s trick is unrelated and still in place).

- [ ] **Step 7: Update `docs/upstream-asks.md`**

Remove ask 3 (`## 3. gen-sdk: kind tag or Natural index on Scalar.Custom`) or mark it explicitly withdrawn with one line explaining why (`buildLookup`'s only consumer was resolved locally by generating named codecs instead of resolving structural type info by search — see `docs/plans/2026-07-11-reusable-custom-type-codecs.md`). Don't delete the file's other two asks (pragma parsing, warnings printing) — they're unrelated and still open.

- [ ] **Step 8: Update `CHANGELOG.md`**

Add an entry under the appropriate section describing the behavior change from the Design decision (composite-array columns/params no longer rejected at generation time; verify at basedpyright-strict time instead) if Step 1's fixture addition was kept, or note it as a documented-but-untested path if reverted.

- [ ] **Step 9: Commit**

```bash
git add tests/golden tests/fixture-project python.gen/DESIGN.md python.gen/docs/upstream-asks.md python.gen/CHANGELOG.md
git commit -m "python.gen: regenerate golden fixtures for reusable custom-type codecs"
```

---

## Self-Review

**Spec coverage:** Task 1-2 build the reusable codecs (the actual "fix the root cause"). Tasks 3-4 make the two reference sites (decode, encode) call them. Tasks 5-7 remove the now-dead plumbing (`lookup` threading, `buildLookup`, `CustomKind.dhall`) so nothing is left half-migrated. Task 8 proves it against the real toolchain and updates the two docs (`DESIGN.md`, `upstream-asks.md`) that currently assert this is unfixable — both would otherwise go stale and mislead the next reader.

**Open question carried forward, not silently resolved:** the array-of-composite behavior change (Design decision, Option A vs B) is a real product decision, flagged explicitly rather than picked unilaterally in the diff. Task 8 Step 1 is designed to surface the actual runtime behavior (does `basedpyright strict` really catch it, does composite-array decode actually work against real Postgres) before committing to either branch.

**Dependency on the companion plan:** Task 3 explicitly calls out that it needs `docs/plans/2026-07-11-encounter-order-custom-imports.md` (`ImportSet.dhall`'s `order`/`dedupKey` removal) landed first or alongside — `ImportSet.customEnum`/`customComposite` currently *require* an `order : Natural` that only `buildLookup` produced. Implement that plan first, or fold both into one PR; don't land this plan's Task 3 against the unmodified `ImportSet.dhall`.

## Execution Handoff

Plan complete and saved to `python.gen/docs/plans/2026-07-11-reusable-custom-type-codecs.md`. Two execution options:

**1. Subagent-Driven (recommended)** - dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
