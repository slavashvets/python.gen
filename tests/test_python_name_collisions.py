"""Real-pgn coverage for generated Python namespace collisions and mappings."""

from __future__ import annotations

import ast
import importlib
import shutil
import subprocess
import sys
from collections.abc import Iterable, Mapping, Sequence
from pathlib import Path

import pytest

from tests._harness import SRC_DIR, run_pgn

QueryMapping = tuple[str, str, str]
CustomTypeMapping = tuple[str, str, str, str]


def _project_yaml(
    *,
    query_mappings: Sequence[QueryMapping] = (),
    custom_type_mappings: Sequence[CustomTypeMapping] = (),
    on_unsupported: str | None = None,
) -> str:
    lines = [
        "space: python-gen",
        "name: python-name-collisions",
        "version: 0.0.0",
        "postgres: 18",
        "artifacts:",
        "  python:",
        "    gen: ../src/package.dhall",
        "    config:",
        "      packageName: mapping-client",
        "      emitSync: true",
    ]

    if on_unsupported is not None:
        lines.append(f"      onUnsupported: {on_unsupported}")

    if query_mappings:
        lines.append("      queryNameMappings:")
        for source, snake_case, pascal_case in query_mappings:
            lines.extend(
                [
                    f"        - source: {source}",
                    "          target:",
                    f"            snakeCase: {snake_case}",
                    f"            pascalCase: {pascal_case}",
                ]
            )

    if custom_type_mappings:
        lines.append("      customTypeNameMappings:")
        for schema, name, snake_case, pascal_case in custom_type_mappings:
            lines.extend(
                [
                    "        - source:",
                    f"            schema: {schema}",
                    f"            name: {name}",
                    "          target:",
                    f"            snakeCase: {snake_case}",
                    f"            pascalCase: {pascal_case}",
                ]
            )

    return "\n".join(lines) + "\n"


def _fresh_project(
    tmp_path: Path,
    *,
    queries: Mapping[str, str],
    migration: str = "SELECT 1;\n",
    query_mappings: Sequence[QueryMapping] = (),
    custom_type_mappings: Sequence[CustomTypeMapping] = (),
    on_unsupported: str | None = None,
) -> Path:
    root = tmp_path / "pygen"
    _ = shutil.copytree(SRC_DIR, root / "src")
    project = root / "project"
    migrations = project / "migrations"
    query_dir = project / "queries"
    migrations.mkdir(parents=True)
    query_dir.mkdir()

    _ = (migrations / "1.sql").write_text(migration)
    for name, sql in queries.items():
        _ = (query_dir / name).write_text(sql)
    _ = (project / "project1.pgn.yaml").write_text(
        _project_yaml(
            query_mappings=query_mappings,
            custom_type_mappings=custom_type_mappings,
            on_unsupported=on_unsupported,
        )
    )
    return project


