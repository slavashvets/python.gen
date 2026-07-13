# The generated client is imported dynamically, so its symbols are necessarily Any.
# pyright: reportAny=false
"""Collision coverage for public query names and statement implementation globals."""

from __future__ import annotations

import asyncio
import ast
import importlib
import json
import shutil
import subprocess
import sys
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import date
from pathlib import Path

import psycopg
from psycopg.conninfo import make_conninfo

from tests._harness import FIXTURE_PROJECT, HERE, SRC_DIR, ensure_droppable, run_pgn

HARNESS_ROOT = HERE.parent
EXPECTED_FUNCTIONS = frozenset({"cast", "require_array", "fetch_many", "date_query"})
HELPERS = {
    "cast": "fetch_single",
    "require_array": "fetch_single",
    "fetch_many": "fetch_many",
    "date_query": "fetch_single",
}


def _fresh_project(tmp_path: Path) -> tuple[Path, Path, str, str]:
    root = tmp_path / "pygen"
    _ = shutil.copytree(SRC_DIR, root / "src")
    project = shutil.copytree(FIXTURE_PROJECT, root / "tests" / "fixture-project")
    (project / "freeze1.pgn.yaml").unlink(missing_ok=True)
    shutil.rmtree(project / "artifacts", ignore_errors=True)
    shutil.rmtree(project / "queries")
    (project / "queries").mkdir()

    package_name = f"identifier-collisions-{uuid.uuid4().hex[:8]}"
    import_name = package_name.replace("-", "_")
    _ = (project / "project1.pgn.yaml").write_text(
        "space: python-gen\n"
        "name: identifier-collisions\n"
        "version: 0.0.0\n"
        "postgres: 18\n"
        "artifacts:\n"
        "  python:\n"
        "    gen: ../../src/package.dhall\n"
        "    config:\n"
        f"      packageName: {package_name}\n"
        "      emitSync: true\n"
    )

    queries = {
        "cast.sql": "SELECT 1::int8 AS value\n",
        "require_array.sql": "SELECT ARRAY['happy'::mood] AS moods\n",
        "fetch_many.sql": (
            "SELECT value\n"
            "FROM (VALUES (1::int8), (2::int8)) AS rows(value)\n"
            "ORDER BY value\n"
        ),
        "date.sql": "SELECT DATE '2026-07-13' AS value\n",
    }
    for name, sql in queries.items():
        _ = (project / "queries" / name).write_text(sql)

    return root, project, package_name, import_name


def _assert_private_query_canaries(
    root: Path, project: Path, pgn_bin: str, pgn_admin_url: str
) -> None:
    # pgn rejects leading-underscore query filenames before invoking a generator,
    # so exercise those policy inputs through a pgn-executed synthetic generator.
    wrapper = r'''
let Lude = ./Deps/Lude.dhall

let Model = ./Deps/Contract.dhall

let Sdk = ./Deps/Sdk.dhall

let PyIdent = ./Structures/PyIdent.dhall

let RegisterModule = ./Templates/RegisterModule.dhall

let Config = { packageName : Optional Text }

let Config/default = { packageName = None Text }

let run =
      \(_ : Config) ->
      \(_ : Model.Project) ->
        Lude.Compiled.ok
          Lude.Files.Type
              ( [ { path = "query-safe-name.txt"
              , content =
                      PyIdent.querySafeName "_db_types"
                  ++  "\n"
                  ++  PyIdent.querySafeName "_args_row"
                  ++  "\n"
                  ++  PyIdent.querySafeName "_fetch_many_sync"
                  ++  "\n"
                  ++  PyIdent.querySafeName "sync"
                  ++  "\n"
                  ++  PyIdent.querySafeName "register_types"
                  ++  "\n"
              }
                ]
          # [ { path = "composite-only-register.py"
              , content =
                  RegisterModule.run
                    { customTypes =
                      [ { typeName = "CompositeOnly"
                        , moduleName = "composite_only"
                        , pgSchema = "public"
                        , pgName = "composite_only"
                        , kind = RegisterModule.TypeKind.Composite
                        }
                      ]
                    , emitSync = True
                    }
              }
                ] : Lude.Files.Type
              )

in  Sdk.Sigs.generator Config Config/default run
'''
    _ = (root / "src" / "query-safe-name-probe.dhall").write_text(wrapper)

    canary = shutil.copytree(project, root / "tests" / "query-safe-name-project")
    shutil.rmtree(canary / "queries")
    (canary / "queries").mkdir()
    shutil.rmtree(canary / "artifacts", ignore_errors=True)
    _ = (canary / "project1.pgn.yaml").write_text(
        "space: python-gen\n"
        "name: query-safe-name-probe\n"
        "version: 0.0.0\n"
        "postgres: 18\n"
        "artifacts:\n"
        "  python:\n"
        "    gen: ../../src/query-safe-name-probe.dhall\n"
        "    config:\n"
        "      packageName: query-safe-name-probe\n"
    )

    result = run_pgn(pgn_bin, pgn_admin_url, canary, "generate")
    assert result.returncode == 0, f"query-name canary generation failed:\n{result.stdout}\n{result.stderr}"
    output = canary / "artifacts" / "python" / "query-safe-name.txt"
    assert output.read_text().splitlines() == [
        "_db_types_query",
        "_args_row_query",
        "_fetch_many_sync_query",
        "sync_query",
        "register_types_query",
    ]
    composite_register = (canary / "artifacts" / "python" / "composite-only-register.py").read_text()
    assert "CompositeInfo" in composite_register
    assert "register_composite" in composite_register
    assert "_dataclass_callbacks" in composite_register
    assert "EnumInfo" not in composite_register
    assert "register_enum" not in composite_register


