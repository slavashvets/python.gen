"""The generator must reject an unsupported PG type loudly, unless configured
to skip.

Generation has to fail non-zero and name the offending type rather than emit
silently-wrong Python. The Primitive interpreter promises this via
`Compiled.report`, but the golden/roundtrip suites only exercise the SUPPORTED
surface, so without this test a regression that weakened the loud-fail contract
would go unnoticed until a real unsupported column shipped.

The Skip tests below exercise the opposite contract: `onUnsupported: Skip`
must drop only the smallest self-consistent unit (a statement, or a custom
type and everything that references it) and keep generating, rather than
aborting or emitting a half-generated module.
"""

from __future__ import annotations

import importlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from tests._harness import FIXTURE_PROJECT, GEN_DIR, HERE, run_pgn

HARNESS_ROOT = HERE.parent


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

    # Explicit `onUnsupported: Fail` (vs the absent-key default the money test
    # covers): pins that pgn decodes the bare YAML string "Fail" into the
    # < Fail | Skip > union tag, mirroring the "Skip" decode the Skip test pins.
    _ = (project / "project1.pgn.yaml").write_text(
        "space: python-gen\n"
        "name: fixture\n"
        "version: 0.0.0\n"
        "postgres: 18\n"
        "artifacts:\n"
        "  python:\n"
        "    gen: ../../gen/Gen.dhall\n"
        "    config:\n"
        "      onUnsupported: Fail\n"
    )

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