def _write_structural_scope_probe(project: Path, *, kind: str, duplicate_identity: bool) -> None:
    root = project.parent
    right_name = "leftName" if duplicate_identity else "rightName"
    definitions = {
        "composite": (
            "< Enum : List Model.EnumVariant | Composite : List Model.Member | Domain : Model.Value >"
            ".Composite [ valueMember ]"
        ),
        "enum": (
            "< Enum : List Model.EnumVariant | Composite : List Model.Member | Domain : Model.Value >"
            ".Enum [ readyVariant ]"
        ),
    }
    definition = definitions[kind]
    wrapper = f"""
let Model = ./Deps/Contract.dhall

let Sdk = ./Deps/Sdk.dhall

let OnUnsupported = ./Structures/OnUnsupported.dhall

let PythonNameMapping = ./Structures/PythonNameMapping.dhall

let Target = ./Interpreters/Project.dhall

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

let valueName
    : Model.Name
    = {{ inCamelCase = "value"
      , inPascalCase = "Value"
      , inKebabCase = "value"
      , inTrainCase = "Value"
      , inScreamingKebabCase = "VALUE"
      , inSnakeCase = "value"
      , inCamelSnakeCase = "Value"
      , inScreamingSnakeCase = "VALUE"
      }}

let leftName
    : Model.Name
    = valueName // {{ inCamelCase = "leftSource", inPascalCase = "LeftSource", inSnakeCase = "left_source" }}

let rightName
    : Model.Name
    = valueName // {{ inCamelCase = "rightSource", inPascalCase = "RightSource", inSnakeCase = "right_source" }}

let valueMember
    : Model.Member
    = {{ isNullable = False
      , name = valueName
      , pgName = "value"
      , value =
          {{ arraySettings = None Model.ArraySettings
          , scalar = Model.Scalar.Primitive Model.Primitive.Int8
          }}
      }}

let readyVariant
    : Model.EnumVariant
    = {{ name = valueName // {{ inScreamingSnakeCase = "READY" }}
      , pgName = "ready"
      }}

let leftType
    : Model.CustomType
    = {{ definition = {definition}
      , name = leftName
      , pgName = "c"
      , pgSchema = "a.b"
      }}

let rightType
    : Model.CustomType
    = {{ definition = {definition}
      , name = {right_name}
      , pgName = "b.c"
      , pgSchema = "a"
      }}

let targetConfig =
      {{ packageName = Some "mapping-client"
      , emitSync = Some False
      , onUnsupported = Some OnUnsupported.Mode.Fail
      , queryNameMappings = None (List PythonNameMapping.Query)
      , customTypeNameMappings =
          Some
            [ {{ source = {{ schema = "a.b", name = "c" }}
              , target = {{ snakeCase = "schema_dot_c", pascalCase = "SchemaDotC" }}
              }}
            , {{ source = {{ schema = "a", name = "b.c" }}
              , target = {{ snakeCase = "type_dot_c", pascalCase = "TypeDotC" }}
              }}
            ]
      }}

let run =
      \\(_ : Config) ->
      \\(input : Model.Project) ->
        Target.run
          targetConfig
          ( input
          // {{ customTypes = [ leftType, rightType ]
             , queries = [] : List Model.Query
             }}
          )

in  Sdk.Sigs.generator Config Config/default run
"""
    _ = (root / "src" / "structural-scope-probe.dhall").write_text(wrapper)
    project_file = project / "project1.pgn.yaml"
    _ = project_file.write_text(
        project_file.read_text().replace("../src/package.dhall", "../src/structural-scope-probe.dhall")
    )


def _analyse(pgn_bin: str, pgn_admin_url: str, project: Path) -> None:
    result = run_pgn(pgn_bin, pgn_admin_url, project, "analyse")
    assert result.returncode == 0, f"pgn analyse rejected the collision fixture:\n{result.stdout}\n{result.stderr}"


def _diagnostic(result: subprocess.CompletedProcess[str]) -> str:
    return f"{result.stdout}\n{result.stderr}"


def _assert_no_python_files(project: Path) -> None:
    artifact = project / "artifacts" / "python"
    assert not artifact.exists() or not any(artifact.rglob("*.py"))


def _assert_generation_fails(
    pgn_bin: str,
    pgn_admin_url: str,
    project: Path,
    expected: Iterable[str],
) -> None:
    result = run_pgn(pgn_bin, pgn_admin_url, project, "generate")
    diagnostic = _diagnostic(result)
    assert result.returncode != 0, f"pgn generate unexpectedly succeeded:\n{diagnostic}"
    for fragment in expected:
        assert fragment in diagnostic, f"missing {fragment!r} in pgn diagnostic:\n{diagnostic}"
    _assert_no_python_files(project)


def _package_dir(project: Path) -> Path:
    package = project / "artifacts" / "python" / "src" / "mapping_client"
    assert package.is_dir()
    return package


def _clear_package_modules() -> None:
    for name in list(sys.modules):
        if name == "mapping_client" or name.startswith("mapping_client."):
            del sys.modules[name]


