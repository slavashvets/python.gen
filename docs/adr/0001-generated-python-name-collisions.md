# ADR 0001: Generated Python name collisions

Status: Superseded

## Context

Different PostgreSQL names can resolve to the same Python name. The original
implementation collected every generated binding and compared it with a growing
list of prior bindings. It did this for project exports and modules, query
members, custom-type members, and imports inside each custom-type module.

Those scans were quadratic and expensive under Dhall normalization. They ran on
every generation, including projects that did not configure any name mappings.

## Superseding decision

The namespace-wide and local audits are removed. The typed query and custom-type
rename-mapping API and its runtime identity validators are removed with them.

Lexical handling remains. Source-derived defaults are escaped for Python
keywords and generator-owned implementation names.

Final uniqueness is now the project's responsibility. Two distinct entities can
resolve to the same module, class, function, field, or export. Static analysis
can catch many collisions in the surviving generated Python, but a module-path
collision can overwrite an earlier file before static analysis sees it.

## Consequences

- Normal generation uses less time and peak memory.
- Projects must keep final generated names unique.
- Resolve a conflict by renaming its SQL or schema source.
- A future collision check should avoid growing-list normalization and should
  preferably be enforced by pgn before generator evaluation.
