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
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from tests._harness import (
    FIXTURE_PROJECT,
    GOLDEN_DIR,
    HERE,
    SRC_DIR,
    run_pgn,
)

HARNESS_ROOT = HERE.parent


def _fresh_project(tmp_path: Path) -> tuple[Path, Path]:
    root = tmp_path / "pygen"
    _ = shutil.copytree(SRC_DIR, root / "src")
    project = shutil.copytree(FIXTURE_PROJECT, root / "tests" / "fixture-project")
    (project / "freeze1.pgn.yaml").unlink(missing_ok=True)
    shutil.rmtree(project / "artifacts", ignore_errors=True)
    return root, project


def _write_single_artifact(
    project: Path,
    generator: str,
    package_name: str,
    mode: str | None = "Fail",
) -> None:
    unsupported_config = "" if mode is None else f"      onUnsupported: {mode}\n"
    _ = (project / "project1.pgn.yaml").write_text(
        "space: python-gen\n"
        "name: fixture\n"
        "version: 0.0.0\n"
        "postgres: 18\n"
        "artifacts:\n"
        "  python:\n"
        f"    gen: {generator}\n"
        "    config:\n"
        f"      packageName: {package_name}\n"
        f"{unsupported_config}"
    )


def _combined_output(result: subprocess.CompletedProcess[str]) -> str:
    return result.stdout + result.stderr


def _clear_package_modules(package_name: str) -> None:
    for name in list(sys.modules):
        if name == package_name or name.startswith(f"{package_name}."):
            del sys.modules[name]


def test_unsupported_pg_type_fails_loudly(pgn_bin: str, pgn_admin_url: str, tmp_path: Path) -> None:
    _, project = _fresh_project(tmp_path)
    _write_single_artifact(project, "../../src/package.dhall", "unsupported-money", None)

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
    _, project = _fresh_project(tmp_path)

    # Explicit `onUnsupported: Fail` (vs the absent-key default the money test
    # covers): pins that pgn decodes the bare YAML string "Fail" into the
    # < Fail | Skip > union tag, mirroring the "Skip" decode the Skip test pins.
    _write_single_artifact(project, "../../src/package.dhall", "unsupported-json-array")

    # A jsonb[] param has no faithful psycopg bind (Jsonb wraps a scalar, not
    # element-wise); the generator must reject it, not emit an unwrapped list.
    _ = (project / "queries" / "probe_json_array.sql").write_text("SELECT cardinality($payloads::jsonb []) AS n\n")

    result = run_pgn(pgn_bin, pgn_admin_url, project, "generate")

    assert result.returncode != 0, f"expected generation to fail on a json array param, it succeeded:\n{result.stdout}"
    combined = (result.stdout + result.stderr).lower()
    assert "json/jsonb array" in combined, (
        f"the failure did not name the json array param:\n{result.stdout}\n{result.stderr}"
    )


