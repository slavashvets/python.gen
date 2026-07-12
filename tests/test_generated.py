# The generated client is imported dynamically (it does not exist at type-check
# time), so its symbols are necessarily Any; silence reportAny for this module.
# pyright: reportAny=false
"""Harness for the pGenie Python generator.

End to end: validate the fixture pgn project (`pgn analyse`), generate the Python
client (`pgn generate`), diff it against the committed golden tree, typecheck the
generated package with basedpyright strict, and round-trip every generated
statement function against a throwaway database on the local pg0 instance.
"""

from __future__ import annotations

import asyncio
import importlib
import inspect
import json
import subprocess
import sys
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from decimal import Decimal
from datetime import date
from pathlib import Path

import psycopg
import pytest
from psycopg.conninfo import make_conninfo

from tests._harness import FIXTURE_PROJECT, GOLDEN_DIR, HERE, ensure_droppable, run_pgn

HARNESS_ROOT = HERE.parent

# The generator emits the <pkg>/_generated subtree plus the package-root
# __init__.py facade; the rest of the shell (pyproject.toml, py.typed) is
# hand-written and lives in golden as a committed fixture, not produced by
# generate.
GENERATED_PACKAGE = Path("src/specimen_client")
QUERY_NAMES = (
    "bump_specimen_revision",
    "get_specimen",
    "get_tagged_item",
    "insert_specimen",
    "insert_tagged_item",
    "list_specimens_by_class",
    "list_specimens_by_feeling",
    "list_specimens_by_ids",
    "list_specimens_by_moods",
    "list_specimens_keyword_column",
    "search_specimens",
)
ROW_NAMES = {
    name: "".join(part.title() for part in name.split("_")) + "Row"
    for name in QUERY_NAMES
    if name != "bump_specimen_revision"
}


def test_fixture_project_analyses_clean(pgn_bin: str, pgn_admin_url: str, fixture_copy: Path) -> None:
    """pgn analyse must accept the fixture project (exit 0).

    pgn spins up its own temp database from the admin URL, applies the
    migrations, prepares every query, then drops that DB. A non-zero exit means
    the fixture drifted away from what the pinned pgn accepts.
    """
    result = run_pgn(pgn_bin, pgn_admin_url, fixture_copy, "analyse")
    assert result.returncode == 0, f"pgn analyse failed:\n{result.stdout}\n{result.stderr}"


def test_committed_sig_files_match_fresh_analysis(pgn_bin: str, pgn_admin_url: str, fixture_copy: Path) -> None:
    """The committed *.sig1.pgn.yaml files are the pinned contract.

    Re-running analyse on a clean copy must reproduce them byte for byte; a diff
    means the schema or queries changed without refreshing the signatures.
    """
    for sig in fixture_copy.rglob("*.sig1.pgn.yaml"):
        sig.unlink()

    result = run_pgn(pgn_bin, pgn_admin_url, fixture_copy, "analyse")
    assert result.returncode == 0, f"pgn analyse failed:\n{result.stdout}\n{result.stderr}"

    committed = sorted(p.relative_to(FIXTURE_PROJECT) for p in FIXTURE_PROJECT.rglob("*.sig1.pgn.yaml"))
    regenerated = sorted(p.relative_to(fixture_copy) for p in fixture_copy.rglob("*.sig1.pgn.yaml"))
    assert committed == regenerated, "set of signature files changed; refresh committed sigs"

    for rel in committed:
        expected = (FIXTURE_PROJECT / rel).read_text()
        actual = (fixture_copy / rel).read_text()
        assert actual == expected, f"signature drift in {rel}; re-run pgn analyse in fixture-project"


def test_generate_produces_python_package(generated_tree: Path) -> None:
    assert generated_tree.is_dir()
    assert list(generated_tree.rglob("*.py")), "generator produced no Python modules"


def _relative_files(root: Path, *, exclude: frozenset[Path] = frozenset()) -> set[Path]:
    # Skip bytecode: the generator never emits it, but a local `import specimen_client`
    # leaves __pycache__ under golden and would false-fail the file-set comparison.
    return {
        p.relative_to(root)
        for p in root.rglob("*")
        if p.is_file() and "__pycache__" not in p.parts and p.relative_to(root) not in exclude
    }


