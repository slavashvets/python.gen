"""Pins pgn's actual YAML->Dhall decode semantics for the Optional Config knobs.

pgn's decode behavior for record types is undocumented, so each artifact in
project1.pgn.yaml drives a different subset of `config` keys through the same
compile.dhall and the assertions below record what pgn 0.6.5 was observed to do,
not a documented contract. These variants are pinned by the directory/package
name and which surface (sync or async) they produce, not a full golden tree.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    os.environ.get("HARNESS_CI_REDUCED") == "1",
    reason=(
        "variant decode semantics are pinned locally; CI runs the reduced "
        "single-artifact project because pgn generate of all 7 artifacts "
        "exhausts GitHub-hosted runner memory"
    ),
)


def _artifact_src(generated_tree: Path, artifact_key: str) -> Path:
    # generated_tree is <project>/artifacts/python; artifact directories are
    # named after the artifact key with "-" replaced by "_" (pgn's own doing,
    # independent of the Dhall config below).
    project_root = generated_tree.parent.parent
    artifact_dir = artifact_key.replace("-", "_")
    return project_root / "artifacts" / artifact_dir / "src"


def _package_dir(generated_tree: Path, artifact_key: str) -> Path:
    src = _artifact_src(generated_tree, artifact_key)
    packages = [p for p in src.iterdir() if p.is_dir()]
    assert len(packages) == 1, f"expected exactly one package under {src}, found {packages}"
    return packages[0]


def _is_sync(package: Path) -> bool:
    """Whether the generated package's runtime module is the sync surface.

    There is no `sync/` subdirectory to check anymore (config.sync selects
    which content is rendered at the *same* `_runtime.py` path); the async
    body defines `async def fetch_many`, the sync body defines `def
    fetch_many` with no `async`.
    """
    runtime = (package / "_generated" / "_runtime.py").read_text()
    return "async def fetch_many" not in runtime


def test_name_only_config_derives_package_and_defaults_sync_off(generated_tree: Path) -> None:
    package = _package_dir(generated_tree, "python-name-only")
    assert package.name == "name_only_client"
    assert not _is_sync(package)


def test_sync_only_config_defaults_package_name_from_project(generated_tree: Path) -> None:
    package = _package_dir(generated_tree, "python-sync-only")
    assert package.name == "fixture"
    assert _is_sync(package)


def test_empty_config_object_defaults_both_fields(generated_tree: Path) -> None:
    package = _package_dir(generated_tree, "python-empty")
    assert package.name == "fixture"
    assert not _is_sync(package)


def test_absent_config_key_defaults_both_fields(generated_tree: Path) -> None:
    """No `config:` key at all decodes the same as `config: {}` (None Config)."""
    package = _package_dir(generated_tree, "python-bare")
    assert package.name == "fixture"
    assert not _is_sync(package)


def test_unknown_config_key_is_ignored_not_rejected(generated_tree: Path) -> None:
    """An extra key not in the generator's Config type (bogusField) does not fail generation."""
    package = _package_dir(generated_tree, "python-unknown-key")
    assert package.name == "unknown_key_client"
    assert not _is_sync(package)


def test_null_value_decodes_as_absent_field(generated_tree: Path) -> None:
    """`sync: null` decodes to None, same as omitting the key (default False)."""
    package = _package_dir(generated_tree, "python-null")
    assert package.name == "null_client"
    assert not _is_sync(package)