def test_reserved_query_collision_fails_before_emission(
    pgn_bin: str,
    pgn_admin_url: str,
    tmp_path: Path,
) -> None:
    project = _fresh_project(
        tmp_path,
        queries={
            "sync.sql": "SELECT 1::int8 AS value\n",
            "sync_query.sql": "SELECT 2::int8 AS value\n",
        },
    )
    _analyse(pgn_bin, pgn_admin_url, project)
    _assert_generation_fails(
        pgn_bin,
        pgn_admin_url,
        project,
        [
            "Generated Python name collision in generated statement modules",
            'query "sync"',
            'query "sync_query"',
            'both resolve to "sync_query"',
        ],
    )


def test_json_value_custom_type_collision_fails_before_emission(
    pgn_bin: str,
    pgn_admin_url: str,
    tmp_path: Path,
) -> None:
    project = _fresh_project(
        tmp_path,
        migration="CREATE TYPE \"json_value\" AS ENUM ('ready');\n",
        queries={"read_json_value.sql": "SELECT 'ready'::public.\"json_value\" AS value\n"},
    )
    _analyse(pgn_bin, pgn_admin_url, project)
    _assert_generation_fails(
        pgn_bin,
        pgn_admin_url,
        project,
        [
            "Generated Python name collision in package facade",
            "generated core symbol JsonValue",
            'custom type "public.json_value"',
            'both resolve to "JsonValue"',
        ],
    )


def test_query_row_and_custom_type_collision_fails_before_emission(
    pgn_bin: str,
    pgn_admin_url: str,
    tmp_path: Path,
) -> None:
    project = _fresh_project(
        tmp_path,
        migration="CREATE TYPE foo_row AS ENUM ('ready');\n",
        queries={"foo.sql": "SELECT 'ready'::foo_row AS value\n"},
    )
    _analyse(pgn_bin, pgn_admin_url, project)
    _assert_generation_fails(
        pgn_bin,
        pgn_admin_url,
        project,
        [
            "Generated Python name collision in package facade",
            'Row class from query "foo"',
            'custom type "public.foo_row"',
            'both resolve to "FooRow"',
        ],
    )


@pytest.mark.parametrize(
    ("native_type", "native_value", "mapped_snake", "mapped_pascal", "on_unsupported"),
    [
        (
            "uuid",
            "'00000000-0000-0000-0000-000000000001'::uuid",
            "custom_uuid",
            "UUID",
            None,
        ),
        ("numeric", "1.25::numeric", "custom_decimal", "Decimal", None),
        (
            "uuid",
            "'00000000-0000-0000-0000-000000000001'::uuid",
            "custom_uuid",
            "UUID",
            "Skip",
        ),
    ],
    ids=["uuid-fail", "decimal-fail", "uuid-skip"],
)
def test_mapped_custom_dependency_cannot_shadow_composite_import(
    native_type: str,
    native_value: str,
    mapped_snake: str,
    mapped_pascal: str,
    on_unsupported: str | None,
    pgn_bin: str,
    pgn_admin_url: str,
    tmp_path: Path,
) -> None:
    project = _fresh_project(
        tmp_path,
        migration=(
            "CREATE TYPE import_dependency AS ENUM ('ready');\n"
            f"CREATE TYPE import_holder AS (native_value {native_type}, dependency import_dependency);\n"
        ),
        queries={
            "read_import_holder.sql": (
                f"SELECT ROW({native_value}, 'ready'::import_dependency)::import_holder AS value\n"
            )
        },
        custom_type_mappings=[("public", "import_dependency", mapped_snake, mapped_pascal)],
        on_unsupported=on_unsupported,
    )
    _analyse(pgn_bin, pgn_admin_url, project)
    _assert_generation_fails(
        pgn_bin,
        pgn_admin_url,
        project,
        [
            'Generated Python name collision in custom type module for schema "public", type "import_holder"',
            f"{mapped_pascal} primitive import",
            "custom dependency import",
            f'both resolve to "{mapped_pascal}"',
        ],
    )


