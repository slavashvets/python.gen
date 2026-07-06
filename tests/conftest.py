"""Shared fixtures for the pGenie Python generator harness.

The harness validates the fixture pgn project today. It never touches
pre-existing databases; any database it
creates is a uniquely named temp DB that it drops afterwards.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from tests._harness import (
    FIXTURE_PROJECT,
    GEN_DIR,
    GOLDEN_DIR,
    PROTECTED_DATABASES,
    HERE,
    admin_database_url,
    effective_database_name,
    run_pgn,
)


@pytest.fixture(scope="session")
def pgn_bin() -> str:
    """Absolute path to the mise-managed pgn binary.

    pgn is installed via mise from GitHub releases and is not on PATH outside the
    monorepo. Resolving it here lets the harness exec it with cwd set to a temp
    project copy that lives outside the repo.
    """
    resolved = shutil.which("pgn")
    if resolved:
        return resolved
    out = subprocess.run(["mise", "which", "pgn"], cwd=HERE, capture_output=True, text=True)
    path = out.stdout.strip()
    if out.returncode != 0 or not path:
        pytest.skip("pgn binary not resolvable via mise")
    return path


@pytest.fixture(scope="session")
def pgn_admin_url() -> str:
    url = admin_database_url()
    # pgn must connect to an admin DB that is not one of the app databases; the
    # actual work happens in a temp DB pgn creates and drops itself. Resolve the
    # name libpq would actually use (falling back to the user for a path-less URL)
    # and require it explicitly, so a protected DB cannot slip through as the user.
    name = effective_database_name(url)
    if not name or name in PROTECTED_DATABASES:
        pytest.fail(f"refusing to run against protected or unspecified database in {url!r}")
    return url


@pytest.fixture
def fixture_copy(tmp_path: Path) -> Path:
    """A writable copy of the fixture pgn project under tmp_path."""
    dest = tmp_path / "fixture-project"
    return shutil.copytree(FIXTURE_PROJECT, dest)


@pytest.fixture(scope="session")
def generated_tree(pgn_bin: str, pgn_admin_url: str, tmp_path_factory: pytest.TempPathFactory) -> Path:
    """Generate the fixture client once and return its artifacts/python dir.

    The generator path in project1.pgn.yaml is `../../gen/Gen.dhall`,
    relative to the fixture project. To keep it resolvable the copy mirrors the
    real layout: `<tmp>/gen` and `<tmp>/tests/fixture-project`. The freeze
    file is dropped so pgn re-resolves the working-tree generator instead of a
    cached hash (a stale freeze makes pgn ignore gen/ edits and silently
    emit the old output).
    """
    root = tmp_path_factory.mktemp("pygen")
    _ = shutil.copytree(GEN_DIR, root / "gen")
    project = shutil.copytree(FIXTURE_PROJECT, root / "tests" / "fixture-project")
    (project / "freeze1.pgn.yaml").unlink(missing_ok=True)
    shutil.rmtree(project / "artifacts", ignore_errors=True)

    result = run_pgn(pgn_bin, pgn_admin_url, project, "generate")
    assert result.returncode == 0, f"pgn generate failed:\n{result.stdout}\n{result.stderr}"

    generated = project / "artifacts" / "python"
    assert generated.is_dir(), "pgn generate produced no artifacts/python directory"
    return generated


@pytest.fixture(scope="session")
def full_package(generated_tree: Path, tmp_path_factory: pytest.TempPathFactory) -> Path:
    """An importable fixture package: the hand-written golden shell overlaid with
    the freshly generated subtree and facade.

    The generator emits <pkg>/_generated and the package-root __init__.py facade;
    the rest of the shell (pyproject.toml, py.typed) is hand-written. This overlays
    the fresh _generated subtree and the fresh facade onto the committed shell so
    the round-trip exercises the real consumer layout. Returns the package root
    holding `src/`.
    """
    root = tmp_path_factory.mktemp("pkg")
    shell_src = GOLDEN_DIR / "src"
    generated_src = generated_tree / "src"
    _ = shutil.copytree(shell_src, root / "src", ignore=shutil.ignore_patterns("_generated", "__init__.py"))
    for pkg_dir in generated_src.iterdir():
        dest_pkg = root / "src" / pkg_dir.name
        _ = shutil.copytree(pkg_dir / "_generated", dest_pkg / "_generated")
        _ = shutil.copy2(pkg_dir / "__init__.py", dest_pkg / "__init__.py")
        # The sync facade (sync/__init__.py) lives outside _generated, like the
        # async facade; overlay it too when the project emits a sync surface.
        sync_facade = pkg_dir / "sync" / "__init__.py"
        if sync_facade.exists():
            (dest_pkg / "sync").mkdir(parents=True, exist_ok=True)
            _ = shutil.copy2(sync_facade, dest_pkg / "sync" / "__init__.py")
    return root
