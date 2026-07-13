# python.gen

A Dhall-authored code generator for [pGenie](https://github.com/pgenie-io/pgenie)
(`pgn`). It turns queries and custom types analyzed against PostgreSQL into a
strictly typed Python client for psycopg 3.

The generated package has no separately installed generator runtime. Consumers
must depend on `psycopg>=3.3.4,<4`; the verified fixture uses psycopg 3.3.4. The
rest of the generated imports are from the Python standard library.

## Quickstart

Point an artifact at the working-tree entry point and choose a package name:

```yaml
artifacts:
  python:
    gen: https://raw.githubusercontent.com/slavashvets/python.gen/master/src/package.dhall
    config:
      packageName: my-db-client
      emitSync: true
```

Then generate against the PostgreSQL server pgn may use for its scratch
database:

```bash
pgn --database-url "$DATABASE_URL" generate
```

The raw `master` URL is valid but moving. For reproducible use, pin an actual
published `resolved.dhall` release asset or vendor the artifact delivered by
the release wheel. Do not guess a release tag that has not been published.
A relative path such as `../python.gen/src/package.dhall` is appropriate while
developing against a local checkout. An absolute path also works but makes the
freeze key machine-specific; pgn project configuration does not accept a
`file://` URL.

## Configuration

| key | type | default |
| --- | --- | --- |
| `packageName` | `Text` | project name in kebab case |
| `emitSync` | `Bool` | `False` |
| `onUnsupported` | `"Fail" \| "Skip"` | `"Fail"` |
| `queryNameMappings` | typed query-name mappings | `[]` |
| `customTypeNameMappings` | typed PostgreSQL type-name mappings | `[]` |

The `config` block and every field are optional. An omitted or `null` field uses
its default. Omitting `emitSync`, setting it to `null`, or setting it to `false`
emits the async client only. `emitSync: true` keeps that async root and adds a
`<package>.sync` facade, a sync runtime, and an adjacent sync function in each
canonical statement module. `packageName` becomes an import name by replacing
`-` with `_`.

`onUnsupported: "Fail"` aborts generation with a path-aware report.
`onUnsupported: "Skip"` preserves warnings and repeatedly removes an
unsupported custom type, its dependent custom types and statements, and every
affected facade, registration, and statement entry until the survivors are a
strict-importable fixed point.

Generated Python namespaces are audited before files are rendered. Collisions
fail loudly instead of overwriting a file or receiving an order-dependent
numeric suffix. An intentional public rename uses one typed mapping for the
entity's snake-case module/function name and Pascal-case Row/type name:

```yaml
queryNameMappings:
  - source: sync_query
    target:
      snakeCase: synchronize
      pascalCase: Synchronize
customTypeNameMappings:
  - source:
      schema: public
      name: json_value
    target:
      snakeCase: pg_json_value
      pascalCase: PgJsonValue
```

Mapping sources must identify an existing query or exact PostgreSQL schema/type
pair. A query source is pgn's snake-case query name; a custom-type source is the
exact PostgreSQL schema and type name preserved in the input contract. Targets
are final Python names: invalid or reserved targets are rejected, and
PostgreSQL names remain unchanged.
`PgJsonValue` above is a user-chosen Python alias for `public.json_value`, not a
built-in type or automatic naming rule.

pgn 0.9.1 does not preserve two custom types that share one unqualified name
across schemas: it can retain only one `customTypes` entry, while
`Scalar.Custom` carries only an unqualified `Name`. A mapping cannot recover a
schema-qualified identity missing from the contract. Avoid that database shape
until upstream preserves every schema-qualified type and a stable qualified
reference; if a future input contains two entries with the same unqualified
contract `Name`, this generator rejects it as ambiguous.

Local parameter, result-field, composite-field, and enum-member audits are
defensive for names that reach the generator. pgn may reject a conflicting SQL
or schema spelling earlier. Such a conflict is resolved at its SQL or schema
source; the entity mappings above do not apply. See
[ADR 0001](docs/adr/0001-generated-python-name-collisions.md).

## Generated package

The generator owns the package-root facade and the generated subtree. With
`emitSync: true`, the layout is:

```text
src/<package>/
  __init__.py
  sync/__init__.py
  _generated/
    __init__.py
    _core.py
    _runtime.py
    _register.py                 # when custom types need registration
    sync/_runtime.py
    statements/__init__.py
    statements/<query>.py
    types/__init__.py            # when custom types exist
    types/<custom_type>.py
```

Each statement has one canonical module. That module owns one `SQL` string,
its frozen and slotted `Row` dataclass when rows are returned, the async
function, and the optional adjacent sync function. The SQL value remains a
string accepted by the runtime as `LiteralString`; it is not encoded to bytes.
For row-returning queries, psycopg's `args_row(Row)` constructs the canonical
dataclass directly through `BaseRowFactory`. The output has no query decoders,
model codecs, `typing.cast` calls, or bytes SQL.

The async and sync facades share the same SQL, Row classes, custom types,
`_core`, registration module, and `NoRowError`. The only duplicated I/O layer is
the small sync runtime. Internal generated paths are a greenfield implementation
detail and carry no compatibility promise.

Every generated Python file begins with this exact first line:

```text
# @generated by python.gen (pGenie); regeneration overwrites manual changes.
```

The next two lines are the REUSE copyright and `SPDX-License-Identifier: MIT-0`
headers.

## Type support

Primitive mappings are intentionally conservative:

| PostgreSQL | Python |
| --- | --- |
| `bool` | `bool` |
| `int2`, `int4`, `int8`, `oid` | `int` |
| `float4`, `float8` | `float` |
| `numeric` | `Decimal` |
| `text`, `varchar`, `bpchar`, `char`, `citext`, `name` | `str` |
| `uuid` | `UUID` |
| `date` | `date` |
| `time` | `time` |
| `timestamp`, `timestamptz` | `datetime` |
| `interval` | `timedelta` |
| `bytea` | `bytes` |
| `json`, `jsonb` | recursive `JsonValue` |

Primitive arrays preserve dimensionality, element nullability, and outer
nullability. Custom types use psycopg's class-aware adapters and stay ordinary
Python models:

- PostgreSQL enums become `StrEnum` classes. Scalar enums and enum arrays are
  supported, including the rank-2 enum-array contract.
- PostgreSQL composites become `@dataclass(frozen=True, slots=True)` classes.
  Scalar load and dump, rank-1 composite arrays, and nested scalar composites
  are supported.
- Nullable members and Python-keyword names are preserved safely. SQL names
  remain raw while Python fields and parameters gain a trailing underscore when
  required.

Unsupported primitive types, domains, missing custom types, and unsupported
custom kinds fail loudly. Custom-shape limits are enum arrays above rank 2,
composite arrays above rank 1, and any custom-array field nested inside a
composite. A `json` or `jsonb` array parameter is also rejected because wrapping
the whole list is not a faithful element-wise psycopg adaptation.

## Registration and use

`register_types` is a precondition for each newly opened connection once the
database types and migrations exist. Async and sync registration are separate
operations because psycopg fetches catalog metadata through the connection.
Registration is dependency-first and class-aware:

- `EnumInfo.fetch` plus `register_enum` binds the generated `StrEnum` class.
- `CompositeInfo.fetch` plus `register_composite` binds the generated dataclass
  with validated object and sequence callbacks.

Async use:

```python
from my_db_client import get_specimen, register_types


async def load(conn, specimen_id: int):
    await register_types(conn)
    return await get_specimen(conn, id=specimen_id)
```

Sync use when `emitSync: true`:

```python
from my_db_client.sync import get_specimen, register_types


def load(conn, specimen_id: int):
    register_types(conn)
    return get_specimen(conn, id=specimen_id)
```

The facades expose the exact same model and error objects:

```python
import my_db_client
from my_db_client import sync

assert my_db_client.GetSpecimenRow is sync.GetSpecimenRow
assert my_db_client.Mood is sync.Mood
assert my_db_client.NoRowError is sync.NoRowError
```

Cardinality follows pgn without narrowing: optional rows return `Row | None`,
single rows return `Row` or raise `NoRowError`, multiple rows return
`list[Row]`, affected-row statements return `int`, and void statements return
`None`. The generated runtimes implement exactly those five helpers.

## Taking ownership

Generated code is ordinary Python and can be taken over deliberately:

1. Generate the desired client and commit the complete result.
2. Disable every regeneration path first, including local tasks, CI jobs, and
   automation that invokes pgn for this artifact.
3. Replace the generated marker with a project-owned header before editing.
4. Maintain the files as ordinary Python. Keep the package structure unless a
   deliberate refactor updates imports and consumers together.
5. Run basedpyright strict, Ruff check and format checks, and the project's
   database tests before accepting the takeover.

Do not edit while regeneration is still enabled. The marker is a truthful
overwrite warning, and ownership starts only after that overwrite path is
disabled.

## Development

This repository pins pgn 0.9.1 in `mise.toml`. Run all tools through `mise`:

```bash
mise run install
mise run lint
mise run test
```

The harness drives real pgn subprocesses against a live PostgreSQL server and
only creates and drops its own scratch databases. Set `PGN_TEST_DATABASE_URL`
for a non-default server. The full verified suite is 73 passed and 0 skipped;
it includes byte-for-byte golden comparison, async and sync round trips,
basedpyright strict, Ruff, generated-quality budgets, unsupported-type modes,
and public identity checks.

Regenerate the committed fixture only with `mise run golden` and follow
[`tests/golden/README.md`](tests/golden/README.md). The task deletes stale
freeze and artifact state in a temporary fixture before invoking pgn. Never
hand-edit generated fixture files.

pgn freezes a resolved generator by the literal `gen` value. If source behind a
stable local path or URL changes, delete the fixture's stale freeze file before
regenerating or pgn may reuse the cached generator.

Remote imports under `src/Deps/` are sha256-pinned. Bump them deliberately, one
at a time, and rerun the harness. The release workflow resolves
`src/package.dhall` into the `resolved.dhall` release asset, then builds the
wheel from those exact bytes. The wheel exposes path, URL, and vendor commands;
PyPI publication remains disabled until its explicit release gate is enabled.

`fixtures/Exhaustive.dhall` is the contract fixture. It and `buildLookup` rely
on the pgn fork's `Text/equal` builtin, so the standard upstream Dhall evaluator
cannot run the complete contract path. CI uses the pinned fork-aware action.

## Provenance and license

The generator was extracted from a production code base where it generates the
data layer for a 115-query corpus.

- Repository source is MIT, see [LICENSE](LICENSE).
- Emitted Python is MIT-0 under its file headers.
- `resolved.dhall` and the `pgenie-python-gen` wheel are
  GPL-3.0-or-later as combined artifacts because they inline gen-sdk. The wheel
  carries the pinned GPL text and `wheel/NOTICE`; generated Python contains no
  gen-sdk code and remains MIT-0.
