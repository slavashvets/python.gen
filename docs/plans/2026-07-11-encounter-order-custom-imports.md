# Encounter-Order Custom-Type Imports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop requiring a project-wide `order : Natural` to sort and dedupe custom-type import lines in `ImportSet.dhall`. Emit them in encounter order (the order the referencing columns/params are declared) instead, and accept that de-duplicating two references to the *same* custom type within one file is not achievable in vanilla Dhall — verify it isn't actually needed by the current corpus, and document the tradeoff rather than reintroduing a lookup to avoid it.

**Architecture:** `ImportSet.dhall` today dedupes and alphabetizes custom-type imports by carrying a `dedupKey : Natural` — the type's alphabetical index in `project.customTypes` — through every `CustomImport` value, specifically because Dhall has no `Text` comparison to sort or dedupe on `moduleName`/`className` directly (see the file's own header comment). That `order` value's only source was `buildLookup` (`Interpreters/Project.dhall`), which the companion plan (`2026-07-11-reusable-custom-type-codecs.md`) deletes. Once it's gone, `ImportSet.dhall` has nothing to key on. Rather than re-deriving a Natural surrogate some other way, this plan removes the sort/dedup step and lets `ImportSet.combine`'s existing `List/fold` order (already the query's declared column/param order — a real, already-computed, non-Text-comparison ordering) stand as the output order.

**Tech Stack:** Dhall (dhall-lang 1.42), Python 3.12 generated output, pytest golden-file harness (`mise run test`, `mise run golden`).

## Global Constraints

- **Depends on** `docs/plans/2026-07-11-reusable-custom-type-codecs.md` — that plan's Task 3/4 call `ImportSet.custom customImport` (no `order` argument). Land this plan's Task 1 first, or in the same PR; `ImportSet.customEnum`/`customComposite` (which this plan deletes) are exactly what those tasks stop calling.
- No behavior change to the four already-Natural-keyed stdlib import flags (`uuid`, `datetime`, `date`, `time`, `timedelta`, `decimal`, `jsonb`, `json`, `jsonValue`, `enumArray`) — those are plain `Bool` OR's today and are untouched by this plan.
- Golden fixture output must be regenerated and diffed (`tests/golden/`), not hand-edited.
- Every Dhall file touched must independently type-check: `dhall type --file=<path>`.

---

## Why dedup can't be preserved without reintroducing a lookup

Worth writing down since it's not obvious and the temptation to "just find a clever `Text/replace` trick" is real — this was checked directly against `PyIdent.dhall`'s working pattern (DESIGN.md section 13) before concluding it doesn't generalize:

`PyIdent.dhall`'s `sanitizeAgainst` tests a runtime `Text` against a small, **fixed, compile-time-literal** candidate list (the 35 Python keywords) — one known literal at a time, folded. That's why the two-`Text/replace` trick works: one side of every comparison is always a literal.

Import dedup needs the opposite shape: is this **runtime** `moduleName` (derived from a `Name` that varies per project) equal to any of the **other runtime** `moduleName`s already collected? Both sides are dynamic. No sequence of `Text/replace` calls can decide that, because deciding it requires producing a `Bool` from two non-literal `Text` values, which is exactly the operation Dhall doesn't have (and which pgn's forked `Text/equal` exists to provide). This isn't a missing trick — dedup of dynamically-computed `Text` is unconditionally impossible in vanilla Dhall. The only ways to get it back are: (a) a fork builtin (what we're removing), (b) a pre-assigned `Natural` id per distinct value (what `order` was — sourced from a project-wide search, i.e. `buildLookup`, also being removed), or (c) don't need it.

This plan takes (c), having checked how much it costs to:

```bash
grep -rl "^from \.\.types\." tests/golden/src 2>/dev/null | while read f; do
  n=$(grep -c "^from \.\.types\." "$f")
  [ "$n" -gt 1 ] && echo "$f: $n"
done
```

No output — verified during design (see conversation record / re-run before Task 2 to confirm it's still true after Doc 1's regeneration). No file in the current fixture corpus imports the same custom type twice. The risk is real but currently unexercised: if a future query selects the same composite/enum type via two different columns, the generated file will contain two identical `from ..types.X import Y` lines — syntactically valid, harmless to `basedpyright strict` and to Python's import system, just visually redundant. Task 2 adds a corpus case that exercises this on purpose so the tradeoff is documented against real output, not just asserted.

---

## File Structure

| File | Change |
|---|---|
| `src/Structures/ImportSet.dhall` | Drop `dedupKey` from `CustomImport`; delete `dedupCustoms`, `sortCustoms`, `eqNat`, `leNat`, `sortedCustoms`; collapse `customEnum`/`customComposite` into the existing `custom`; `combine` plain-concatenates `customTypes` instead of deduping. |
| `src/Templates/RowsModule.dhall`, `src/Templates/StatementModule.dhall` | Read `imports.customTypes` directly instead of `ImportSet.sortedCustoms imports`. |
| `tests/golden/` | Regenerate via `mise run golden`; review the (likely negligible) reordering of custom-type import lines from alphabetical to declaration order. |
| `python.gen/DESIGN.md` | Note the ordering change where section 12/13 currently describe the alphabetical-by-`order` scheme. |