def test_skip_unsupported_drops_offending_units_and_cascades(
    pgn_bin: str, pgn_admin_url: str, tmp_path: Path
) -> None:
    """onUnsupported: Skip drops only the smallest self-consistent unit.

    Three independent failures in one project: a money result column and a
    jsonb[] param each doom their own statement (Primitive.dhall / ParamsMember
    .dhall); a composite nesting another composite dooms the custom type
    itself (CustomType.dhall's nestedLookup is hardcoded Absent for any nested
    custom-type reference) and, because the lookup built from the surviving
    types resolves it to Absent, the query selecting that composite column
    cascades into a skip too. Generation must still succeed, the surviving
    statements and all 3 fixture types must be unaffected, no generated file
    may reference a skipped name, the package must still import, and
    basedpyright strict must still pass on the result -- the same gate the
    golden package is held to.
    """
    root = tmp_path / "pygen"
    _ = shutil.copytree(GEN_DIR, root / "gen")
    project = shutil.copytree(FIXTURE_PROJECT, root / "tests" / "fixture-project")
    (project / "freeze1.pgn.yaml").unlink(missing_ok=True)
    shutil.rmtree(project / "artifacts", ignore_errors=True)

    # Skip mode evaluates every query twice (the keep/drop check plus the
    # final render; see Interpreters/Project.dhall), and a full-fixture Skip
    # generate peaks past the ~8 GB of a hosted CI runner. Two survivors are
    # enough: get_specimen references mood and point_2_d, get_tagged_item
    # references tag_value, so every custom type still proves it survives.
    kept_statements = ["get_specimen", "get_tagged_item"]
    for query_file in (project / "queries").iterdir():
        if query_file.name.split(".", 1)[0] not in kept_statements:
            query_file.unlink()

    # A single Skip artifact, package name left at its "fixture" default so it
    # cannot collide with the "specimen_client" package the shared golden/
    # roundtrip suites import.
    _ = (project / "project1.pgn.yaml").write_text(
        "space: python-gen\n"
        "name: fixture\n"
        "version: 0.0.0\n"
        "postgres: 18\n"
        "artifacts:\n"
        "  python:\n"
        "    gen: ../../gen/Gen.dhall\n"
        "    config:\n"
        "      onUnsupported: Skip\n"
    )

    _ = (project / "queries" / "probe_unsupported.sql").write_text("SELECT 1::money AS amount\n")
    _ = (project / "queries" / "probe_json_array.sql").write_text(
        "SELECT cardinality($payloads::jsonb []) AS n\n"
    )
    _ = (project / "migrations" / "2.sql").write_text(
        "create type wrapped_point as (\n"
        "  label text,\n"
        "  origin point2d\n"
        ");\n"
        "\n"
        "create table nested_probe (\n"
        "  id      int8 primary key generated always as identity,\n"
        "  wrapped wrapped_point not null\n"
        ");\n"
    )
    _ = (project / "queries" / "probe_nested_composite.sql").write_text(
        "SELECT wrapped FROM nested_probe LIMIT 1\n"
    )

    result = run_pgn(pgn_bin, pgn_admin_url, project, "generate")
    assert result.returncode == 0, f"Skip mode must still succeed:\n{result.stdout}\n{result.stderr}"

    # pgn 0.6.5 does not surface the generator's Compiled.warnings anywhere --
    # not stdout, not stderr, no written warnings file -- for this Files-based
    # generator contract; this is an observed fact about pgn, not something
    # the generator controls, so this pins it rather than asserting the
    # warning text is visible.
    combined = (result.stdout + result.stderr).lower()
    for marker in ("unsupported type", "json/jsonb array", "custom type not found"):
        assert marker not in combined, f"expected pgn to swallow the warning silently, found {marker!r} in output"

    generated = project / "artifacts" / "python"
    package_src = generated / "src" / "fixture"
    src = package_src / "_generated"

    for name in ("probe_unsupported", "probe_json_array", "probe_nested_composite"):
        assert not (src / "statements" / f"{name}.py").exists(), f"{name} should have been skipped"
    assert not (src / "types" / "wrapped_point.py").exists(), "wrapped_point should have been skipped"

    for name in kept_statements:
        assert (src / "statements" / f"{name}.py").is_file(), f"{name} should not have been skipped"
    for name in ("mood", "point_2_d", "tag_value"):
        assert (src / "types" / f"{name}.py").is_file(), f"{name} should not have been skipped"

    facade = (package_src / "__init__.py").read_text()
    rows = (src / "_rows.py").read_text()
    register = (src / "_register.py").read_text()
    types_init = (src / "types" / "__init__.py").read_text()
    for orphan in (
        "probe_unsupported",
        "probe_json_array",
        "probe_nested_composite",
        "wrapped_point",
        "WrappedPoint",
    ):
        assert orphan not in facade, f"facade references skipped {orphan}"
        assert orphan not in rows, f"_rows references skipped {orphan}"
        assert orphan not in register, f"_register references skipped {orphan}"
        assert orphan not in types_init, f"types/__init__ references skipped {orphan}"

    src_root = str(generated / "src")
    sys.path.insert(0, src_root)
    try:
        for name in list(sys.modules):
            if name == "fixture" or name.startswith("fixture."):
                del sys.modules[name]
        importlib.import_module("fixture")
        importlib.import_module("fixture._generated._register")
        importlib.import_module("fixture._generated._rows")
        for name in kept_statements:
            importlib.import_module(f"fixture._generated.statements.{name}")
    finally:
        sys.path.remove(src_root)
        for name in list(sys.modules):
            if name == "fixture" or name.startswith("fixture."):
                del sys.modules[name]

    config = tmp_path / "pyrightconfig.json"
    _ = config.write_text(
        json.dumps(
            {
                "pythonVersion": "3.12",
                "typeCheckingMode": "strict",
                "include": [str(generated / "src")],
                "venvPath": str(HARNESS_ROOT),
                "venv": ".venv",
                "reportMissingModuleSource": False,
            }
        )
    )
    pyright_result = subprocess.run(
        ["basedpyright", "--project", str(config), "--outputjson"],
        capture_output=True,
        text=True,
    )
    if not pyright_result.stdout.strip():
        pytest.fail(f"basedpyright produced no JSON (exit {pyright_result.returncode}):\n{pyright_result.stderr}")
    summary = json.loads(pyright_result.stdout)["summary"]
    assert summary["filesAnalyzed"] > 0, f"basedpyright analyzed no files; bad include path?\n{pyright_result.stdout}"
    assert summary["errorCount"] == 0 and summary["warningCount"] == 0, (
        f"basedpyright strict reported issues on the Skip output: {summary}\n{pyright_result.stdout}"
    )