def test_generated_matches_golden(generated_tree: Path) -> None:
    """Every generated package file must equal golden byte for byte.

    Generate produces the <pkg>/_generated subtree plus the root and sync
    facades; the rest of the shell in golden is a hand-written
    committed fixture and stays out of this comparison. Update flow when the
    generator legitimately changes: re-run `pgn generate` in tests/fixture-project
    and copy the fresh _generated subtree plus both facades into golden (see
    tests/golden/README.md), then review the diff.
    """
    produced_root = generated_tree / GENERATED_PACKAGE
    golden_root = GOLDEN_DIR / GENERATED_PACKAGE

    produced = _relative_files(produced_root)
    golden = _relative_files(golden_root, exclude=frozenset({Path("py.typed")}))

    missing = sorted(str(p) for p in golden - produced)
    extra = sorted(str(p) for p in produced - golden)
    assert not missing, f"golden files not produced by the generator: {missing}"
    assert not extra, f"generator emitted files absent from golden: {extra}"

    mismatched: list[str] = []
    for rel in sorted(produced, key=str):
        if (produced_root / rel).read_text() != (golden_root / rel).read_text():
            mismatched.append(str(rel))

    assert not mismatched, (
        "generated output drifted from golden in: "
        + ", ".join(mismatched)
        + "\nupdate via: mise run golden (see tests/golden/README.md)"
    )


