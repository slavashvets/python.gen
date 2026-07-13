# ADR 0001: Fail loudly on generated Python name collisions

Status: Accepted

## Context

Different PostgreSQL names can resolve to the same Python name. For example,
the query names `sync` and `sync_query` both resolved to the module and function
`sync_query`, so one generated file silently replaced the other. Similar
collisions can affect Row classes, custom types, facade exports, and members
after Python keyword escaping.

Silent overwrite loses code. Order-based suffixes such as `name2` also make a
public API change when an unrelated declaration is added or reordered.

## Decision

Lexical handling and uniqueness are separate stages:

1. Source-derived defaults are escaped for Python keywords and generator-owned
   implementation names.
2. Optional typed mappings resolve a declaration's complete Python identity.
3. Explicit targets must already be exact, valid, non-reserved Python names.
   Snake-case targets start with a lowercase ASCII letter, and Pascal-case
   targets start with an uppercase ASCII letter. Facade and module metadata
   dunder names cannot be overwritten. Invalid targets are rejected rather
   than silently rewritten.
4. The generator audits each Python namespace selected for emission after name
   resolution and before rendering files. A collision stops generation and
   identifies both owners and the final name.

The greenfield configuration uses entity-typed mappings:

```dhall
let PythonName = { snakeCase : Text, pascalCase : Text }

let QueryNameMapping = { source : Text, target : PythonName }

let CustomTypeNameMapping =
      { source : { schema : Text, name : Text }, target : PythonName }
```

For a query, `snakeCase` owns the statement module and async/root public name;
the sync facade exports that same public name while its adjacent implementation
function adds `_sync`. `pascalCase` owns `${pascalCase}Row`. For a custom type,
`snakeCase` owns the type module and imports, while `pascalCase` owns the class,
facade export, and adapter registration. PostgreSQL and SQL names never change.
Duplicate or unknown mapping sources, invalid targets, and mapped collisions all
fail before files are emitted. Fixed package names such as `JsonValue`,
`NoRowError`, `register_types`, and `sync` cannot be remapped. `PgJsonValue` is
an example explicit user alias, not an automatic naming policy.

Local parameter, result-field, composite-field, and enum-member audits are
defensive for inputs that reach the generator; pgn may reject the conflicting
source spelling earlier. They are resolved by renaming the SQL placeholder, SQL
alias, or schema member. A future local override, if needed, must use a typed,
parent-scoped mapping instead of a string path grammar.

The structured custom-type source is exact only when the input contract
preserves the entity. pgn 0.9.1 can collapse types with the same unqualified
name across schemas, and `Scalar.Custom` has no qualified identity. A mapping
cannot recover that lost distinction. Such database shapes remain unsupported
until upstream preserves all qualified custom types and references.

## Consequences

- Generation cannot silently overwrite a file or export.
- Adding or reordering a declaration cannot renumber existing public names.
- Intentional renames are deterministic and propagate through all references.
- A conflicting source requires either a source-level rename or an explicit
  typed mapping.
- Mapping configuration is more verbose than automatic suffixing, but it is
  type-checked, and raw identifiers represented in the contract remain
  unambiguous.
