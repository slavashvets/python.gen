#!/usr/bin/env bash
# Wraps the Dhall-generated package (from fixtures/Exhaustive.dhall) in a minimal
# consumer shell, mirroring the hand-written tests/golden/ shell (pyproject.toml
# + py.typed) so basedpyright strict runs against the same layout a real
# consumer would import, per the full_package pattern in tests/conftest.py.
set -euo pipefail

generated_dir=$1
shell_dir=$2

src="$generated_dir/src"
packages=("$src"/*/)
if [[ ${#packages[@]} -ne 1 ]]; then
  echo "::error::Expected exactly one package under $src, found ${#packages[@]}" >&2
  exit 1
fi
pkg_dir=${packages[0]%/}
pkg_name=$(basename "$pkg_dir")

rm -rf "$shell_dir"
mkdir -p "$shell_dir/src"
cp -r "$pkg_dir" "$shell_dir/src/$pkg_name"
touch "$shell_dir/src/$pkg_name/py.typed"

cat > "$shell_dir/pyproject.toml" <<TOML
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "${pkg_name//_/-}"
version = "0.0.0"
requires-python = ">=3.12"
dependencies = ["psycopg>=3.3.4,<4"]

[tool.hatch.build.targets.wheel]
packages = ["src/$pkg_name"]
TOML