def _write_contract_probe(
    root: Path,
    *,
    interpreter: str,
    lookup_kind: str,
    dimensionality: int,
    nested: bool,
) -> None:
    array_settings = (
        "None Model.ArraySettings"
        if dimensionality == 0
        else f"Some {{ dimensionality = {dimensionality}, elementIsNullable = False }}"
    )
    lookup = {
        "absent": "CustomKind.TypeKind.Absent",
        "enum": ('CustomKind.TypeKind.Enum { className = "ProbeValue", moduleName = "probe_value", order = 0 }'),
        "composite": (
            "CustomKind.TypeKind.Composite "
            "{ fields = [] : List CustomKind.CompositeField, "
            'identity = { className = "ProbeValue", moduleName = "probe_value", order = 0 } }'
        ),
    }[lookup_kind]
    custom_type_name_mappings = (
        ", customTypeNameMappings = [] : List PythonNameMapping.CustomType" if interpreter == "CustomType" else ""
    )
    target_input = "customType" if nested else "member"
    custom_type = (
        """
        let customType
            : Model.CustomType
            = { definition =
                  < Enum : List Model.EnumVariant
                  | Composite : List Model.Member
                  | Domain : Model.Value
                  >.Composite [ member ]
              , name
              , pgName = "outer_custom"
              , pgSchema = "public"
              }
        """
        if nested
        else ""
    )
    wrapper = f"""
let Lude = ./Deps/Lude.dhall

let Model = ./Deps/Contract.dhall

let Sdk = ./Deps/Sdk.dhall

let OnUnsupported = ./Structures/OnUnsupported.dhall

let CustomKind = ./Structures/CustomKind.dhall

let PythonNameMapping = ./Structures/PythonNameMapping.dhall

let Target = ./Interpreters/{interpreter}.dhall

let Config =
      {{ packageName : Optional Text
      , emitSync : Optional Bool
      , onUnsupported : Optional OnUnsupported.Mode
      }}

let Config/default =
      {{ packageName = None Text
      , emitSync = None Bool
      , onUnsupported = None OnUnsupported.Mode
      }}

let interpreterConfig =
      {{ packageName = "contract-probe"
      , importName = "contract_probe"
      , emitSync = False
      , onUnsupported = OnUnsupported.Mode.Fail
      {custom_type_name_mappings}
      }}

let run =
      \\(_ : Config) ->
      \\(input : Model.Project) ->
        let name = input.name

        let member
            : Model.Member
            = {{ isNullable = False
              , name
              , pgName = "probe_value"
              , value =
                  {{ arraySettings = {array_settings}
                  , scalar = Model.Scalar.Custom name
                  }}
              }}

{custom_type}
        let lookup
            : CustomKind.Lookup
            = \\(_ : Model.Name) -> {lookup}

        in  Lude.Compiled.map
              Target.Output
              Lude.Files.Type
              (\\(_ : Target.Output) -> [] : Lude.Files.Type)
              (Target.run interpreterConfig lookup {target_input})

in  Sdk.Sigs.generator Config Config/default run
"""
    _ = (root / "src" / "contract-probe.dhall").write_text(wrapper)


# PostgreSQL flattens array rank and valid projects resolve customs, so synthetic
# inputs are required to reach the rank-2 and missing-reference contracts.
@pytest.mark.parametrize(
    ("case_id", "interpreter", "lookup_kind", "dimensionality", "nested", "message", "path_tokens"),
    [
        pytest.param(
            "missing_custom",
            "Member",
            "absent",
            0,
            False,
            "Custom type not found in project customTypes",
            ("fixture",),
            id="missing-custom",
        ),
        pytest.param(
            "custom_array_member",
            "CustomType",
            "composite",
            1,
            True,
            "Custom array fields inside a composite type are not supported",
            ("fixture", "probe_value"),
            id="custom-array-member",
        ),
        pytest.param(
            "composite_rank_two_result",
            "Member",
            "composite",
            2,
            False,
            "Array of a composite type with dimensionality > 1 is not supported",
            ("fixture", "probe_value"),
            id="composite-rank-two-result",
        ),
        pytest.param(
            "composite_rank_two_parameter",
            "ParamsMember",
            "composite",
            2,
            False,
            "Array of a composite type parameter with dimensionality > 1 is not supported",
            ("fixture", "probe_value"),
            id="composite-rank-two-parameter",
        ),
        pytest.param(
            "enum_rank_three_result",
            "Member",
            "enum",
            3,
            False,
            "Array of an enum with dimensionality > 2 is not supported",
            ("fixture", "probe_value"),
            id="enum-rank-three-result",
        ),
        pytest.param(
            "enum_rank_three_parameter",
            "ParamsMember",
            "enum",
            3,
            False,
            "Array of an enum parameter with dimensionality > 2 is not supported",
            ("fixture", "probe_value"),
            id="enum-rank-three-parameter",
        ),
    ],
)
def test_custom_shape_contracts_fail_loudly(
    pgn_bin: str,
    pgn_admin_url: str,
    tmp_path: Path,
    case_id: str,
    interpreter: str,
    lookup_kind: str,
    dimensionality: int,
    nested: bool,
    message: str,
    path_tokens: tuple[str, ...],
) -> None:
    root, project = _fresh_project(tmp_path)
    for query_file in (project / "queries").iterdir():
        query_file.unlink()
    _write_contract_probe(
        root,
        interpreter=interpreter,
        lookup_kind=lookup_kind,
        dimensionality=dimensionality,
        nested=nested,
    )
    _write_single_artifact(project, "../../src/contract-probe.dhall", f"probe-{case_id}")

    result = run_pgn(pgn_bin, pgn_admin_url, project, "generate")
    combined = _combined_output(result)
    assert result.returncode != 0, f"expected {case_id} to fail:\n{combined}"
    assert message in combined, f"missing exact diagnostic {message!r}:\n{combined}"

    plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", combined)
    message_at = plain.index(message)
    diagnostic = plain[max(0, message_at - 500) : message_at + len(message) + 1000]
    stage = re.search(
        r"Stage:\s*Generating\s*>\s*python\s*>\s*Compiling\s*>\s*([^\r\n]+)",
        diagnostic,
    )
    assert stage, f"diagnostic had no pgn Stage path:\n{plain}"
    rendered_path = tuple(re.split(r"\s*>\s*", stage.group(1).strip()))
    assert rendered_path == path_tokens, f"expected exact path {path_tokens}, got {rendered_path}:\n{plain}"