def test_generated_passes_basedpyright_strict(full_package: Path, tmp_path: Path) -> None:
    """basedpyright strict on the fresh full package: zero errors and warnings.

    The full_package fixture overlays the fresh generated tree and both facades
    onto the hand-written shell. psycopg resolves from the harness venv. The
    config scopes the run to that package's `src` so harness tests stay excluded.
    """
    config = tmp_path / "pyrightconfig.json"
    _ = config.write_text(
        json.dumps(
            {
                "pythonVersion": "3.12",
                "typeCheckingMode": "strict",
                "include": [str(full_package / "src")],
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

    # A tool-level failure (bad flag, crash) writes nothing to stdout and exits
    # non-zero; surface stderr instead of an opaque JSONDecodeError.
    if not result.stdout.strip():
        pytest.fail(f"basedpyright produced no JSON (exit {result.returncode}):\n{result.stderr}")

    summary = json.loads(result.stdout)["summary"]
    # basedpyright exits 0 with filesAnalyzed=0 when the include path matches nothing,
    # so without this the strict gate would pass vacuously if the package src moved.
    assert summary["filesAnalyzed"] > 0, f"basedpyright analyzed no files; bad include path?\n{result.stdout}"
    assert summary["errorCount"] == 0 and summary["warningCount"] == 0, (
        f"basedpyright strict reported issues: {summary}\n{result.stdout}"
    )


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
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                "WHERE datname = %s AND pid <> pg_backend_pid()"
            )
            _ = admin.execute(terminate.encode(), (name,))
            ensure_droppable(name)
            _ = admin.execute(f'DROP DATABASE IF EXISTS "{name}"'.encode())
        finally:
            admin.close()


def _apply_migrations(db_url: str) -> None:
    migrations = sorted((FIXTURE_PROJECT / "migrations").glob("*.sql"), key=lambda p: int(p.stem))
    with psycopg.connect(db_url, autocommit=True) as conn:
        for migration in migrations:
            _ = conn.execute(migration.read_text().encode())


def _clear_client_modules() -> None:
    for name in list(sys.modules):
        if name == "specimen_client" or name.startswith("specimen_client."):
            del sys.modules[name]


@contextmanager
def _client_modules(full_package: Path):  # noqa: ANN202 - dynamic module set
    src = str(full_package / "src")
    original_path = sys.path.copy()
    sys.path.insert(0, src)
    _clear_client_modules()
    try:
        root = importlib.import_module("specimen_client")
        sync = importlib.import_module("specimen_client.sync")
        yield root, sync, importlib.import_module
    finally:
        _clear_client_modules()
        sys.path[:] = original_path


@pytest.fixture
def client_modules(full_package: Path):  # noqa: ANN202 - dynamic module set
    with _client_modules(full_package) as loaded:
        yield loaded


def test_combined_public_api_identity_and_signatures(full_package: Path) -> None:
    with _client_modules(full_package) as (root, sync, import_module):
        assert root.sync is sync

        for name in QUERY_NAMES:
            statement = import_module(f"specimen_client._generated.statements.{name}")
            async_function = getattr(root, name)
            sync_function = getattr(sync, name)
            assert async_function is getattr(statement, name)
            assert sync_function is getattr(statement, f"{name}_sync")
            assert inspect.iscoroutinefunction(async_function)
            assert not inspect.iscoroutinefunction(sync_function)

            async_signature = inspect.signature(async_function)
            sync_signature = inspect.signature(sync_function)
            assert async_signature.return_annotation == sync_signature.return_annotation
            async_params = list(async_signature.parameters.values())
            sync_params = list(sync_signature.parameters.values())
            assert len(async_params) == len(sync_params)
            for index, (async_param, sync_param) in enumerate(zip(async_params, sync_params, strict=True)):
                assert async_param.name == sync_param.name
                assert async_param.kind == sync_param.kind
                assert async_param.default == sync_param.default
                if index == 0:
                    assert async_param.annotation == "AsyncConnection[object]"
                    assert sync_param.annotation == "Connection[object]"
                else:
                    assert async_param.annotation == sync_param.annotation

            row_name = ROW_NAMES.get(name)
            if row_name is not None:
                row_class = getattr(statement, row_name)
                assert getattr(root, row_name) is row_class
                assert getattr(sync, row_name) is row_class

        for name in ("Mood", "Point2D", "TagValue", "JsonValue", "NoRowError"):
            assert getattr(root, name) is getattr(sync, name)

        register = import_module("specimen_client._generated._register")
        assert root.register_types is register.register_types
        assert sync.register_types is register.register_types_sync
        assert "register_types" in root.__all__
        assert "register_types" in sync.__all__


def test_roundtrip_type_mappings(client_modules, roundtrip_db: str) -> None:  # noqa: ANN001
    """INSERT then SELECT through the generated client, asserting the mappings.

    Exercises every generated statement and the full type surface: enum param +
    enum column decoding to the generated StrEnum, composite param encode +
    column decode to the frozen dataclass, array param via ANY, jsonb param and
    column round-trip, the literal-`%` query, nullable columns as None, and the
    rows-affected helper. Runs against a throwaway pg0 database.
    """
    _apply_migrations(roundtrip_db)
    facade, _, _ = client_modules
    Mood = facade.Mood
    Point2D = facade.Point2D

    async def scenario() -> None:
        conn = await psycopg.AsyncConnection.connect(roundtrip_db, autocommit=True)
        try:
            await facade.register_types(conn)

            inserted = await facade.insert_specimen(
                conn,
                doc_jsonb={"k": "v", "n": 1},
                feeling=Mood.HAPPY,
                origin=Point2D(x=1.5, y=2.5),
                flag=True,
                small=1,
                medium=2,
                large=3,
                ratio=0.5,
                precise=0.25,
                title="alpha",
                code="C-1",
                letter="x",
                born_on=date(2020, 1, 2),
                amount=Decimal("12.34"),
                blob=b"\x00\x01",
                doc_json=[1, 2, 3],
                maybe_text=None,
                maybe_int=None,
                maybe_uuid=None,
                maybe_ts=None,
                maybe_num=None,
                tags=["a", None, "b"],
                related_ids=None,
                grid=None,
                moods=[Mood.HAPPY, None, Mood.SAD],
            )
            assert type(inserted) is facade.InsertSpecimenRow

            # enum column decodes to the generated StrEnum (identity, not just ==).
            assert isinstance(inserted.feeling, Mood)
            assert inserted.feeling is Mood.HAPPY
            # composite column decodes to the frozen dataclass.
            assert isinstance(inserted.origin, Point2D)
            assert inserted.origin == Point2D(x=1.5, y=2.5)
            # jsonb / json columns round-trip the parsed Python objects.
            assert inserted.doc_jsonb == {"k": "v", "n": 1}
            assert inserted.doc_json == [1, 2, 3]
            # arrays become lists; nullable columns come back as None.
            assert inserted.tags == ["a", None, "b"]
            assert inserted.related_ids is None
            assert inserted.maybe_text is None
            # enum array decodes element-wise to the generated StrEnum, with a
            # null element preserved as None (identity, not just ==).
            assert inserted.moods == [Mood.HAPPY, None, Mood.SAD]
            assert inserted.moods is not None
            assert inserted.moods[0] is Mood.HAPPY
            assert inserted.moods[2] is Mood.SAD
            # domain-backed columns map to their base Python types.
            assert inserted.label == "specimen"
            assert inserted.rev == 1
            assert inserted.meta == {}
            assert isinstance(inserted.amount, Decimal)

            specimen_id = inserted.id

            # Optional: hit returns the row, miss returns None.
            hit = await facade.get_specimen(conn, id=specimen_id)
            assert hit is not None
            assert hit.id == specimen_id
            assert isinstance(hit.feeling, Mood)
            assert isinstance(hit.origin, Point2D)
            assert hit.maybe_uuid is None
            miss = await facade.get_specimen(conn, id=specimen_id + 10_000)
            assert miss is None

            # Multiple with enum param + enum/composite column decode.
            feeling_rows = await facade.list_specimens_by_feeling(conn, feeling=Mood.HAPPY)
            assert len(feeling_rows) == 1
            assert feeling_rows[0].feeling is Mood.HAPPY
            assert isinstance(feeling_rows[0].origin, Point2D)
            assert await facade.list_specimens_by_feeling(conn, feeling=Mood.SAD) == []

            # Array param via ANY. This exercises the nullable-element branch
            # (list[T | None] | None). NOTE: the generator's non-null-element
            # branch (list[T]) is not covered by this fixture because the
            # single-table specimen schema produces no query shape under which pgn
            # infers element_not_null:true (= ANY and unnest forms against
            # specimen all yield false), and test_committed_sig_files_match_fresh_analysis
            # pins every fixture sig to fresh analysis, so a true flag cannot be
            # committed here. The branch ships in the real client
            # (documents_have_unpublished_changes, whose unnest-over-FK-join shape
            # does infer it) and is guarded by checks:pgn-generate plus call-site
            # type-checking in apps/backend and apps/ingest, which pass list[UUID].
            # The generated client bodies are not strict-typechecked themselves.
            id_rows = await facade.list_specimens_by_ids(conn, pub_ids=[inserted.pub_id])
            assert [r.pub_id for r in id_rows] == [inserted.pub_id]
            assert await facade.list_specimens_by_ids(conn, pub_ids=[uuid.uuid4()]) == []

            # Enum array param via ANY + enum array column decoded element-wise.
            mood_rows = await facade.list_specimens_by_moods(conn, moods=[Mood.HAPPY])
            assert [r.id for r in mood_rows] == [specimen_id]
            assert mood_rows[0].moods == [Mood.HAPPY, None, Mood.SAD]
            assert mood_rows[0].moods is not None
            assert mood_rows[0].moods[0] is Mood.HAPPY
            assert await facade.list_specimens_by_moods(conn, moods=[Mood.SAD]) == []

            # Keyword-named param: class_ binds as %(class)s, so it must match by title.
            class_rows = await facade.list_specimens_by_class(conn, class_="alpha")
            assert [r.id for r in class_rows] == [specimen_id]
            assert await facade.list_specimens_by_class(conn, class_="nope") == []

            # Keyword-named result column: title AS "class" decodes to .class_.
            kw_rows = await facade.list_specimens_keyword_column(conn)
            assert [r.id for r in kw_rows] == [specimen_id]
            assert kw_rows[0].class_ == "alpha"

            # jsonb containment param + the literal-`%` ILIKE branch (title_like=None).
            search_all = await facade.search_specimens(conn, title_like=None, meta_filter={}, label=None)
            assert [r.id for r in search_all] == [specimen_id]
            search_hit = await facade.search_specimens(
                conn, title_like="alp%", meta_filter={}, label="specimen"
            )
            assert [r.id for r in search_hit] == [specimen_id]
            assert isinstance(search_hit[0].meta, dict)

            # RowsAffected helper returns the count.
            affected = await facade.bump_specimen_revision(conn, id=specimen_id)
            assert affected == 1
            bumped = await facade.get_specimen(conn, id=specimen_id)
            assert bumped is not None
            assert bumped.rev == 2
        finally:
            await conn.close()

    asyncio.run(scenario())


def test_require_array_rejects_unregistered_enum_array(client_modules) -> None:  # noqa: ANN001
    """require_array turns the unregistered enum-array form into a clear error.

    Without register_types psycopg returns an enum array as the raw array text, not
    a list; the generated enum-array decode wraps the value in require_array so it
    fails loudly instead of iterating a string into bogus members.
    """
    _, _, import_module = client_modules
    runtime = import_module("specimen_client._generated._runtime")

    assert runtime.require_array(["happy", "sad"]) == ["happy", "sad"]
    with pytest.raises(RuntimeError, match="register_types"):
        _ = runtime.require_array("{happy,sad}")


def test_roundtrip_sync_surface(client_modules, roundtrip_db: str) -> None:  # noqa: ANN001
    """Drive the additive sync public facade end to end."""
    _apply_migrations(roundtrip_db)
    _, facade, _ = client_modules
    Mood = facade.Mood
    Point2D = facade.Point2D

    conn = psycopg.connect(roundtrip_db, autocommit=True)
    try:
        facade.register_types(conn)

        inserted = facade.insert_specimen(
            conn,
            doc_jsonb={"k": "v", "n": 1},
            feeling=Mood.HAPPY,
            origin=Point2D(x=1.5, y=2.5),
            flag=True,
            small=1,
            medium=2,
            large=3,
            ratio=0.5,
            precise=0.25,
            title="alpha",
            code="C-1",
            letter="x",
            born_on=date(2020, 1, 2),
            amount=Decimal("12.34"),
            blob=b"\x00\x01",
            doc_json=[1, 2, 3],
            maybe_text=None,
            maybe_int=None,
            maybe_uuid=None,
            maybe_ts=None,
            maybe_num=None,
            tags=["a", None, "b"],
            related_ids=None,
            grid=None,
            moods=[Mood.HAPPY, None, Mood.SAD],
        )
        assert type(inserted) is facade.InsertSpecimenRow
        assert isinstance(inserted.feeling, Mood)
        assert inserted.feeling is Mood.HAPPY
        assert isinstance(inserted.origin, Point2D)
        assert inserted.doc_jsonb == {"k": "v", "n": 1}
        assert inserted.moods == [Mood.HAPPY, None, Mood.SAD]
        assert inserted.moods is not None
        assert inserted.moods[0] is Mood.HAPPY

        specimen_id = inserted.id
        hit = facade.get_specimen(conn, id=specimen_id)
        assert hit is not None
        assert hit.id == specimen_id
        assert facade.get_specimen(conn, id=specimen_id + 10_000) is None

        mood_rows = facade.list_specimens_by_moods(conn, moods=[Mood.HAPPY])
        assert [r.id for r in mood_rows] == [specimen_id]
        assert facade.list_specimens_by_moods(conn, moods=[Mood.SAD]) == []

        affected = facade.bump_specimen_revision(conn, id=specimen_id)
        assert affected == 1
        bumped = facade.get_specimen(conn, id=specimen_id)
        assert bumped is not None
        assert bumped.rev == 2
    finally:
        conn.close()


def test_roundtrip_single_field_composite(client_modules, roundtrip_db: str) -> None:  # noqa: ANN001
    """Regression test for compositeBind on a one-field composite.

    concatMapSep joins a single-element field list with no separator, so an
    unguarded tuple expression would render "(x.f)": a parenthesized value, not
    a tuple, which psycopg would try to adapt as the bare field type instead of
    the composite. Exercises the param bind (insert) and the result-column
    decode (RETURNING and a plain SELECT).
    """
    _apply_migrations(roundtrip_db)
    facade, _, _ = client_modules
    TagValue = facade.TagValue

    async def scenario() -> None:
        conn = await psycopg.AsyncConnection.connect(roundtrip_db, autocommit=True)
        try:
            await facade.register_types(conn)

            inserted = await facade.insert_tagged_item(conn, name="widget", tag=TagValue(value="blue"))
            assert type(inserted) is facade.InsertTaggedItemRow
            assert isinstance(inserted.tag, TagValue)
            assert inserted.tag == TagValue(value="blue")

            hit = await facade.get_tagged_item(conn, id=inserted.id)
            assert hit is not None
            assert isinstance(hit.tag, TagValue)
            assert hit.tag == TagValue(value="blue")
            assert await facade.get_tagged_item(conn, id=inserted.id + 10_000) is None
        finally:
            await conn.close()

    asyncio.run(scenario())


def test_roundtrip_single_field_composite_sync(client_modules, roundtrip_db: str) -> None:  # noqa: ANN001
    """Sync public-facade counterpart of the one-field composite regression."""
    _apply_migrations(roundtrip_db)
    _, facade, _ = client_modules
    TagValue = facade.TagValue

    conn = psycopg.connect(roundtrip_db, autocommit=True)
    try:
        facade.register_types(conn)

        inserted = facade.insert_tagged_item(conn, name="widget", tag=TagValue(value="blue"))
        assert type(inserted) is facade.InsertTaggedItemRow
        assert isinstance(inserted.tag, TagValue)
        assert inserted.tag == TagValue(value="blue")

        hit = facade.get_tagged_item(conn, id=inserted.id)
        assert hit is not None
        assert hit.tag == TagValue(value="blue")
    finally:
        conn.close()
