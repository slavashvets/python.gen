# python.gen: `demos/` → `fixtures/` rename

Postponed from the cross-generator rename. Apply when ready.

## Directory rename

```bash
cd /Users/mojojojo/repos/pgenie/python.gen
git mv demos/ fixtures/
```

## File edits

| File | Changes |
|---|---|
| `build.bash` | `demos/Exhaustive.dhall` → `fixtures/Exhaustive.dhall`; `regenerate_demo_output` → `regenerate_fixture_output` |
| `.github/workflows/ci.yml` | `demos/Exhaustive.dhall` → `fixtures/Exhaustive.dhall` |
| `.github/scripts/build-contract-shell.sh` | comment: `demos/Exhaustive.dhall` → `fixtures/Exhaustive.dhall` |
| `DESIGN.md` | 3 references: lines 646, 766, 770 — `demos/Exhaustive.dhall` → `fixtures/Exhaustive.dhall` |
| `CHANGELOG.md` | Add Upcoming entry documenting the rename |

## Cleanup

```bash
rm -rf .superpowers/sdd/
```

## Left as-is

- `Sdk.Fixtures.Exhaustive` import (stays)
- `tests/fixture-project/` (stays — separate concept)
- `notes.md` (historical)