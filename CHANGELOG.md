# Upcoming

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
