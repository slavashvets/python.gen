#!/usr/bin/env bash
# Build the fixture client from the working-tree gen, in one of two variants:
#   with    - gen/Deps as committed (imports `as Source`)
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
cp -R "$root/gen" "$out/gen"
cp -R "$root/tests/fixture-project" "$out/tests/fixture-project"
rm -f "$out/tests/fixture-project/freeze1.pgn.yaml"
rm -rf "$out/tests/fixture-project/artifacts"

if [ "$variant" = without ]; then
  perl -i -ne 'print unless /^\s*as Source$/' "$out"/gen/Deps/*.dhall
  perl -i -pe 's/8d43544ecb0e612406af3133bdbca51138c704a77a5a29ef62fe034d0e77a3a6/b9f7bb842345f3864c71e877fda4200306ba5c044a43e6f7713a23bc4769b91a/' "$out/gen/Deps/Sdk.dhall"
  perl -i -pe 's/46b527b071eba96a17e76b4bc5774645714dd5b4355974d221e705aa7c126e77/14c43eec97972ae27afe3386ff937d04db66f84273d5551476361db12d2c4b50/' "$out/gen/Deps/Lude.dhall"
fi

cd "$out/tests/fixture-project"
pgn --database-url "$url" generate
echo
echo "done: $out/tests/fixture-project/artifacts/python"
