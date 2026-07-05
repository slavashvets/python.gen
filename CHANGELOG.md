# Upcoming

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
