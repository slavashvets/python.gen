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
Implementation has **not** started. Nikita is going to attempt a
gen-contract change first (see item 4) before any code gets written here,
since that changes what "keep, flagged as blocked" for `buildLookup` should
actually look like.

## Decision table

| # | Item | Disposition |
|---|---|---|
| 1 | `emitSync` — dual sync+async generation in one module (`e46dc96`, `a1ac9f8`, `e7d1e6b`) | **Keep as-is.** Confirmed zero `Text/equal` dependency. |
| 2 | Custom type registration — psycopg-native adapter binding, dependency-ordered via a `Natural` `order` field (`bac8f95`, `375ba6f`) | **Keep as-is.** The registration/ordering mechanism itself is zero `Text/equal` (`sameOrder` uses `Natural/subtract`, not text comparison). |
| 3 | `50f74fa`'s module-internal reserved-name disambiguation (`querySafeName`, `moduleReservedNames`, `parameterSafeName` in `PyIdent.dhall`) | **Keep as-is.** Necessary regardless of any collision-detection decision (stops e.g. a query named `date` from shadowing its own generated file's `from datetime import date`), and already `Text/equal`-free via the same fixed-list `Text/replace` trick as Python-keyword escaping. |
| 4 | `buildLookup` (`5147204`, `Interpreters/Project.dhall:590-611`) — backs `onUnsupported: Skip`'s cascade removal and the empirically-verified rank-limit validation (composite arrays ≤1 dim, enum arrays ≤2 dims) | **Keep, flagged as blocked debt** — the sole accepted `Text/equal` exception, pending a gen-contract change. **Nikita is pursuing this now** (see "What #4 needs" below). |
| 5 | Flat top-level package facade (re-exports every query/type/core symbol into one shared top-level namespace) | **Replace.** Un-flatten into per-kind sub-namespaces (statements get their own namespace, types get their own). This is new work, not a keep/discard of an existing commit. |
| 6 | Same-kind collision *detection* (two queries, or two custom types, whose generated names collide with each other — as opposed to cross-kind collisions, which item 5 eliminates structurally) | **Discard.** Risk accepted; pushed upstream instead. Filed [pgenie-io/pgenie#75](https://github.com/pgenie-io/pgenie/issues/75) asking pgn to reject non-normalized query filenames and guarantee unique custom-type identities at the source. |
| 7 | Manual rename-override feature (`queryNameMappings`/`customTypeNameMappings` config, `Structures/PythonNameMapping.dhall`) | **Discard entirely.** Wasn't on the original keep-list; not needed once detection (item 6) is dropped; was the last thing in the collision cluster still needing `Text/equal` (to match a reference's name against a configured mapping's source). |
| 8 | `docs/adr/0001-generated-python-name-collisions.md` and related docs (`DESIGN.md`, `README.md`, `CHANGELOG.md` sections describing the flat facade / collision detection / rename mappings) | **Drop the ADR outright** (decided 2026-07-14, superseding the earlier "rewrite" plan). Related doc sections describing the now-discarded flat-facade/detection/rename-mapping behavior still need rewriting or removal to match the new state — not a blanket drop, just the ADR itself. |
| — | Tests exercising discarded behavior (`test_python_name_collisions.py`, `test_takeover_contract.py`) | Rewrite/remove to match — `test_python_name_collisions.py` specifically tests the collision-detection and rename-mapping mechanisms being discarded; `test_takeover_contract.py` locks in flat-facade output that item 5 changes. |

## What #4 (buildLookup) needs from gen-contract

The generator's `Model.Scalar.Custom` variant (pinned to gen-contract
v4.0.1) carries only a bare `Name`:

```dhall
let ScalarDecode = < Passthrough | Custom >
-- Custom = \(name : Model.Name) -> { customRef = Some name, decode = ScalarDecode.Custom, ... }
```

There's no id or kind tag tying a *reference* to a custom type back to its
*definition* without a project-wide name search — that search is what
`buildLookup` performs with `Text/equal`. The fix already drafted (and
previously withdrawn, then un-withdrawn — see `docs/upstream-asks.md` ask
3 in this branch's history) is to add a stable identity directly onto
`Scalar.Custom`:

```
Scalar.Custom : { name : Name, kind : < Enum | Composite >, id : Natural }
```

If the reference site already carries this, `buildLookup`,
`Structures/CustomKind.dhall`, and the `Text/equal` dependency disappear
from python.gen entirely — the classification comes for free instead of
being re-derived by search. This touches every gen-sdk consumer (java.gen
included), so it needs coordination, not something python.gen can do
unilaterally against a pinned import.

Full background, live evidence (reproduced `pgn generate` runs showing the
Skip-cascade and rank-limit behavior in detail), and the historical context
of why `buildLookup` was withdrawn-then-reinstated live in the companion
note: `/private/tmp/claude-501/-Users-mojojojo-repos-pgenie-python-gen/018e3c75-72c2-414c-af89-0e300db2f020/scratchpad/handoff-buildlookup-text-equal.md`
(session-local scratch path — copy anything worth keeping into this repo
before that path is cleaned up).

**Once the gen-contract change lands and this branch's pin is bumped:**
`buildLookup` should be reimplemented against the new `id`/`kind` fields
directly (no search, no `Text/equal`) rather than kept as flagged debt —
re-open this document and update item 4's disposition before starting
implementation.

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

1. Nikita attempts the gen-contract change for item 4.
2. Come back to this document, update item 4's disposition based on the
   outcome (clean reimplementation vs. still-blocked debt).
3. Only then start implementation: new commits on top of current `HEAD`
   (not a history rewrite — the 15 commits' hypothesis-testing context in
   their messages is worth keeping), covering items 5-8 plus whatever
   item 4 turns into.