@pytest.mark.parametrize("kind", ["composite", "enum"])
def test_custom_local_namespaces_keep_schema_and_name_structured(
    kind: str,
    pgn_bin: str,
    pgn_admin_url: str,
    tmp_path: Path,
) -> None:
    project = _fresh_project(tmp_path, queries={"seed.sql": "SELECT 1::int8 AS value\n"})
    _write_structural_scope_probe(project, kind=kind, duplicate_identity=False)
    _analyse(pgn_bin, pgn_admin_url, project)

    result = run_pgn(pgn_bin, pgn_admin_url, project, "generate")
    diagnostic = _diagnostic(result)
    assert result.returncode == 0, f"structured local namespace probe failed:\n{diagnostic}"

    package = _package_dir(project)
    left_source = (package / "_generated" / "types" / "schema_dot_c.py").read_text()
    right_source = (package / "_generated" / "types" / "type_dot_c.py").read_text()
    expected = (
        ("class SchemaDotC:", "class TypeDotC:", "value: int")
        if kind == "composite"
        else ("class SchemaDotC(StrEnum):", "class TypeDotC(StrEnum):", 'READY = "ready"')
    )
    assert expected[0] in left_source
    assert expected[1] in right_source
    assert expected[2] in left_source and expected[2] in right_source
    for source in package.rglob("*.py"):
        _ = ast.parse(source.read_text(), filename=str(source))


def test_duplicate_unqualified_custom_contract_identity_fails_loudly(
    pgn_bin: str,
    pgn_admin_url: str,
    tmp_path: Path,
) -> None:
    project = _fresh_project(tmp_path, queries={"seed.sql": "SELECT 1::int8 AS value\n"})
    _write_structural_scope_probe(project, kind="composite", duplicate_identity=True)
    _analyse(pgn_bin, pgn_admin_url, project)
    _assert_generation_fails(
        pgn_bin,
        pgn_admin_url,
        project,
        [
            'Ambiguous unqualified custom type identity "left_source"',
            'schema "a.b", type "c"',
            'schema "a", type "b.c"',
            "upstream contract must preserve a distinct schema-qualified custom identifier",
            "Python mappings cannot recover it",
        ],
    )


