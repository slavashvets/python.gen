# Upstream asks: pgn and gen-sdk

This is a negotiation brief, not architecture documentation (that stays in
DESIGN.md). It collects three asks whose implementations live outside this
repository: two against pgn, one against gen-sdk. They travel as one package
because they interlock; the sequencing note in ask 3 explains how.

## 1. pgn: move the pragma grammar into the model

### Motivation

Nullability and cardinality overrides currently ride in SQL comments that
only this generator parses, after the fact, out of already-parsed query
fragments. That works for columns and cardinality but cannot work for
params: a marker attached to the placeholder itself would be sent to
Postgres verbatim today and fail at PREPARE, so param-level nullability is
impossible to express generator-locally in placeholder position. Only pgn,
which owns the SQL tokenizer, can honor an inline marker.

### Proposed change

- Params: an inline marker `$name!` (and `$name[]!` for array elements)
  directly on the placeholder, stripped by pgn before the statement reaches
  Postgres and reflected in the model as `Member.isNullable` /
  `elementIsNullable`.
- Columns and cardinality: pgn parses the comment grammar
  `-- @column <name> not null`, `-- not null columns: ...`, and
  `-- @returns single|optional|scalar|optional scalar`, and reflects it in
  the model (column nullability, `Result` cardinality).

### What the generator deletes afterwards

The Dhall comment-scanner and the param comment-bridge are deleted
outright. The generator then consumes nullability and cardinality from the
model like any other query metadata.

### Compatibility notes

User-facing syntax for columns and cardinality does not change; existing
queries keep working unmodified. Params deliberately migrate from comment
lists to the inline marker, a breaking change for param annotations that we
accept because the inline form is the one that belongs on the placeholder.

## 2. pgn: print `Compiled.warnings` on successful runs

### Motivation

Skip mode drops the smallest failing unit and keeps the rest of the project
generating, and the generator already collects a report per dropped unit
into `Compiled.warnings` per the contract (DESIGN.md, section 11). pgn does
not surface that list anywhere on a successful run, so Skip currently drops
queries silently. The collection side is done; pgn only needs to print it.

### Proposed change

On successful runs, print `Compiled.warnings` to stderr in the same format
as the failure report, keeping exit code 0. Optionally, a
`--strict-warnings` flag that raises the exit code when the warnings list
is non-empty, for CI setups that want silent drops to fail the build.

### What the generator simplifies afterwards

Nothing to delete; the generator was built ready for this (section 11).
The existing warnings plumbing starts paying off, and the README's caveat
about silent drops in Skip mode goes away.

### Compatibility notes

Purely additive: exit codes are unchanged by default, stdout is untouched,
and the new stderr output only appears when warnings are non-empty.
`--strict-warnings` is opt-in.

## 3. gen-sdk: `kind` tag or `Natural` index on `Scalar.Custom`

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