@pytest.mark.parametrize(
    ("case_id", "interpreter", "lookup_kind", "dimensionality", "nested"),
    [
        pytest.param("nested_scalar", "CustomType", "composite", 0, True, id="nested-scalar"),
        pytest.param("enum_rank_two_result", "Member", "enum", 2, False, id="enum-rank-two-result"),
        pytest.param(
            "enum_rank_two_parameter",
            "ParamsMember",
            "enum",
            2,
            False,
            id="enum-rank-two-parameter",
        ),
        pytest.param(
            "composite_array_result",
            "Member",
            "composite",
            1,
            False,
            id="composite-array-result",
        ),
        pytest.param(
            "composite_array_parameter",
            "ParamsMember",
            "composite",
            1,
            False,
            id="composite-array-parameter",
        ),
    ],
)
def test_custom_shape_contracts_succeed(
    pgn_bin: str,
    pgn_admin_url: str,
    tmp_path: Path,
    case_id: str,
    interpreter: str,
    lookup_kind: str,
    dimensionality: int,
    nested: bool,
) -> None:
    root, project = _fresh_project(tmp_path)
    for query_file in (project / "queries").iterdir():
        query_file.unlink()
    _write_contract_probe(
        root,
        interpreter=interpreter,
        lookup_kind=lookup_kind,
        dimensionality=dimensionality,
        nested=nested,
    )
    _write_single_artifact(project, "../../src/contract-probe.dhall", f"probe-{case_id}")

    result = run_pgn(pgn_bin, pgn_admin_url, project, "generate")
    assert result.returncode == 0, f"expected {case_id} to succeed:\n{_combined_output(result)}"


