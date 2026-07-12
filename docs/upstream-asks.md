# Upstream asks: pgn and gen-sdk

This is a negotiation brief, not architecture documentation (that stays in
DESIGN.md). It collects three asks whose implementations live outside this
repository: two against pgn, one against gen-sdk. They travel as one package
because they interlock; the sequencing note in ask 3 explains how.

## 1. pgn: parse annotation comments into the model

Issue #66: https://github.com/pgenie-io/pgenie/issues/66

### Motivation

Nullability and cardinality overrides currently ride in SQL comments that
only this generator parses, after the fact, out of already-parsed query
fragments: one line per subject, `-- @param <name> not null|nullable` (with
a `-- @param <name>[] ...` form for array elements), `-- @column <name> not
null`, and `-- @returns single|optional|scalar|optional scalar`, names
unsigiled. Only pgn, which owns the SQL tokenizer, can carry these into the
model so that consumers do not each re-parse comments on their own.

Observed pgn 0.6.5 behavior, filed separately as a bug (issue #65:
https://github.com/pgenie-io/pgenie/issues/65): pgn tokenizes `$`-tokens
inside SQL comments as if they were live placeholders. A comment-only
`$token` receives a param index in the fragments yet never appears in
`params`, and a comment `$id` merges onto the real `$id` param. This is why
the annotation grammar is unsigiled: a sigiled `-- @param $id ...` line
never reaches a comment scanner as literal text.

### Proposed change

pgn parses the per-line, unsigiled comment grammar and reflects it in the
model:

- Params: `-- @param <name> not null|nullable` (and `-- @param <name>[] ...`
  for array elements), reflected as `Member.isNullable` /
  `elementIsNullable`.
- Columns: `-- @column <name> not null`, reflected as column nullability.
- Cardinality: `-- @returns single|optional|scalar|optional scalar`,
  reflected as `Result` cardinality.

The names in the comment are bare throughout, never `$`-prefixed.

This is framed as a prototype offer, not a committed ship: we are willing
to build a working prototype of the comment-into-model parsing against pgn
and hand it over, so the grammar can be judged on running code rather than
on a proposal.

#### Rejected alternative

An earlier sketch put the marker on the placeholder itself, an inline
`$name!` (with `$name[]!` for array elements) stripped by pgn before the
statement reached Postgres. Two things sank it. pgn 0.6.5 tokenizes
`$`-tokens inside comments (issue #65), so the sigiled forms are unsafe to
place near live SQL; and a per-use-site marker has a consistency problem,
since the same parameter can appear at several placeholders with nothing
forcing the markers to agree. The per-line comment grammar keeps one
annotation per subject and sidesteps both.

### What the generator deletes afterwards

The Dhall comment-scanner (`Pragma.dhall`) and the `-- @param` comment
bridge are deleted outright. The generator then consumes nullability and
cardinality from the model like any other query metadata.

### Compatibility notes

User-facing syntax does not change; existing queries keep working
unmodified. The move is purely a shift of parsing responsibility from this
generator into pgn and the model, so no annotation needs rewriting.

## 2. pgn: print `Compiled.warnings` on successful runs

Issue #67: https://github.com/pgenie-io/pgenie/issues/67

### Motivation

Skip mode drops the smallest failing unit and keeps the rest of the project
generating, and the generator already collects a report per dropped unit
into `Compiled.warnings` per the contract (DESIGN.md, section 11). pgn does
not surface that list anywhere on a successful run, so Skip currently drops
queries silently. The collection side is done; pgn only needs to print it.

### Proposed change

On successful runs, print `Compiled.warnings` to stderr in the same format
as the failure report, keeping exit code 0. Optionally, a
`--fail-on-warnings` flag that raises the exit code when the warnings list
is non-empty, for CI setups that want silent drops to fail the build.

### What the generator simplifies afterwards

Nothing to delete; the generator was built ready for this (section 11).
The existing warnings plumbing starts paying off, and the README's caveat
about silent drops in Skip mode goes away.

### Compatibility notes

Purely additive: exit codes are unchanged by default, stdout is untouched,
and the new stderr output only appears when warnings are non-empty.
`--fail-on-warnings` is opt-in.

## 3. gen-sdk: `kind` tag or `Natural` index on `Scalar.Custom`

**WITHDRAWN.** `buildLookup`'s only consumer of the fork-only `Text/equal`
builtin was resolved locally, with no gen-sdk contract change needed:
custom-type decode/encode now dispatches through named
`_decode`/`_decode_array`/`_encode` methods generated onto each custom
type's own Python class (`CompositeModule.dhall`/`EnumModule.dhall`),
called by name from every reference site, instead of resolving
classification/fields via a project-wide structural search. `buildLookup`
and `Structures/CustomKind.dhall` are deleted; see
`docs/plans/2026-07-11-reusable-custom-type-codecs.md` and DESIGN.md
section 12. This section is kept for the historical record of why the ask
existed, not as an open request.

### Motivation

This is the ask already planned in DESIGN.md, section 12. The generator's
last remaining use of the fork-only `Text/equal` builtin is
`Interpreters/Project.dhall`'s `buildLookup`, which matches a custom type
by its snake-case name while building the `CustomKind.Lookup`. It returns a
structural `TypeKind` value, not `Text`, so the `Text/replace`-based trick
that removed `Text/equal` from keyword sanitizing (section 13) does not
carry over.

### Proposed change

As recorded in section 12: a `kind` tag or a `Natural` index carried
directly on `Scalar.Custom`, so the lookup becomes an equality-free
structural match. This is a change to gen-sdk's model types, not something
this generator can do unilaterally.

### What the generator deletes afterwards

`buildLookup`'s name-equality matching, which removes the last need for the
forked `Text/equal` builtin in this generator's own code.

Sequencing constraint: the pragma work in ask 1 adds `Text/equal` uses in
`Pragma.dhall`, so landing this ask alone does not de-fork the generator.
Full removal of the fork dependency is possible only after ask 1 lands and
`Pragma.dhall` is deleted; the order matters and is part of this
negotiation, not an implementation detail.

### Compatibility notes

A new field on `Scalar.Custom` touches every gen-sdk consumer (java.gen
included), so it should be introduced in coordination with them. This
generator pins gen-sdk imports by sha256 and adopts the change on the next
pin bump. Note that gen-sdk's own `Fixtures` module also relies on the fork
builtin (section 12), so this ask de-forks generators, not gen-sdk's full
package entry point.
