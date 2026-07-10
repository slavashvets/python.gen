#!/usr/bin/env bash
# Cold-cache benchmark of `pgn generate` on the fixture project, comparing the
# current gen (Deps imported `as Source`) against the same tree with the
# pre-as-Source Deps (plain pinned imports). Both variants run the same pgn
# binary by default, so the measurement isolates the import mode itself.
#
#   mise run bench:as-source
#
# Needs a reachable Postgres; override with PGN_TEST_DATABASE_URL. Each variant
# gets a fresh XDG_CACHE_HOME, so every run pays the full cold import cost.
# PGN_BEFORE_BIN selects a different pgn for the before variant (e.g. 0.8.0,
# which predates `as Source` and can only run that variant):
#
#   PGN_BEFORE_BIN="$(mise x github:pgenie-io/pgenie@0.8.0 -- sh -c 'command -v pgn')" \
#     mise run bench:as-source
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
url="${PGN_TEST_DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/postgres?sslmode=disable}"
pgn="${PGN_BIN:-$(command -v pgn)}"
pgn_before="${PGN_BEFORE_BIN:-$pgn}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

prepare() { # $1 = variant root; mirrors the repo layout the fixture expects
  rm -rf "$1" && mkdir -p "$1/tests"
  cp -R "$root/gen" "$1/gen"
  cp -R "$root/tests/fixture-project" "$1/tests/fixture-project"
  rm -f "$1/tests/fixture-project/freeze1.pgn.yaml"
  rm -rf "$1/tests/fixture-project/artifacts"
}

# Rewrite Deps to the pre-as-Source form: drop the mode and restore the
# normalized-expression pins (an `as Source` pin hashes the import's source,
# so the two modes need different sha256 values for the same version).
strip_as_source() { # $1 = variant root
  perl -i -ne 'print unless /^\s*as Source$/' "$1"/gen/Deps/*.dhall
  perl -i -pe 's/8d43544ecb0e612406af3133bdbca51138c704a77a5a29ef62fe034d0e77a3a6/b9f7bb842345f3864c71e877fda4200306ba5c044a43e6f7713a23bc4769b91a/' "$1/gen/Deps/Sdk.dhall"
  perl -i -pe 's/46b527b071eba96a17e76b4bc5774645714dd5b4355974d221e705aa7c126e77/14c43eec97972ae27afe3386ff937d04db66f84273d5551476361db12d2c4b50/' "$1/gen/Deps/Lude.dhall"
}

measure() { # $1 = label, $2 = variant root, $3 = pgn binary
  local label=$1 variant=$2 bin=$3
  local cache="$work/cache-$label" log="$work/$label.log"
  mkdir -p "$cache"
  local timecmd=(/usr/bin/time -l)
  [ "$(uname)" = Linux ] && timecmd=(/usr/bin/time -v)
  echo "-- $label (cold cache, $("$bin" --version 2>/dev/null || echo pgn))"
  ( cd "$variant/tests/fixture-project" \
    && XDG_CACHE_HOME="$cache" "${timecmd[@]}" "$bin" --database-url "$url" generate ) \
    >"$log" 2>&1
  local rc=$?
  if [ "$(uname)" = Linux ]; then
    grep -E 'Elapsed \(wall clock\)|Maximum resident set size' "$log" | sed 's/^\s*/   /'
  else
    awk '/ real /{printf "   wall: %ss\n",$1} /maximum resident set size/{printf "   peak RSS: %.2f GB\n",$1/1073741824}' "$log"
  fi
  echo "   exit code: $rc"
  [ $rc -ne 0 ] && { echo "   last error lines:"; grep -a "Error" "$log" | tail -3 | sed 's/^/   /'; }
  return 0
}

prepare "$work/before"; strip_as_source "$work/before"
prepare "$work/after"

measure "before-as-Source" "$work/before" "$pgn_before"
measure "with-as-Source"   "$work/after"  "$pgn"