def test_skip_unsupported_drops_offending_units_and_cascades(pgn_bin: str, pgn_admin_url: str, tmp_path: Path) -> None:
    """onUnsupported: Skip drops only the smallest self-consistent unit.

    Three independent failures in one project: a money result column and a
    jsonb[] param each doom their own statement (Primitive.dhall / ParamsMember
    .dhall); a composite containing a custom array dooms that type, its scalar
    custom parent, its grandparent, and the dependent query through the bounded
    survivor closure. Generation must still succeed, the surviving statements
    and all 5 fixture types must be unaffected, no generated file
    may reference a skipped name, the package must still import, and
    basedpyright strict must still pass on the result -- the same gate the
    golden package is held to.
    """
    _, project = _fresh_project(tmp_path)

    # Skip mode evaluates every query twice (the keep/drop check plus the
    # final render; see Interpreters/Project.dhall), and a full-fixture Skip
    # generate peaks past the ~8 GB of a hosted CI runner. Two survivors are
    # enough: get_specimen references mood and point_2_d, get_tagged_item
    # references tag_value, so every custom type still proves it survives.
    kept_statements = ["get_specimen", "get_tagged_item"]
    for query_file in (project / "queries").iterdir():
        if query_file.name.split(".", 1)[0] not in kept_statements:
            query_file.unlink()

    # A unique package prefix prevents collisions with the golden and roundtrip
    # packages imported by the shared test process.
    _write_single_artifact(project, "../../src/package.dhall", "skip-cascade", "Skip")

    _ = (project / "queries" / "probe_unsupported.sql").write_text("SELECT 1::money AS amount\n")
    _ = (project / "queries" / "probe_json_array.sql").write_text("SELECT cardinality($payloads::jsonb []) AS n\n")
    _ = (project / "queries" / "probe_custom_only.sql").write_text("SELECT 'happy'::mood AS feeling\n")
    _ = (project / "migrations" / "2.sql").write_text(
        "create type z_bad_leaf as (\n"
        "  feelings mood[]\n"
        ");\n"
        "\n"
        "create type m_bad_parent as (\n"
        "  leaf z_bad_leaf\n"
        ");\n"
        "\n"
        "create type a_bad_grandparent as (\n"
        "  parent m_bad_parent\n"
        ");\n"
        "\n"
        "create table nested_probe (\n"
        "  id      int8 primary key generated always as identity,\n"
        "  wrapped a_bad_grandparent not null\n"
        ");\n"
    )
    _ = (project / "queries" / "probe_nested_composite.sql").write_text("SELECT wrapped FROM nested_probe LIMIT 1\n")

    result = run_pgn(pgn_bin, pgn_admin_url, project, "generate")
    assert result.returncode == 0, f"Skip mode must still succeed:\n{result.stdout}\n{result.stderr}"

    # Since 0.7.2 pgn surfaces the generator's Compiled.warnings during
    # generate (pgenie-io/pgenie#67), so every skipped unit must be visible in
    # the combined output.
    combined = _combined_output(result).lower()
    for marker in (
        "unsupported type",
        "json/jsonb array as a parameter is not supported",
        "custom array fields inside a composite type are not supported",
        "custom type not found in project customtypes",
    ):
        assert marker in combined, f"expected pgn to surface the warning, {marker!r} missing from output"

    generated = project / "artifacts" / "python"
    package_name = "skip_cascade"
    package_src = generated / "src" / package_name
    src = package_src / "_generated"

    for name in ("probe_unsupported", "probe_json_array", "probe_nested_composite"):
        assert not (src / "statements" / f"{name}.py").exists(), f"{name} should have been skipped"
    for name in ("z_bad_leaf", "m_bad_parent", "a_bad_grandparent"):
        assert not (src / "types" / f"{name}.py").exists(), f"{name} should have been skipped"

    for name in [*kept_statements, "probe_custom_only"]:
        assert (src / "statements" / f"{name}.py").is_file(), f"{name} should not have been skipped"
    for name in ("a_codec_wrapper", "mood", "point_2_d", "tag_value", "z_codec_payload"):
        assert (src / "types" / f"{name}.py").is_file(), f"{name} should not have been skipped"

    generated_python = {path: path.read_text() for path in package_src.rglob("*.py")}
    for orphan in (
        "probe_unsupported",
        "probe_json_array",
        "probe_nested_composite",
        "z_bad_leaf",
        "ZBadLeaf",
        "m_bad_parent",
        "MBadParent",
        "a_bad_grandparent",
        "ABadGrandparent",
    ):
        assert not any(orphan in text for text in generated_python.values()), (
            f"surviving generated output references skipped {orphan}"
        )

    custom_only = (src / "statements" / "probe_custom_only.py").read_text()
    assert "from .. import types as _db_types" in custom_only
    assert "_db_types.Mood" in custom_only
    assert "_args_row(ProbeCustomOnlyRow)" in custom_only

    src_root = str(generated / "src")
    sys.path.insert(0, src_root)
    try:
        _clear_package_modules(package_name)
        for module_path in sorted(package_src.rglob("*.py")):
            relative = module_path.relative_to(generated / "src").with_suffix("")
            parts = list(relative.parts)
            if parts[-1] == "__init__":
                parts.pop()
            importlib.import_module(".".join(parts))
    finally:
        sys.path.remove(src_root)
        _clear_package_modules(package_name)

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


def test_statement_custom_types_use_one_qualified_namespace_import() -> None:
    statements = GOLDEN_DIR / "src" / "specimen_client" / "_generated" / "statements"
    namespace_import = "from .. import types as _db_types"
    for module in statements.glob("*.py"):
        source = module.read_text()
        assert not re.search(r"^from \.\.types\.", source, re.MULTILINE), f"direct custom type import in {module}"
        if "_db_types." in source:
            assert source.count(namespace_import) == 1, f"expected one custom type namespace import in {module}"

    insert_specimen = (statements / "insert_specimen.py").read_text()
    for annotation in (
        "feeling: _db_types.Mood",
        "moods: list[_db_types.Mood | None] | None",
        "origin: _db_types.Point2D | None",
        "codec_payload: _db_types.ZCodecPayload",
        "codec_payloads: list[_db_types.ZCodecPayload | None]",
        "codec_wrapper: _db_types.ACodecWrapper | None",
    ):
        assert annotation in insert_specimen

    insert_tagged_item = (statements / "insert_tagged_item.py").read_text()
    assert "tag: _db_types.TagValue" in insert_tagged_item
