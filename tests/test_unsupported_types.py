"""The generator must reject an unsupported PG type loudly.

Generation has to fail non-zero and name the offending type rather than emit
silently-wrong Python. The Primitive interpreter promises this via
`Compiled.report`, but the golden/roundtrip suites only exercise the SUPPORTED
surface, so without this test a regression that weakened the loud-fail contract
would go unnoticed until a real unsupported column shipped.
"""

from __future__ import annotations

import shutil
from pathlib import Path

from tests._harness import FIXTURE_PROJECT, GEN_DIR, run_pgn


def test_unsupported_pg_type_fails_loudly(pgn_bin: str, pgn_admin_url: str, tmp_path: Path) -> None:
    root = tmp_path / "pygen"
    _ = shutil.copytree(GEN_DIR, root / "gen")
    project = shutil.copytree(FIXTURE_PROJECT, root / "tests" / "fixture-project")
    (project / "freeze1.pgn.yaml").unlink(missing_ok=True)
    shutil.rmtree(project / "artifacts", ignore_errors=True)

    # `money` has no Python mapping (psycopg decodes it as a locale string, not Decimal),
    # so the Primitive interpreter must reject it instead of guessing.
    _ = (project / "queries" / "probe_unsupported.sql").write_text("SELECT 1::money AS amount\n")

    result = run_pgn(pgn_bin, pgn_admin_url, project, "generate")

    assert result.returncode != 0, f"expected generation to fail on an unsupported type, it succeeded:\n{result.stdout}"
    combined = (result.stdout + result.stderr).lower()
    assert "money" in combined or "unsupported" in combined, (
        f"the failure did not name the unsupported type:\n{result.stdout}\n{result.stderr}"
    )


def test_json_array_param_fails_loudly(pgn_bin: str, pgn_admin_url: str, tmp_path: Path) -> None:
    root = tmp_path / "pygen"
    _ = shutil.copytree(GEN_DIR, root / "gen")
    project = shutil.copytree(FIXTURE_PROJECT, root / "tests" / "fixture-project")
    (project / "freeze1.pgn.yaml").unlink(missing_ok=True)
    shutil.rmtree(project / "artifacts", ignore_errors=True)

    # A jsonb[] param has no faithful psycopg bind (Jsonb wraps a scalar, not
    # element-wise); the generator must reject it, not emit an unwrapped list.
    _ = (project / "queries" / "probe_json_array.sql").write_text(
        "SELECT cardinality($payloads::jsonb []) AS n\n"
    )

    result = run_pgn(pgn_bin, pgn_admin_url, project, "generate")

    assert result.returncode != 0, f"expected generation to fail on a json array param, it succeeded:\n{result.stdout}"
    combined = (result.stdout + result.stderr).lower()
    assert "json/jsonb array" in combined, (
        f"the failure did not name the json array param:\n{result.stdout}\n{result.stderr}"
    )
