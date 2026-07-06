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
# Default admin URL is localhost:5432; set PGN_TEST_DATABASE_URL to point
# elsewhere (e.g. a local pg0 instance on a non-default port).
mise run golden
```

The task (see `mise.toml`) copies the fixture project to a temp dir, cuts it
down to the `python` artifact (a full 7-artifact generate peaks at ~31 GB RSS,
a single-artifact one at ~10 GB), regenerates from the working-tree `gen/`
with a fresh resolve (no stale `freeze1.pgn.yaml`), and rsyncs the
`_generated/` subtree plus both facades back into the golden tree.
