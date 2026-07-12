# Golden files (sync surface)

The sync-surface counterpart of `tests/golden/`: a committed full fixture
package generated with `config: { sync: true }`, package name
`specimen_sync_client`. Same structure and purpose as `tests/golden/README.md`
describes for the async (default) surface — the hand-written shell here
(`pyproject.toml`, `py.typed`) plus the generated `_generated/` subtree and
the generated package-root facade `src/specimen_sync_client/__init__.py`.

`test_generated_sync_matches_golden` regenerates the `python-sync` fixture
artifact into a temp tree and asserts every file under the fresh
`_generated/` plus the facade equals its golden twin here, both ways (no
missing, no extra). `test_generated_sync_passes_basedpyright_strict` runs
basedpyright strict on this full golden package.

## Updating the golden

Run only when a generator change legitimately alters the sync surface's
output, and review the resulting diff before committing.

```bash
mise run golden
```

`mise run golden` refreshes both `tests/golden/` (the `python` artifact) and
this directory (the `python-sync` artifact) in one pass — see `mise.toml`.