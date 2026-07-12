# Upcoming

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

- `buildLookup` (`Interpreters/Project.dhall`) and, with it, this generator's
  last dependency on pgn's fork-only `Text/equal` builtin are removed from
  `src/`: custom-type decode/encode now dispatches through named
  `_decode`/`_encode` methods generated onto each custom type's own Python
  class (`CompositeModule.dhall`/`EnumModule.dhall`), called by name from
  every reference site, instead of resolving classification and fields via a
  project-wide structural search (`grep -rn "Text/equal" src` now returns
  only two explanatory comments, zero invocations). Array (dims > 0)
  decode/encode is built at the call site (`Member.dhall`/
  `ParamsMember.dhall`) instead of a third per-type method, delegating only
  the per-element transform to `_decode`/`_encode`: an earlier draft this
  session added a per-type `_decode_array` to `EnumModule.dhall`, but it
  could not express `elementIsNullable` (a per-column fact, not a per-type
  one) and silently broke nullable-element enum-array decode and
  enum-array param encode — both working, corpus-exercised paths — caught
  by the final whole-branch review and fixed before merge. Behavior change:
  because the call site is now kind-uniform, a 1-D composite-array column
  or param is no longer rejected at Dhall-generation time the way it used
  to be, and — unlike the `_decode_array` design it replaces — no longer
  depends on `basedpyright strict` catching a missing method either, since
  `_decode`/`_encode` genuinely exist on a composite class too. **This path
  has not been exercised against real Postgres, and `tests/golden/` has NOT
  been regenerated for this change this session** — the composite-array
  fixture addition, its golden regeneration, and confirming actual Postgres
  round-trip behavior are a known, deliberate gap in this commit, deferred
  to a follow-up pass on a properly provisioned machine (see
  `docs/plans/2026-07-11-reusable-custom-type-codecs.md`).
  Separately, a composite field nesting another custom type is *also* no
  longer rejected at generation time: the `nestedLookup = Absent` stub that
  used to force it down the same loud-fail path is gone (it only existed
  to satisfy `Member.run`'s old signature). This is not the same kind of
  change as the composite-array case above, though — `CompositeModule.dhall`'s
  `_decode`/`_encode` still do a blind flat `cast(tuple[...], src)`/splat,
  unchanged by this refactor, and never recurse into the nested type's own
  codec, so the field silently decodes/encodes wrong rather than being
  caught by a type checker. Because the failure mode is `cast()`, which
  suppresses type-checking on its argument by design, this is **not**
  expected to be caught by `basedpyright strict`. It is a real, silent
  architecture gap, flagged here as an open follow-up design question, not
  a shipped or backstopped behavior change.
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
- The test harness now runs every pgn subprocess in its own process group under
  an RSS watchdog: a thread polls `ps -o rss=` every 2 s and, on breach of
  `PGN_MAX_RSS_GB` (default 40 GB), kills the whole group and fails the test with
  the observed RSS. A single-artifact generate peaks ~35 GB on the reference
  machine; an unbounded run once hit ~80 GB and had to be emergency-killed, so
  the budget keeps a runaway generate from taking down the host.
- Emitted packages gained a surface-agnostic `_generated/_core.py` that owns the
  shared names (the `JsonValue` alias, `NoRowError`, a new `DecodeError`, and the
  `require_array` decode guard) with no I/O. Both `_runtime.py` modules are now
  I/O-only and re-export `JsonValue`/`NoRowError`/`require_array` from `_core` so
  off-contract `from ._runtime import ...` keeps working; `_rows.py`, the
  statement modules, and the facades import the shared names from `_core`
  directly.
- The release wheel now ships its GPL compliance files inside the artifact:
  the build fetches the GPLv3 text into `COPYING` (sha256-pinned) and bundles
  the committed `wheel/NOTICE` describing the composition; both land in
  `dist-info/licenses` and the release job asserts their presence in the
  wheel and the sdist. The repository LICENSE (MIT) is no longer copied into
  the wheel, where it misstated the artifact's license.
- Emitted files now carry REUSE-style SPDX header lines
  (`SPDX-FileCopyrightText`, `SPDX-License-Identifier: MIT-0`) right after
  the `@generated` marker: license scanners in consuming projects see a
  standard permissive id for the generated code instead of guessing its
  provenance.
- Added a `pgenie-python-gen` wheel channel (`wheel/`): the release build bundles
  the resolved generator as an installable package with a `path`/`url`/`vendor`
  CLI; publication to PyPI ships wired but disabled.
- Keyword escaping (`PyIdent.dhall`) no longer needs the fork-only
  `Text/equal` builtin; it's rewritten against a `Text/replace`-based marker
  trick, since pgn's embedded `Text/replace` doesn't match a needle spanning
  a concatenation boundary, which is what the java.gen-style delimiter trick
  relied on.
- The generator config is now fully optional, folded through a single
  defaults record in `compile.dhall` (`packageName` from the project name,
  `emitSync` off, `onUnsupported` `Fail`). A project can omit `config:`
  entirely, pass `config: {}`, or set any subset of the keys.
- gen-sdk pinned to `v0.10.2`.
- Fixed single-field composite param binding: it rendered as `(x.field)`,
  parentheses around a bare expression, not a one-element Python tuple.
  Now renders `(x.field,)`. Covered by a dedicated fixture composite
  (`tag_value`) exercised as both a param and a result column.
- Added `onUnsupported: Fail | Skip`. `Fail` (default) is the existing
  loud-abort behavior. `Skip` drops the smallest self-consistent unit (a
  statement or a custom type, cascading to anything that references it) and
  keeps generating the rest.