---

### Task 1: Simplify `ImportSet.dhall`

**Files:**
- Modify: `src/Structures/ImportSet.dhall`

**Interfaces:**
- `CustomImport` loses `dedupKey : Natural` → becomes `{ className : Text, moduleName : Text }`.
- `custom : CustomImport -> Self` — unchanged signature, now the only constructor (no more `customEnum`/`customComposite`).
- `combine : Self -> Self -> Self` — `customTypes` field is now a plain list concatenation.
- `sortedCustoms` is deleted. Callers read `.customTypes` directly.

- [ ] **Step 1: Replace the file**

```dhall
let Prelude = ../Deps/Prelude.dhall

-- A custom-type import line: "from ..types.<moduleName> import <className>".
-- Emitted in encounter order (the order the referencing columns/params were
-- declared), not sorted. Dhall (upstream) has no Text comparison, so there is
-- no way to alphabetize or dedupe by moduleName/className without either the
-- pgn fork's Text/equal or a project-wide Natural id (previously `order`,
-- sourced from Project.dhall's buildLookup — see
-- docs/plans/2026-07-11-encounter-order-custom-imports.md for why that's
-- gone and why dedup isn't reintroduced some other way). Two references to
-- the same type currently produce two identical lines; harmless to Python
-- and to basedpyright, just not deduped.
let CustomImport = { className : Text, moduleName : Text }

let Self =
      { uuid : Bool
      , datetime : Bool
      , date : Bool
      , time : Bool
      , timedelta : Bool
      , decimal : Bool
      , jsonb : Bool
      , json : Bool
      , jsonValue : Bool
      , enumArray : Bool
      , customTypes : List CustomImport
      }

let base =
      { uuid = False
      , datetime = False
      , date = False
      , time = False
      , timedelta = False
      , decimal = False
      , jsonb = False
      , json = False
      , jsonValue = False
      , enumArray = False
      , customTypes = [] : List CustomImport
      }

let empty
    : Self
    = base

let uuid
    : Self
    = base // { uuid = True }

let datetime
    : Self
    = base // { datetime = True }

let date
    : Self
    = base // { date = True }

let time
    : Self
    = base // { time = True }

let timedelta
    : Self
    = base // { timedelta = True }

let decimal
    : Self
    = base // { decimal = True }

let jsonb
    : Self
    = base // { jsonb = True }

let json
    : Self
    = base // { json = True }

let jsonValue
    : Self
    = base // { jsonValue = True }

let enumArray
    : Self
    = base // { enumArray = True }

let custom
    : CustomImport -> Self
    = \(c : CustomImport) -> base // { customTypes = [ c ] }

let combine =
      \(left : Self) ->
      \(right : Self) ->
        { uuid = left.uuid || right.uuid
        , datetime = left.datetime || right.datetime
        , date = left.date || right.date
        , time = left.time || right.time
        , timedelta = left.timedelta || right.timedelta
        , decimal = left.decimal || right.decimal
        , jsonb = left.jsonb || right.jsonb
        , json = left.json || right.json
        , jsonValue = left.jsonValue || right.jsonValue
        , enumArray = left.enumArray || right.enumArray
        , customTypes = left.customTypes # right.customTypes
        }

let combineAll
    : List Self -> Self
    = \(sets : List Self) -> List/fold Self sets Self combine empty

in  { Type = Self
    , CustomImport
    , empty
    , uuid
    , datetime
    , date
    , time
    , timedelta
    , decimal
    , jsonb
    , json
    , jsonValue
    , enumArray
    , custom
    , combine
    , combineAll
    }
```

- [ ] **Step 2: Type-check**

Run: `dhall type --file=src/Structures/ImportSet.dhall`
Expected: prints the record-of-functions signature, no error.

- [ ] **Step 3: Commit**

```bash
git add src/Structures/ImportSet.dhall
git commit -m "python.gen: drop order-based sort/dedup from ImportSet, use encounter order"
```

---

### Task 2: Update the two render call sites

**Files:**
- Modify: `src/Templates/RowsModule.dhall`, `src/Templates/StatementModule.dhall`

- [ ] **Step 1: `RowsModule.dhall:58`**

Change:
```dhall
          (ImportSet.sortedCustoms imports)
```
to:
```dhall
          imports.customTypes
```

- [ ] **Step 2: `StatementModule.dhall:82`**

Same change:
```dhall
          imports.customTypes
```

- [ ] **Step 3: Type-check both**

Run: `dhall type --file=src/Templates/RowsModule.dhall && dhall type --file=src/Templates/StatementModule.dhall`
Expected: both print their signatures, no error.

- [ ] **Step 4: Commit**