def test_typed_mappings_propagate_through_generated_package(
    pgn_bin: str,
    pgn_admin_url: str,
    tmp_path: Path,
) -> None:
    project = _fresh_project(
        tmp_path,
        migration=(
            "CREATE TYPE \"json_value\" AS ENUM ('ready');\n"
            "CREATE TYPE mapped_inner AS (value int8);\n"
            "CREATE TYPE mapped_outer AS (child mapped_inner);\n"
        ),
        queries={
            "sync.sql": "SELECT 1::int8 AS value\n",
            "sync_query.sql": "SELECT 2::int8 AS value\n",
            "read_json_value.sql": "SELECT 'ready'::public.\"json_value\" AS value\n",
            "read_mapped_outer.sql": ("SELECT ROW(ROW(7::int8)::mapped_inner)::mapped_outer AS value\n"),
        },
        query_mappings=[("sync_query", "api_v2", "ApiV2")],
        custom_type_mappings=[
            ("public", "json_value", "pg_json_value", "PgJsonValue"),
            ("public", "mapped_inner", "mapped_inner_v2", "MappedInnerV2"),
        ],
    )
    _analyse(pgn_bin, pgn_admin_url, project)
    result = run_pgn(pgn_bin, pgn_admin_url, project, "generate")
    diagnostic = _diagnostic(result)
    assert result.returncode == 0, f"mapped pgn generate failed:\n{diagnostic}"

    package = _package_dir(project)
    statements = package / "_generated" / "statements"
    assert {path.name for path in statements.glob("*.py")} == {
        "__init__.py",
        "api_v2.py",
        "read_json_value.py",
        "read_mapped_outer.py",
        "sync_query.py",
    }
    api_source = (statements / "api_v2.py").read_text()
    assert "class ApiV2Row:" in api_source
    assert "async def api_v2(" in api_source
    assert "def api_v2_sync(" in api_source

    type_source = (package / "_generated" / "types" / "pg_json_value.py").read_text()
    assert "class PgJsonValue(StrEnum):" in type_source
    inner_source = (package / "_generated" / "types" / "mapped_inner_v2.py").read_text()
    assert "class MappedInnerV2:" in inner_source
    outer_source = (package / "_generated" / "types" / "mapped_outer.py").read_text()
    assert "from .mapped_inner_v2 import MappedInnerV2" in outer_source
    assert "child: MappedInnerV2" in outer_source
    json_statement = (statements / "read_json_value.py").read_text()
    assert "value: _db_types.PgJsonValue" in json_statement
    register_source = (package / "_generated" / "_register.py").read_text()
    assert "_db_types.PgJsonValue" in register_source
    assert "_db_types.MappedInnerV2" in register_source
    assert register_source.index('"public.mapped_inner"') < register_source.index('"public.mapped_outer"')
    assert "public.json_value" in register_source

    facade_source = (package / "__init__.py").read_text()
    assert facade_source.index("statements.sync_query") < facade_source.index("statements.api_v2")
    assert facade_source.index("types.pg_json_value") < facade_source.index("types.mapped_inner_v2")
    assert facade_source.index('"PgJsonValue"') < facade_source.index('"MappedInnerV2"')
    types_init_source = (package / "_generated" / "types" / "__init__.py").read_text()
    assert types_init_source.index(".pg_json_value import") < types_init_source.index(".mapped_inner_v2 import")

    for source in package.rglob("*.py"):
        _ = ast.parse(source.read_text(), filename=str(source))

    ruff = subprocess.run(
        [
            "ruff",
            "check",
            "--config",
            str(SRC_DIR.parent / "pyproject.toml"),
            str(package),
        ],
        capture_output=True,
        text=True,
    )
    assert ruff.returncode == 0, f"mapped generated package failed Ruff:\n{ruff.stdout}\n{ruff.stderr}"

    generated_src = package.parent
    sys.path.insert(0, str(generated_src))
    _clear_package_modules()
    try:
        client = importlib.import_module("mapping_client")
        sync_client = importlib.import_module("mapping_client.sync")
        assert client.api_v2.__name__ == "api_v2"
        assert sync_client.api_v2.__name__ == "api_v2_sync"
        assert client.ApiV2Row is sync_client.ApiV2Row
        assert client.PgJsonValue is sync_client.PgJsonValue
        assert client.MappedInnerV2 is sync_client.MappedInnerV2
        assert client.MappedOuter is sync_client.MappedOuter
        assert client.JsonValue is not client.PgJsonValue
    finally:
        _clear_package_modules()
        sys.path.remove(str(generated_src))


