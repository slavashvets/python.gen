"""Plain helpers shared by the harness fixtures and tests.

Fixtures live in conftest.py; this module holds path constants and the pgn
subprocess wrapper so test modules can import them without reaching into
conftest.
"""

from __future__ import annotations

import os
import signal
import subprocess
import threading
from pathlib import Path

import psycopg
from psycopg.conninfo import conninfo_to_dict

# RSS budget for a pgn subprocess, in GB. A single-artifact generate peaks
# ~35 GB RSS on this 48 GB machine, and an unbounded run once climbed to ~80 GB
# RSS+swap and had to be emergency-killed. The default leaves headroom over the
# measured ~35 GB; override with PGN_MAX_RSS_GB (a float number of GB).
DEFAULT_MAX_RSS_GB = 40.0

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


def ensure_droppable(name: str) -> None:
    """Refuse to drop a protected (system/maintenance) database.

    The harness only ever drops the uniquely named temp databases it created
    itself, so this should never fire; it is a belt-and-suspenders guard at the
    single destructive site.
    """
    if not name or name in PROTECTED_DATABASES:
        raise RuntimeError(f"refusing to drop protected or unspecified database {name!r}")


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


def _rss_gb(pid: int) -> float | None:
    """RSS of pid in GB via `ps -o rss= -p <pid>` (kilobytes on macOS).

    Returns None if the process is already gone (ps prints nothing / non-zero).
    """
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True)
    value = out.stdout.strip()
    if out.returncode != 0 or not value:
        return None
    return int(value) / (1024 * 1024)  # KB -> GB


def run_pgn(pgn_bin: str, admin_url: str, project_dir: Path, *args: str) -> subprocess.CompletedProcess[str]:
    """Run pgn with the global --database-url flag, cwd = the project directory.

    pgn's per-artifact closure normalization is memory-hungry, so a runaway
    generate can exhaust the host. pgn runs in its own process group and a
    watchdog thread polls its RSS every 2 s; on breach of PGN_MAX_RSS_GB
    (default DEFAULT_MAX_RSS_GB) it kills the whole group and this raises, so
    the offending test fails instead of the machine going down.
    """
    budget_gb = float(os.environ.get("PGN_MAX_RSS_GB", DEFAULT_MAX_RSS_GB))
    proc = subprocess.Popen(
        [pgn_bin, "--database-url", admin_url, *args],
        cwd=project_dir,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,  # own process group so we can kill the whole tree
    )

    done = threading.Event()
    state: dict[str, object] = {"peak_gb": 0.0, "killed": False}

    def watchdog() -> None:
        while True:
            rss = _rss_gb(proc.pid)
            if rss is not None:
                state["peak_gb"] = max(float(state["peak_gb"]), rss)  # type: ignore[arg-type]
                if rss > budget_gb:
                    state["killed"] = True
                    try:
                        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    except (ProcessLookupError, PermissionError):
                        pass
                    return
            if done.wait(2.0):  # normal exit signalled, or poll interval elapsed
                return

    thread = threading.Thread(target=watchdog, daemon=True)
    thread.start()
    try:
        stdout, stderr = proc.communicate()
    finally:
        done.set()
        thread.join()

    if state["killed"]:
        raise RuntimeError(
            f"pgn watchdog killed the process group: RSS {float(state['peak_gb']):.1f} GB "
            f"exceeded the PGN_MAX_RSS_GB={budget_gb:.1f} GB budget"
        )

    return subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr)
