#!/usr/bin/env bash
# Build the fixture client from the working-tree src, in one of two variants:
#   with    - src/Deps as committed (imports `as Source`)
#   without - the pre-as-Source Deps (mode stripped, normalized-expression
#             pins restored; byte-identical to commit fb78869's Deps)
# Output lands in ./demo-with-as-source or ./demo-without-as-source.
# Uses the normal dhall cache; for cold-cache measurements use bench/as-source.sh.
set -euo pipefail

variant="${1:?usage: bench/generate.sh with|without}"
case "$variant" in with|without) ;; *) echo "usage: bench/generate.sh with|without" >&2; exit 2;; esac

root=$(cd "$(dirname "$0")/.." && pwd)
url="${PGN_TEST_DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/postgres?sslmode=disable}"
out="$root/demo-$variant-as-source"

rm -rf "$out" && mkdir -p "$out/tests"
cp -R "$root/src" "$out/src"
cp -R "$root/tests/fixture-project" "$out/tests/fixture-project"
rm -f "$out/tests/fixture-project/freeze1.pgn.yaml"
rm -rf "$out/tests/fixture-project/artifacts"

if [ "$variant" = without ]; then
  perl -i -ne 'print unless /^\s*as Source$/' "$out"/src/Deps/*.dhall

  # gen-sdk v2.0.0's src/package.dhall: `mise x -- dhall hash` against the
  # live GitHub-hosted package (both `... as Source` and the plain import)
  # returns the SAME sha256 (b9def6ab1179bc4aaae7fc6e91977f094f75934cd5755175c294a9e97ca71b15),
  # matching the value already committed in src/Deps/Sdk.dhall -- so, unlike
  # the old v0.11.0 pin this pair used to target (where the two genuinely
  # differed: 8d43544e...->b9f7bb84...), no character swap is needed here
  # after the strip above; the committed pin already equals the plain-import
  # target. See docs/superpowers/plans/2026-07-11-gen-sdk-v2-migration.md
  # Task 6 for how this was verified (dhall's local import cache made the
  # lookup instant; a cold, uncached fetch of a *different* URL hung in this
  # sandbox, so treat network reachability here as best-effort, not given).

  # lude v5.1.0 is unchanged by this migration (see src/Deps/Lude.dhall), so
  # its existing as-Source -> plain-import hash swap below is still correct.
  perl -i -pe 's/46b527b071eba96a17e76b4bc5774645714dd5b4355974d221e705aa7c126e77/14c43eec97972ae27afe3386ff937d04db66f84273d5551476361db12d2c4b50/' "$out/src/Deps/Lude.dhall"
fi

cd "$out/tests/fixture-project"
pgn --database-url "$url" generate
echo
echo "done: $out/tests/fixture-project/artifacts/python"
