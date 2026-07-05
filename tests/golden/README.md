# Golden files

A committed full fixture package: the hand-written shell (`pyproject.toml`,
`src/specimen_client/py.typed`) plus the generated subtree under
`src/specimen_client/_generated/` and the generated package-root facade
`src/specimen_client/__init__.py`. The generator emits the `_generated/` subtree and
the facade; the rest of the shell is hand-written and committed here as a fixture.

`test_generated_matches_golden` regenerates the fixture client into a temp tree
and asserts every file under the fresh `_generated/` plus the facade equals its
golden twin, both ways (no missing, no extra).
`test_generated_passes_basedpyright_strict` runs basedpyright strict on the full
golden package (shell + facade + `_generated`) so the strictness guarantee covers
the real consumer layout. This `README.md` and the hand-written shell stay out of
the byte-comparison.

## Updating the golden

Run only when a generator change legitimately alters the output, and review the
resulting diff before committing. Refresh the `_generated/` subtree and the
facade; never overwrite the hand-written `pyproject.toml` or `py.typed`.

```bash
cd tests/fixture-project
rm -f freeze1.pgn.yaml                 # force pgn to re-resolve the working-tree gen/
rm -rf artifacts
# Default admin URL is localhost:5432; set PGN_TEST_DATABASE_URL to point elsewhere
# (e.g. a local pg0 instance on a non-default port).
mise x -- pgn --database-url "${PGN_TEST_DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/postgres?sslmode=disable}" generate
rsync -a --delete \
  artifacts/python/src/specimen_client/_generated/ \
  ../golden/src/specimen_client/_generated/
cp artifacts/python/src/specimen_client/__init__.py ../golden/src/specimen_client/__init__.py
# The sync facade lives outside _generated, like the async facade.
mkdir -p ../golden/src/specimen_client/sync
cp artifacts/python/src/specimen_client/sync/__init__.py ../golden/src/specimen_client/sync/__init__.py
```

`artifacts/` is gitignored; the golden tree is the committed contract.

> Note: a stale `freeze1.pgn.yaml` makes pgn reuse a cached generator and ignore
> edits under `gen/`, silently emitting old output. Always remove it before
> a golden refresh. The harness deletes it in its temp copy for the same reason.