@contextmanager
def _scratch_database(admin_url: str) -> Iterator[str]:
    name = f"pgn_collision_{uuid.uuid4().hex[:12]}"
    admin = psycopg.connect(admin_url, autocommit=True)
    try:
        _ = admin.execute(f'CREATE DATABASE "{name}"'.encode())
    finally:
        admin.close()

    target = make_conninfo(admin_url, dbname=name)
    try:
        yield target
    finally:
        admin = psycopg.connect(admin_url, autocommit=True)
        try:
            terminate = (
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                "WHERE datname = %s AND pid <> pg_backend_pid()"
            )
            _ = admin.execute(terminate.encode(), (name,))
            ensure_droppable(name)
            _ = admin.execute(f'DROP DATABASE IF EXISTS "{name}"'.encode())
        finally:
            admin.close()


def _apply_migrations(project: Path, db_url: str) -> None:
    migrations = sorted((project / "migrations").glob("*.sql"), key=lambda path: int(path.stem))
    with psycopg.connect(db_url, autocommit=True) as conn:
        for migration in migrations:
            _ = conn.execute(migration.read_text().encode())


def _clear_package_modules(import_name: str) -> None:
    for name in list(sys.modules):
        if name == import_name or name.startswith(f"{import_name}."):
            del sys.modules[name]


def _facade_statement_exports(facade: Path, *, level: int, function_suffix: str) -> dict[str, str]:
    exports: dict[str, str] = {}
    tree = ast.parse(facade.read_text())
    for node in tree.body:
        if not isinstance(node, ast.ImportFrom) or node.module is None:
            continue
        prefix = "_generated.statements."
        if node.level != level or not node.module.startswith(prefix):
            continue
        module_name = node.module.removeprefix(prefix)
        query_import = node.names[0]
        assert query_import.name == f"{module_name}{function_suffix}"
        assert query_import.asname == module_name
        exports[module_name] = query_import.asname
    return exports


def _assert_statement_structure(statements: Path) -> None:
    modules = {path.stem for path in statements.glob("*.py") if path.name != "__init__.py"}
    assert modules == EXPECTED_FUNCTIONS

    for function_name, helper in HELPERS.items():
        source = (statements / f"{function_name}.py").read_text()
        tree = ast.parse(source)
        async_runtime_imports = [
            node
            for node in tree.body
            if isinstance(node, ast.ImportFrom) and node.level == 2 and node.module == "_runtime"
        ]
        assert len(async_runtime_imports) == 1
        assert [(alias.name, alias.asname) for alias in async_runtime_imports[0].names] == [
            (helper, f"_{helper}")
        ]
        sync_runtime_imports = [
            node
            for node in tree.body
            if isinstance(node, ast.ImportFrom) and node.level == 2 and node.module == "sync._runtime"
        ]
        assert len(sync_runtime_imports) == 1
        assert [(alias.name, alias.asname) for alias in sync_runtime_imports[0].names] == [
            (helper, f"_{helper}_sync")
        ]
        assert f"from .._runtime import {helper} as _{helper}" in source
        assert f"from ..sync._runtime import {helper} as _{helper}_sync" in source
        row_classes = [node.name for node in tree.body if isinstance(node, ast.ClassDef)]
        assert len(row_classes) == 1
        row_name = row_classes[0]
        assert f"return await _{helper}(conn, SQL, params, _args_row({row_name}))" in source
        assert f"return _{helper}_sync(conn, SQL, params, _args_row({row_name}))" in source
        assert f"async def {function_name}(" in source
        assert f"def {function_name}_sync(" in source
        assert source.count("from psycopg.rows import args_row as _args_row") == 1
        assert "def decode_" not in source
        assert "_SQL" not in source
        assert "_decode_row" not in source
        assert "_cast" not in source
        assert "_require_array" not in source

    require_array_source = (statements / "require_array.py").read_text()
    assert require_array_source.count("from .. import types as _db_types") == 1
    assert "moods: list[_db_types.Mood | None] | None" in require_array_source
    assert "_args_row(RequireArrayRow)" in require_array_source
    assert "from datetime import date" in (statements / "date_query.py").read_text()


