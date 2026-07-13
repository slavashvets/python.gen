#!/usr/bin/env bash
# Historical fixture helper for a retired Dhall import-mode comparison.
# Current src/Deps uses ordinary sha256-pinned imports, so the two labels no
# longer describe distinct current dependency configurations.
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

  # These rewrites belong to the old dependency snapshot and are no-ops for
  # the current ordinary imports and hashes.
  perl -i -pe 's/46b527b071eba96a17e76b4bc5774645714dd5b4355974d221e705aa7c126e77/14c43eec97972ae27afe3386ff937d04db66f84273d5551476361db12d2c4b50/' "$out/src/Deps/Lude.dhall"
fi

cd "$out/tests/fixture-project"
pgn --database-url "$url" generate
echo
echo "done: $out/tests/fixture-project/artifacts/python"
