# Handoff: filtering `fix-collision-stuff/2` down to what survives without `Text/equal`

## Why this exists

`fix-collision-stuff/2` accumulated 15 commits (all by Viacheslav Shvets)
since base commit `7b876a3e4f80d764ec16eff802288ec28ccda920`, several of
which lean on `Text/equal` — an experimental, pgn-fork-only Dhall builtin
that is going away in a future pgn/Dhall release. Stock Dhall has no text
equality primitive at all (a deliberate upstream omission), so any code
depending on `Text/equal` needs to be either eliminated or explicitly
accepted as blocked debt. This document is the outcome of a full audit of
which parts survive and which don't, and why.

**Status when this was written:** decisions are locked (see table below).
Implementation has **not** started. Nikita was going to attempt a
gen-contract change first (see item 4) before any code gets written here,
since that changes what "keep, flagged as blocked" for `buildLookup` should
actually look like.

**Update 2026-07-14 (later the same day):** the gen-contract change
happened and shipped — `gen-contract` v5.0.0 and `gen-sdk` v3.0.0 are now
released. Item 4 is no longer blocked debt; see its updated row and the
rewritten "What #4 needs" section below (now "What #4 gets"). This branch's
pins (`src/Deps/Contract.dhall` at v4.0.1, `src/Deps/Sdk.dhall` at v2.0.0)
have **not** been bumped yet — that bump plus the resulting migration is
now the actual next step, not a hypothetical.

## Decision table