```bash
git add src/Templates/RowsModule.dhall src/Templates/StatementModule.dhall
git commit -m "python.gen: render custom-type imports in encounter order"
```

---

### Task 3: Regenerate golden fixtures and verify the dedup gap directly

**Files:**
- Modify: `tests/fixture-project/` (temporary, to exercise the dedup gap — see Step 1)
- Regenerate: `tests/golden/`

- [ ] **Step 1: Confirm today's corpus has no same-type-twice case**

Run:
```bash
grep -rl "^from \.\.types\." tests/golden/src 2>/dev/null | while read f; do
  n=$(grep -c "^from \.\.types\." "$f")
  [ "$n" -gt 1 ] && echo "$f: $n"
done
```
Expected: no output (re-confirms the design-time check above, against the *current* golden tree before this plan's regeneration).

- [ ] **Step 2: Regenerate golden**

Run: `mise run golden`
Expected: succeeds. `git diff tests/golden` shows custom-type import lines reordered from alphabetical to declaration order in files with 2+ distinct custom-type imports (e.g. wherever `Mood` and `Point2D` are both imported today — check whether the query's own column order already happens to be alphabetical for that file; if so the diff is empty there and this is confirmed low-risk for the current corpus).

- [ ] **Step 3: Deliberately add a same-type-twice column to the fixture project**

Add a query (or extend an existing one) whose result row or param list references the *same* composite or enum type through two different columns/params — e.g. two `mood`-typed columns in one query. This is new fixture surface, not present today; add it under `tests/fixture-project/queries/`.

Run: `mise run golden`
Expected: succeeds; the regenerated file for that query contains **two** identical `from ..types.mood import Mood` lines (confirm with `grep -c` on the specific file). This is the one visible, accepted consequence of this plan — capture it in the diff review, don't silently let it slip into `tests/golden` unremarked.

- [ ] **Step 4: Decide whether to keep the same-type-twice fixture case**

Keeping it in the committed corpus makes the tradeoff a permanent, visible regression test (future readers see the duplicate import and the comment in `ImportSet.dhall` explaining it, instead of being surprised by it later). Removing it keeps the golden diff minimal for this change. Either is fine — this plan recommends **keeping it**, since an accepted-but-invisible tradeoff tends to resurface as a bug report; make the call and note it in the commit message either way.

- [ ] **Step 5: Run the full test suite**

Run: `mise run test`
Expected: all pass. Duplicate import lines don't fail `basedpyright strict` (Python tolerates redundant imports) or the golden byte-comparison (it compares against the freshly-committed golden, not some independent expectation).

- [ ] **Step 6: Commit**

```bash
git add tests/golden tests/fixture-project
git commit -m "python.gen: regenerate golden fixtures for encounter-order imports"
```

---

### Task 4: Update `DESIGN.md`

**Files:**
- Modify: `python.gen/DESIGN.md`

- [ ] **Step 1: Update section 12/13 cross-references**

Wherever DESIGN.md currently describes `order`/alphabetical import sorting (it's referenced in passing around sections 12-13 and in code comments already updated by `docs/plans/2026-07-11-reusable-custom-type-codecs.md`'s Task 8), add a short note: custom-type imports are emitted in encounter (declaration) order, not sorted, since the `order` Natural no longer exists once `buildLookup` is gone; same-type-twice references are not deduped (a Dhall limitation, not an oversight — see `src/Structures/ImportSet.dhall`'s header comment for the full reasoning). Point at the fixture case from Task 3 if kept.

- [ ] **Step 2: Commit**

```bash
git add python.gen/DESIGN.md
git commit -m "python.gen: document encounter-order custom-type imports in DESIGN.md"
```

---

## Self-Review

**Spec coverage:** Task 1 is the actual mechanism change (drop the Natural key, drop sort/dedup). Task 2 fixes the two render call sites that would otherwise reference a deleted `sortedCustoms`. Task 3 regenerates and — importantly — deliberately exercises the one behavior change (duplicate imports for a same-type-twice reference) instead of letting it go unverified. Task 4 keeps DESIGN.md truthful.

**Placeholder scan:** no TBDs; every step names an exact file, an exact diff, or an exact command with expected output.

**Dependency on the companion plan:** called out at the top (Global Constraints) and repeated in the companion plan's own self-review — `docs/plans/2026-07-11-reusable-custom-type-codecs.md` Task 3/4 call `ImportSet.custom` with no `order` argument, which only type-checks after this plan's Task 1. Sequence: this plan's Task 1 → companion plan's Tasks 3-6 → this plan's Tasks 2-4 (Task 2 touches templates the companion plan doesn't touch, so it can land anytime after Task 1, but golden regeneration in either plan's Task 8/3 should happen once, after both are code-complete, not twice).

## Execution Handoff

Plan complete and saved to `python.gen/docs/plans/2026-07-11-encounter-order-custom-imports.md`. Two execution options:

**1. Subagent-Driven (recommended)** - dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