@pytest.mark.parametrize(
    ("queries", "mappings", "expected"),
    [
        (
            {"alpha.sql": "SELECT 1::int8 AS value\n"},
            [("alpha", "api_v2", "ApiV2"), ("alpha", "other_api", "OtherApi")],
            ['Duplicate query name mapping source "alpha"'],
        ),
        (
            {"alpha.sql": "SELECT 1::int8 AS value\n"},
            [("missing", "api_v2", "ApiV2")],
            ['Unknown query name mapping source "missing"'],
        ),
        (
            {"alpha.sql": "SELECT 1::int8 AS value\n"},
            [("alpha", "2api", "ApiV2")],
            ["Mapped query snakeCase must start with a lowercase ASCII letter"],
        ),
        (
            {"alpha.sql": "SELECT 1::int8 AS value\n"},
            [("alpha", "api_v2", "2Api")],
            ["Mapped query pascalCase must start with an uppercase ASCII letter"],
        ),
        (
            {"alpha.sql": "SELECT 1::int8 AS value\n"},
            [("alpha", "api_v2", "apiV2")],
            ["Mapped query pascalCase must start with an uppercase ASCII letter"],
        ),
        (
            {"alpha.sql": "SELECT 1::int8 AS value\n"},
            [("alpha", "__init__", "Init")],
            ["Mapped query snakeCase must start with a lowercase ASCII letter"],
        ),
        (
            {"alpha.sql": "SELECT 1::int8 AS value\n"},
            [("alpha", "__all__", "All")],
            ["Mapped query snakeCase must start with a lowercase ASCII letter"],
        ),
        (
            {
                "alpha.sql": "SELECT 1::int8 AS value\n",
                "beta.sql": "SELECT 2::int8 AS value\n",
            },
            [("beta", "alpha", "BetaResult")],
            [
                "Generated Python name collision in generated statement modules",
                'query "alpha"',
                'query "beta"',
                'both resolve to "alpha"',
            ],
        ),
    ],
    ids=[
        "duplicate-source",
        "unknown-source",
        "leading-digit-snake",
        "leading-digit-pascal",
        "lowercase-pascal",
        "init-module",
        "all-facade",
        "mapped-final-collision",
    ],
)
def test_invalid_query_mappings_fail_before_emission(
    queries: Mapping[str, str],
    mappings: Sequence[QueryMapping],
    expected: Sequence[str],
    pgn_bin: str,
    pgn_admin_url: str,
    tmp_path: Path,
) -> None:
    project = _fresh_project(tmp_path, queries=queries, query_mappings=mappings)
    _analyse(pgn_bin, pgn_admin_url, project)
    _assert_generation_fails(pgn_bin, pgn_admin_url, project, expected)


@pytest.mark.parametrize(
    ("mappings", "expected"),
    [
        (
            [
                ("public", "json_value", "pg_json_value", "PgJsonValue"),
                ("public", "json_value", "other_json_value", "OtherJsonValue"),
            ],
            ['Duplicate custom type name mapping source "public.json_value"'],
        ),
        (
            [("public", "missing", "pg_missing", "PgMissing")],
            ['Unknown custom type name mapping source "public.missing"'],
        ),
        (
            [("public", "json_value", "pg_json_value", "NoRowError")],
            [
                "Generated Python name collision in package facade",
                "generated core symbol NoRowError",
                'custom type "public.json_value"',
                'both resolve to "NoRowError"',
            ],
        ),
        (
            [("public", "json_value", "pg_json_value", "JsonValue")],
            [
                "Generated Python name collision in package facade",
                "generated core symbol JsonValue",
                'custom type "public.json_value"',
                'both resolve to "JsonValue"',
            ],
        ),
        (
            [("public", "json_value", "pg_json_value", "pgJsonValue")],
            ["Mapped custom type pascalCase must start with an uppercase ASCII letter"],
        ),
        (
            [("public", "json_value", "__path__", "PgJsonValue")],
            ["Mapped custom type snakeCase must start with a lowercase ASCII letter"],
        ),
    ],
    ids=[
        "duplicate-source",
        "unknown-source",
        "mapped-final-collision",
        "mapped-json-value",
        "lowercase-pascal",
        "path-module",
    ],
)
def test_invalid_custom_type_mappings_fail_before_emission(
    mappings: Sequence[CustomTypeMapping],
    expected: Sequence[str],
    pgn_bin: str,
    pgn_admin_url: str,
    tmp_path: Path,
) -> None:
    project = _fresh_project(
        tmp_path,
        migration="CREATE TYPE \"json_value\" AS ENUM ('ready');\n",
        queries={"read_json_value.sql": "SELECT 'ready'::public.\"json_value\" AS value\n"},
        custom_type_mappings=mappings,
    )
    _analyse(pgn_bin, pgn_admin_url, project)
    _assert_generation_fails(pgn_bin, pgn_admin_url, project, expected)
