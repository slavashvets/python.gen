# Upstream resolution status: pgn and gen-sdk

This brief records the current status of three upstream integration points.
The pgn annotation-metadata and warning-surfacing issues are closed and shipped.
Only the gen-sdk request for a stable custom-type kind or identifier remains
actionable. Architecture details stay in `DESIGN.md`.

## 1. pgn annotation metadata: resolved

Issue [#66](https://github.com/pgenie-io/pgenie/issues/66) is closed.

The pgn-side move is complete. The generator consumes nullability and
cardinality directly from `Model.Member` and `Model.Result` metadata. The former
SQL comment scanner and annotation bridge have already been removed, so no
generator-side annotation parsing remains.

## 2. pgn warning surfacing: resolved

Issue [#67](https://github.com/pgenie-io/pgenie/issues/67) is closed. Since pgn
0.7.2, successful generation surfaces reports from `Compiled.warnings`; this
repository pins pgn 0.9.1.

With `onUnsupported: Skip`, the generator retains a report for every dropped
unit while fixed-point filtering removes unsupported custom types, their
dependents, and affected statements. See `DESIGN.md`, section 8.

## 3. gen-sdk stable custom kind or identifier: actionable

Project-wide custom-type lookup classifies every custom reference as an enum,
composite, or absent. Shipped models are pure declarations with no class
codecs. The lookup classification instead drives support-shape validation,
custom imports and dependencies, and dependency-first psycopg adapter
registration. See `DESIGN.md`, sections 3, 5, and 8.

`Interpreters/Project.dhall` currently implements `buildLookup` by comparing a
custom reference's snake-case name with each project custom type through
`Text/equal`. This local lookup is the generator's sole need for that
pgn-specific builtin.

The upstream ask is a stable `kind` tag or identifier on `Scalar.Custom`, such
as a `Natural` project index, so the lookup can use an equality-free structural
match. That would remove the local `Text/equal` dependency described in
`DESIGN.md`, section 10.

Changing `Scalar.Custom` affects gen-sdk consumers. This repository pins its
gen-sdk import by sha256, so adopting such a change would require an explicit
pin update and a full harness run.