def _assert_strict(package_src: Path, tmp_path: Path) -> None:
    config = tmp_path / "identifier-collisions-pyright.json"
    _ = config.write_text(
        json.dumps(
            {
                "pythonVersion": "3.12",
                "typeCheckingMode": "strict",
                "include": [str(package_src)],
                "venvPath": str(HARNESS_ROOT),
                "venv": ".venv",
                "reportMissingModuleSource": False,
            }
        )
    )
    result = subprocess.run(
        ["basedpyright", "--project", str(config), "--outputjson"],
        capture_output=True,
        text=True,
    )
    assert result.stdout.strip(), f"basedpyright produced no JSON (exit {result.returncode}):\n{result.stderr}"
    summary = json.loads(result.stdout)["summary"]
    assert summary["filesAnalyzed"] > 0, f"basedpyright analyzed no files:\n{result.stdout}"
    assert summary["errorCount"] == 0 and summary["warningCount"] == 0, (
        f"basedpyright strict reported issues: {summary}\n{result.stdout}"
    )


def test_identifier_collisions_roundtrip(
    pgn_bin: str, pgn_admin_url: str, tmp_path: Path
) -> None:
    root, project, package_name, import_name = _fresh_project(tmp_path)
    _assert_private_query_canaries(root, project, pgn_bin, pgn_admin_url)
    result = run_pgn(pgn_bin, pgn_admin_url, project, "generate")
    assert result.returncode == 0, f"pgn generate failed:\n{result.stdout}\n{result.stderr}"

    generated_src = project / "artifacts" / "python" / "src"
    package_src = generated_src / import_name
    statements = package_src / "_generated" / "statements"
    assert package_src.is_dir(), f"pgn did not generate package {package_name!r}"
    _assert_statement_structure(statements)
    facade_exports = _facade_statement_exports(
        package_src / "__init__.py", level=1, function_suffix=""
    )
    sync_exports = _facade_statement_exports(
        package_src / "sync" / "__init__.py", level=2, function_suffix="_sync"
    )
    expected_exports = {name: name for name in EXPECTED_FUNCTIONS}
    assert facade_exports == expected_exports
    assert sync_exports == expected_exports
    assert not (statements / "date.py").exists()
    assert not (statements / "_types.py").exists()
    assert not (package_src / "_generated" / "sync" / "statements").exists()
    assert not (package_src / "_generated" / "sync" / "_register.py").exists()
    register_source = (package_src / "_generated" / "_register.py").read_text()
    assert "EnumInfo" in register_source
    assert "register_enum" in register_source
    assert "CompositeInfo" not in register_source
    assert "register_composite" not in register_source
    assert "_dataclass_callbacks" not in register_source
    _assert_strict(package_src, tmp_path)

    sys.path.insert(0, str(generated_src))
    _clear_package_modules(import_name)
    try:
        facade = importlib.import_module(import_name)
        sync_facade = importlib.import_module(f"{import_name}.sync")
        Mood = facade.Mood

        with _scratch_database(pgn_admin_url) as db_url:
            _apply_migrations(project, db_url)

            async def scenario() -> None:
                conn = await psycopg.AsyncConnection.connect(db_url, autocommit=True)
                try:
                    await facade.register_types(conn)
                    cast_row = await facade.cast(conn)
                    require_array_row = await facade.require_array(conn)
                    many_rows = await facade.fetch_many(conn)
                    date_row = await facade.date_query(conn)

                    assert cast_row.value == 1
                    assert require_array_row.moods == [Mood.HAPPY]
                    assert require_array_row.moods[0] is Mood.HAPPY
                    assert [row.value for row in many_rows] == [1, 2]
                    assert date_row.value == date(2026, 7, 13)
                finally:
                    await conn.close()

            asyncio.run(scenario())

            with psycopg.connect(db_url, autocommit=True) as conn:
                sync_facade.register_types(conn)
                cast_row = sync_facade.cast(conn)
                require_array_row = sync_facade.require_array(conn)
                many_rows = sync_facade.fetch_many(conn)
                date_row = sync_facade.date_query(conn)

                assert cast_row.value == 1
                assert require_array_row.moods == [Mood.HAPPY]
                assert require_array_row.moods[0] is Mood.HAPPY
                assert [row.value for row in many_rows] == [1, 2]
                assert date_row.value == date(2026, 7, 13)
    finally:
        _clear_package_modules(import_name)
        sys.path.remove(str(generated_src))
