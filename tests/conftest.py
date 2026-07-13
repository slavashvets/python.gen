"""Shared fixtures for the pGenie Python generator harness.

The harness validates the fixture pgn project today. It never touches
pre-existing databases; any database it
creates is a uniquely named temp DB that it drops afterwards.
"""

from __future__ import annotations

import shutil
import subprocess
import uuid
from collections.abc import Iterator
from pathlib import Path

import psycopg
import pytest
from psycopg.conninfo import make_conninfo

from tests._harness import (
    FIXTURE_PROJECT,
    GOLDEN_DIR,
    HERE,
    SRC_DIR,
    admin_database_url,
    effective_database_name,
    ensure_droppable,
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
    # The admin URL conventionally points at the "postgres" maintenance DB; the
    # harness only uses it to CREATE/DROP uniquely named temp databases, so a
    # protected name is fine here. Destructive protection lives at the drop site
    # (ensure_droppable). Resolve the name libpq would actually use (falling back
    # to the user for a path-less URL) and require it to be explicit.
    name = effective_database_name(url)
    if not name:
        pytest.fail(f"refusing to run against unspecified database in {url!r}")
    return url


@pytest.fixture
def roundtrip_db(pgn_admin_url: str) -> Iterator[str]:
    """A uniquely named throwaway database on pg0, dropped on teardown."""
    name = f"pgn_rt_{uuid.uuid4().hex[:12]}"
    admin = psycopg.connect(pgn_admin_url, autocommit=True)
    try:
        # Encoding to bytes sidesteps psycopg's LiteralString-typed execute
        # overload for these dynamic admin statements (the db name is a generated
        # hex, not user input).
        _ = admin.execute(f'CREATE DATABASE "{name}"'.encode())
    finally:
        admin.close()

    # Rebuild via conninfo (not string surgery) so host/port/user/params survive,
    # including a path-less admin URL the guard accepts.
    target = make_conninfo(pgn_admin_url, dbname=name)
    try:
        yield target
    finally:
        admin = psycopg.connect(pgn_admin_url, autocommit=True)
        try:
            terminate = (
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = %s AND pid <> pg_backend_pid()"
            )
            _ = admin.execute(terminate.encode(), (name,))
            ensure_droppable(name)
            _ = admin.execute(f'DROP DATABASE IF EXISTS "{name}"'.encode())
        finally:
            admin.close()


@pytest.fixture
def fixture_copy(tmp_path: Path) -> Path:
    """A writable copy of the fixture pgn project under tmp_path."""
    dest = tmp_path / "fixture-project"
    return shutil.copytree(FIXTURE_PROJECT, dest)


@pytest.fixture(scope="session")
def generated_tree(pgn_bin: str, pgn_admin_url: str, tmp_path_factory: pytest.TempPathFactory) -> Path:
    """Generate the fixture client once and return its artifacts/python dir.

    The generator path in project1.pgn.yaml is `../../src/package.dhall`,
    relative to the fixture project. To keep it resolvable the copy mirrors the
    real layout: `<tmp>/src` and `<tmp>/tests/fixture-project`. The freeze
    file is dropped so pgn re-resolves the working-tree generator instead of a
    cached hash (a stale freeze makes pgn ignore src/ edits and silently
    emit the old output).
    """
    root = tmp_path_factory.mktemp("pygen")
    _ = shutil.copytree(SRC_DIR, root / "src")
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
    packages = [path for path in generated_src.iterdir() if path.is_dir()]
    assert len(packages) == 1, f"expected exactly one generated package, found {packages}"
    pkg_dir = packages[0]
    assert pkg_dir.name == "specimen_client"

    _ = shutil.copytree(
        shell_src,
        root / "src",
        ignore=shutil.ignore_patterns("_generated", "__init__.py", "sync"),
    )
    dest_pkg = root / "src" / pkg_dir.name
    _ = shutil.copytree(pkg_dir / "_generated", dest_pkg / "_generated")
    _ = shutil.copy2(pkg_dir / "__init__.py", dest_pkg / "__init__.py")
    _ = shutil.copytree(pkg_dir / "sync", dest_pkg / "sync")
    return root