| # | Item | Disposition |
|---|---|---|
| 1 | `emitSync` — dual sync+async generation in one module (`e46dc96`, `a1ac9f8`, `e7d1e6b`) | **Keep as-is.** Confirmed zero `Text/equal` dependency. |
| 2 | Custom type registration — psycopg-native adapter binding, dependency-ordered via a `Natural` `order` field (`bac8f95`, `375ba6f`) | **Keep as-is.** The registration/ordering mechanism itself is zero `Text/equal` (`sameOrder` uses `Natural/subtract`, not text comparison). |
| 3 | `50f74fa`'s module-internal reserved-name disambiguation (`querySafeName`, `moduleReservedNames`, `parameterSafeName` in `PyIdent.dhall`) | **Keep as-is.** Necessary regardless of any collision-detection decision (stops e.g. a query named `date` from shadowing its own generated file's `from datetime import date`), and already `Text/equal`-free via the same fixed-list `Text/replace` trick as Python-keyword escaping. |
| 4 | `buildLookup` (`5147204`, `Interpreters/Project.dhall:590-611`) — backs `onUnsupported: Skip`'s cascade removal and the empirically-verified rank-limit validation (composite arrays ≤1 dim, enum arrays ≤2 dims) | **Resolved, not yet implemented.** `gen-contract` v5.0.0 + `gen-sdk` v3.0.0 (released 2026-07-14) eliminate the need for `buildLookup`, `Text/equal`, and the hand-rolled `CustomKind.Lookup`/`Natural/fold` cascade entirely — see "What #4 gets" below. This branch's pins are still on v4.0.1/v2.0.0; bumping them and migrating `Interpreters/Project.dhall`/`Scalar.dhall`/`Structures/CustomKind.dhall` is now real work, not a keep-as-debt decision. |
| 5 | Flat top-level package facade (re-exports every query/type/core symbol into one shared top-level namespace) | **Replace.** Un-flatten into per-kind sub-namespaces (statements get their own namespace, types get their own). This is new work, not a keep/discard of an existing commit. |
| 6 | Same-kind collision *detection* (two queries, or two custom types, whose generated names collide with each other — as opposed to cross-kind collisions, which item 5 eliminates structurally) | **Discard.** Risk accepted; pushed upstream instead. Filed [pgenie-io/pgenie#75](https://github.com/pgenie-io/pgenie/issues/75) asking pgn to reject non-normalized query filenames and guarantee unique custom-type identities at the source. |
| 7 | Manual rename-override feature (`queryNameMappings`/`customTypeNameMappings` config, `Structures/PythonNameMapping.dhall`) | **Discard entirely.** Wasn't on the original keep-list; not needed once detection (item 6) is dropped; was the last thing in the collision cluster still needing `Text/equal` (to match a reference's name against a configured mapping's source). |
| 8 | `docs/adr/0001-generated-python-name-collisions.md` and related docs (`DESIGN.md`, `README.md`, `CHANGELOG.md` sections describing the flat facade / collision detection / rename mappings) | **Drop the ADR outright** (decided 2026-07-14, superseding the earlier "rewrite" plan). Related doc sections describing the now-discarded flat-facade/detection/rename-mapping behavior still need rewriting or removal to match the new state — not a blanket drop, just the ADR itself. |
| — | Tests exercising discarded behavior (`test_python_name_collisions.py`, `test_takeover_contract.py`) | Rewrite/remove to match — `test_python_name_collisions.py` specifically tests the collision-detection and rename-mapping mechanisms being discarded; `test_takeover_contract.py` locks in flat-facade output that item 5 changes. |

## What #4 (buildLookup) gets from gen-contract v5.0.0 / gen-sdk v3.0.0

Both shipped 2026-07-14. What landed is better than the `id`/`kind`
addition originally drafted here: `gen-sdk` ships a ready-made,
`Text/equal`-free replacement for the whole cascade, not just the
identity tag.

**gen-contract v5.0.0** (`Scalar.Custom` breaking change, commit
`e10128f`): the bare `Name` becomes a resolvable `CustomTypeRef`:

```dhall
let CustomTypeRef =
      { name : Name, pgSchema : Text, pgName : Text, index : Natural }

let Scalar = < Primitive : Primitive | Custom : CustomTypeRef >
```

`index` points into `Project.customTypes : List CustomType`, and the
contract now guarantees that list is **topologically sorted**: every index
reachable from `customTypes[i]` is `< i`. So a reference resolves via
`Prelude.List.index ref.index _ project.customTypes` — a Natural-indexed
list lookup — never a name search, never `Text/equal`. Getting the
referenced type's *kind* (Composite/Enum/Domain) is then a plain union
`merge` on `.definition`, also `Text/equal`-free.

**gen-sdk v3.0.0** (commit `bba067e` et al., pinned to gen-contract v5.0.0):
adds a `CustomTypes` module built on exactly one topological left fold over
`Project.customTypes`, exposing:

- `supportedCustomTypes : (CustomTypeDefinition -> Bool) -> List CustomType -> List Bool` —
  per-type supported/unsupported, propagated through nested
  Composite/Domain dependencies via index lookups into the fold's own
  running output (no re-traversal, no `Natural/fold`-over-`List/filter`
  cascade like `effectiveResolvedCustomTypes` currently does).
- `supportedCustomTypesReasoned` — same fold, but returns the *root-cause*
  `CustomTypeRef` for each unsupported type instead of a bare `Bool`
  (useful for warning messages).
- `customTypeIsSupported : List Bool -> CustomTypeRef -> Bool` and
  `queryIsSupported : List Bool -> Query -> Bool` — given the fold's output,
  answer whether a specific reference or an entire query (all its params
  and result columns, transitively) survives.

This directly supersedes python.gen's own `buildLookup` +
`effectiveResolvedCustomTypes` cascade-removal loop
(`Interpreters/Project.dhall:1174-1204`), which was reinventing the same
topological propagation with repeated `Natural/fold` passes over
`Text/equal`-keyed lookups because the input wasn't guaranteed sorted
before. It does **not** replace the rank-limit checks in
`ParamsMember.dhall:294/318` and `Member.dhall:92/109` (array of enum >2
dims / composite >1 dim) — those are python.gen-specific and still need to
know a referenced type's kind, but can now get it directly off
`ref.index` (via a `List CustomKind.TypeKind` built once, index-aligned
with `project.customTypes`, mirroring gen-sdk's own `List Bool` pattern)
instead of through `Structures/CustomKind.dhall`'s `Model.Name -> TypeKind`
closure and its `Text/equal`-based construction in `buildLookup`.

Net effect once migrated: `buildLookup`, `Structures/CustomKind.dhall`'s
`Lookup` type, and the `Text/equal` call at
`Interpreters/Project.dhall:601` all go away. `Structures/CustomKind.dhall`
likely still keeps `TypeKind`/`Identity` (renamed/reshaped to be
index-keyed) since `CustomTypeGen.run` and the Python codegen side still
need the className/moduleName/order identity — only the *lookup mechanism*
is replaced, not the whole module.

Relevant pins for the migration (computed via `dhall hash`, not raw file
`shasum` — Dhall pins are semantic-CBOR hashes, not byte hashes):

```
-- src/Deps/Contract.dhall
https://raw.githubusercontent.com/pgenie-io/gen-contract/v5.0.0/src/package.dhall
  sha256:a1b48fe025c5536b13907bcd2db307cd438f3ae0f67a59222b3aa39e4bdac9ef

-- src/Deps/Sdk.dhall
https://raw.githubusercontent.com/pgenie-io/gen-sdk/v3.0.0/src/package.dhall
  sha256:368e4ee1f7557e8a1713a0ac53db6bbfb476027b322d06a660842e5e22e18662
```

Both changelogs (`gen-contract` v5.0.0, `gen-sdk` v3.0.0) explicitly call
out the `Scalar.Custom` shape as a **breaking change** — bumping the pin
alone will not compile; every site currently pattern-matching
`Scalar.Custom` with a bare `Name` (`Interpreters/Scalar.dhall:43-51` at
minimum) breaks and needs updating to destructure `CustomTypeRef` instead.
gen-sdk v3.0.0's `Fixtures/Exhaustive.dhall` also grew a domain custom type
and a composite-over-domain type in a non-`public` schema with a
divergent `pgName`, specifically to exercise this — python.gen's own
fixtures/golden tests should be checked against that once the pin bumps.

Full background, live evidence (reproduced `pgn generate` runs showing the
old Skip-cascade and rank-limit behavior in detail), and the historical
context of why `buildLookup` was withdrawn-then-reinstated live in the
companion note: `/private/tmp/claude-501/-Users-mojojojo-repos-pgenie-python-gen/018e3c75-72c2-414c-af89-0e300db2f020/scratchpad/handoff-buildlookup-text-equal.md`
(session-local scratch path, from the *original* audit session — may
already be cleaned up; copy anything worth keeping into this repo).

## What the facade un-flattening (item 5) needs to look like

Not yet designed. The current flat facade
(`tests/golden/src/specimen_client/__init__.py`) does e.g.:

```python
from ._generated._core import JsonValue as JsonValue
from ._generated.statements.get_specimen import GetSpecimenRow as GetSpecimenRow
```

— everything at one flat top level. The replacement needs statements and
types each importable from their own sub-namespace instead, so that e.g. a
custom type named `json_value` and the reserved core symbol `JsonValue`
never land in the same importable namespace, and a query's `FooRow` and an
unrelated custom type also named `foo_row` don't either. Exact shape
(e.g. `from mypackage.statements import get_specimen` /
`from mypackage.types import Mood` vs. some other split) still needs
deciding — this was flagged during the grill as needing design work, not
resolved in detail.

Note this interacts with the "takeover-ready client" ergonomics work
(`1a5de19`, `ae2869c`) which specifically aimed for a flat, single-import
surface — un-flattening is a deliberate reversal of that goal, traded for
structural collision-safety. `5ac6d49`'s `test_takeover_contract.py` and
`a1ac9f8`'s Ruff-ordering fix both assume the flat shape and will need
rework.

## What's already done, independent of the above

- **[pgenie-io/pgenie#75](https://github.com/pgenie-io/pgenie/issues/75)**
  filed, asking pgn to reject non-normalized query filenames (confirmed
  live: `get-specimen.sql` and `get_specimen.sql` both resolve to
  `get_specimen`, hyphenated filenames are accepted by pgn on their own —
  not rejected upstream) and guarantee unique custom-type identities at the
  source.

## Next steps

1. ~~Nikita attempts the gen-contract change for item 4.~~ Done — shipped
   as `gen-contract` v5.0.0 + `gen-sdk` v3.0.0, both released 2026-07-14.
2. ~~Come back to this document, update item 4's disposition.~~ Done above
   — clean reimplementation via gen-sdk's new `CustomTypes` module, not
   blocked debt.
3. Bump this branch's pins (`src/Deps/Contract.dhall` → v5.0.0,
   `src/Deps/Sdk.dhall` → v3.0.0, hashes above) and fix the resulting
   compile breakage at every `Scalar.Custom` pattern match
   (`Interpreters/Scalar.dhall` at minimum — grep for other sites once the
   bump is in).
4. Migrate `buildLookup`/`effectiveResolvedCustomTypes`
   (`Interpreters/Project.dhall:590-611,1174-1204`) onto
   `Sdk.CustomTypes.{supportedCustomTypesReasoned, queryIsSupported}`, and
   reshape `Structures/CustomKind.dhall`'s `Lookup` from a
   `Model.Name -> TypeKind` closure to an index-aligned `List TypeKind`
   sourced from `ref.index`. Confirm the rank-limit checks in
   `ParamsMember.dhall`/`Member.dhall` still get the kind they need through
   the new shape.
5. Only then start implementation on items 5-8: new commits on top of
   current `HEAD` (not a history rewrite — the 15 commits'
   hypothesis-testing context in their messages is worth keeping).
