# Agent Instructions

Conventions for anyone (human or agent) working in this repo.

## Tooling

Run everything through `mise`. Never invoke `uv`, `pytest`, or `python`
directly.

```bash
mise run install   # uv sync
mise run test       # uv run pytest tests -q
```

The test harness drives real pgn subprocesses against a live PostgreSQL. Set
`PGN_TEST_DATABASE_URL` to point it at a non-default server; it only ever
creates and drops its own scratch database, never touches an existing one.

## Regenerating the golden fixture

Never hand-edit anything under `tests/golden/src/specimen_client/_generated/`
or its facade modules; they are produced by `pgn generate`. Follow
`tests/golden/README.md` for the exact recipe (it includes dropping the
stale freeze file first, or pgn silently reuses a cached generator).

## Comments

English only, no em dashes (U+2014); use a comma or a hyphen instead. Budget
roughly 1-2 comments per 30 lines,
and only for a non-obvious WHY: an invariant, an external constraint, a
workaround for a specific tool limitation. Don't narrate what the code
already says.

## Dhall

`src/` pins its remote imports by sha256 (`src/Deps/*.dhall`). Bump those
deliberately, one at a time, and re-run the harness before committing a pin
change.

Never replace a pin with a local filesystem path (`../gen-contract/...`,
`../gen-sdk/...`) even temporarily for convenience; it only works on a
machine with those sibling repos checked out and breaks CI. Always use a
`https://raw.githubusercontent.com/pgenie-io/<repo>/<tag>/...` import with
its `sha256`.
