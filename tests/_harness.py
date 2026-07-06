"""Plain helpers shared by the harness fixtures and tests.

Fixtures live in conftest.py; this module holds path constants and the pgn
subprocess wrapper so test modules can import them without reaching into
conftest.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import psycopg
from psycopg.conninfo import conninfo_to_dict

HERE = Path(__file__).resolve().parent
GEN_DIR = HERE.parent / "gen"
FIXTURE_PROJECT = HERE / "fixture-project"
GOLDEN_DIR = HERE / "golden"

# pgn creates its own temp database from this admin URL; we never write into the
# target database itself. Default points at a local Postgres on the standard port;
# override with PGN_TEST_DATABASE_URL for a non-default instance (e.g. pg0 on 54321).
DEFAULT_ADMIN_URL = "postgresql://postgres:postgres@localhost:5432/postgres?sslmode=disable"
PROTECTED_DATABASES = frozenset({"postgres", "template0", "template1"})


def admin_database_url() -> str:
    return os.environ.get("PGN_TEST_DATABASE_URL", DEFAULT_ADMIN_URL)


def effective_database_name(url: str) -> str:
    """The database libpq actually connects to, resolved by psycopg.

    libpq takes dbname from the URI path OR a dbname= query parameter (last wins),
    falling back to the connecting user when neither is given. Hand-parsing only the
    path let a dbname= parameter smuggle a protected DB past the guard, so resolve it
    the way the driver does. An unparseable URL fails closed (empty name -> rejected).
    """
    try:
        info = conninfo_to_dict(url)
    except psycopg.ProgrammingError:
        return ""
    # Mirror libpq precedence: dbname (URI path or dbname=) -> PGDATABASE -> user
    # (URI or PGUSER). conninfo_to_dict does not apply the env defaults, so resolve
    # them here, else a path-less, dbname-less URL with PGDATABASE set to a protected
    # name would slip past while libpq connected to the protected DB. Empty (OS-user
    # fallback only) returns "" and the caller rejects it.
    return str(
        info.get("dbname")
        or os.environ.get("PGDATABASE")
        or info.get("user")
        or os.environ.get("PGUSER")
        or ""
    )


def run_pgn(pgn_bin: str, admin_url: str, project_dir: Path, *args: str) -> subprocess.CompletedProcess[str]:
    """Run pgn with the global --database-url flag, cwd = the project directory."""
    return subprocess.run(
        [pgn_bin, "--database-url", admin_url, *args],
        cwd=project_dir,
        capture_output=True,
        text=True,
    )
