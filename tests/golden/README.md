# Golden fixture

This directory is one committed combined client package. Its hand-written shell
is `pyproject.toml` plus `src/specimen_client/py.typed`. Generator-owned content
is the complete `src/specimen_client/_generated/` subtree, the package-root
`src/specimen_client/__init__.py` facade, and, when `emitSync: true`, the
`src/specimen_client/sync/__init__.py` facade.

The harness overlays that hand-written shell with a freshly generated package.
It compares every generator-owned file in both directions, checks
basedpyright strict on the full consumer layout, and exercises both connection
surfaces. There is only one golden package because async and sync share the same
canonical SQL, Row classes, custom types, core, and registration module.

## Regenerating

Run the repository task only when an intentional generator or source-query
comment change alters output:

```bash
# Set PGN_TEST_DATABASE_URL for a PostgreSQL server on a non-default address.
mise run golden
```

The task performs one serial, memory-heavy generation. It copies
`tests/fixture-project/` to a temporary directory, deletes the copied freeze file
and artifact directory, keeps only the Python artifact, and rewrites its `gen`
reference to the working-tree `src/package.dhall`. After pgn succeeds, it syncs
the generated subtree and copies the root and sync facades into this fixture.
The temporary directory is removed on exit.

Do not hand-edit generator-owned files. Do not copy over `pyproject.toml` or
`py.typed`. The task does not update analyzed signature YAML, so any signature
change is a separate, explicit review and is unexpected for a SQL-comment-only
refresh.

After regeneration, review the complete fixture diff before committing:

```bash
mise exec -- git diff -- tests/golden
```
