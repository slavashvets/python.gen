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
import json
import subprocess
import sys
import uuid
from collections.abc import Iterator
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
GENERATED_SUBTREE = Path("src/specimen_client/_generated")
FACADE_INIT = Path("src/specimen_client/__init__.py")
SYNC_FACADE_INIT = Path("src/specimen_client/sync/__init__.py")


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


def _relative_files(root: Path) -> set[Path]:
    # Skip bytecode: the generator never emits it, but a local `import specimen_client`
    # leaves __pycache__ under golden and would false-fail the file-set comparison.
    return {
        p.relative_to(root)
        for p in root.rglob("*")
        if p.is_file() and "__pycache__" not in p.parts
    }


def test_generated_matches_golden(generated_tree: Path) -> None:
    """The generated subtree and the facade must equal golden's byte for byte.

    Generate produces the <pkg>/_generated subtree and the package-root
    __init__.py facade; the rest of the shell in golden is a hand-written
    committed fixture and stays out of this comparison. Update flow when the
    generator legitimately changes: re-run `pgn generate` in tests/fixture-project
    and rsync the fresh _generated subtree plus the facade into golden (see
    tests/golden/README.md), then review the diff.
    """
    produced_root = generated_tree / GENERATED_SUBTREE
    golden_root = GOLDEN_DIR / GENERATED_SUBTREE

    produced = _relative_files(produced_root)
    golden = _relative_files(golden_root)

    missing = sorted(str(p) for p in golden - produced)
    extra = sorted(str(p) for p in produced - golden)
    assert not missing, f"golden files not produced by the generator: {missing}"
    assert not extra, f"generator emitted files absent from golden: {extra}"

    mismatched: list[str] = []
    for rel in sorted(produced, key=str):
        if (produced_root / rel).read_text() != (golden_root / rel).read_text():
            mismatched.append(str(rel))

    for facade in (FACADE_INIT, SYNC_FACADE_INIT):
        if (generated_tree / facade).read_text() != (GOLDEN_DIR / facade).read_text():
            mismatched.append(str(facade))

    assert not mismatched, (
        "generated output drifted from golden in: "
        + ", ".join(mismatched)
        + "\nupdate via: rsync the fresh _generated subtree and the facade into golden (see tests/golden/README.md)"
    )


def test_generated_passes_basedpyright_strict(tmp_path: Path) -> None:
    """basedpyright strict on the FULL golden package: zero errors and warnings.

    The golden package (hand-written shell + the generated _generated subtree)
    is the committed contract; test_generated_matches_golden proves the fresh
    output equals golden's _generated subtree, so checking golden checks the
    generator's output. psycopg resolves from the harness venv. The config scopes
    the run to golden's `src` so the harness tests are not pulled in.
    """
    config = tmp_path / "pyrightconfig.json"
    _ = config.write_text(
        json.dumps(
            {
                "pythonVersion": "3.12",
                "typeCheckingMode": "strict",
                "include": [str(GOLDEN_DIR / "src")],
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
    # so without this the strict gate would pass vacuously if the golden src ever moved.
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


def _import_client(full_package: Path):  # noqa: ANN202 - dynamic module set
    src = str(full_package / "src")
    if src not in sys.path:
        sys.path.insert(0, src)
    for name in list(sys.modules):
        if name == "specimen_client" or name.startswith("specimen_client."):
            del sys.modules[name]
    return importlib.import_module


def test_roundtrip_type_mappings(full_package: Path, roundtrip_db: str) -> None:
    """INSERT then SELECT through the generated client, asserting the mappings.

    Exercises every generated statement and the full type surface: enum param +
    enum column decoding to the generated StrEnum, composite param encode +
    column decode to the frozen dataclass, array param via ANY, jsonb param and
    column round-trip, the literal-`%` query, nullable columns as None, and the
    rows-affected helper. Runs against a throwaway pg0 database.
    """
    _apply_migrations(roundtrip_db)
    import_module = _import_client(full_package)

    register = import_module("specimen_client._generated._register")
    mood_mod = import_module("specimen_client._generated.types.mood")
    point_mod = import_module("specimen_client._generated.types.point_2_d")
    insert = import_module("specimen_client._generated.statements.insert_specimen")
    get = import_module("specimen_client._generated.statements.get_specimen")
    by_feeling = import_module("specimen_client._generated.statements.list_specimens_by_feeling")
    by_ids = import_module("specimen_client._generated.statements.list_specimens_by_ids")
    by_moods = import_module("specimen_client._generated.statements.list_specimens_by_moods")
    by_class = import_module("specimen_client._generated.statements.list_specimens_by_class")
    by_kw_col = import_module("specimen_client._generated.statements.list_specimens_keyword_column")
    search = import_module("specimen_client._generated.statements.search_specimens")
    bump = import_module("specimen_client._generated.statements.bump_specimen_revision")

    Mood = mood_mod.Mood
    Point2D = point_mod.Point2D

    async def scenario() -> None:
        conn = await psycopg.AsyncConnection.connect(roundtrip_db, autocommit=True)
        try:
            await register.register_types(conn)

            inserted = await insert.insert_specimen(
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
            hit = await get.get_specimen(conn, id=specimen_id)
            assert hit is not None
            assert hit.id == specimen_id
            assert isinstance(hit.feeling, Mood)
            assert isinstance(hit.origin, Point2D)
            assert hit.maybe_uuid is None
            miss = await get.get_specimen(conn, id=specimen_id + 10_000)
            assert miss is None

            # Multiple with enum param + enum/composite column decode.
            feeling_rows = await by_feeling.list_specimens_by_feeling(conn, feeling=Mood.HAPPY)
            assert len(feeling_rows) == 1
            assert feeling_rows[0].feeling is Mood.HAPPY
            assert isinstance(feeling_rows[0].origin, Point2D)
            assert await by_feeling.list_specimens_by_feeling(conn, feeling=Mood.SAD) == []

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
            id_rows = await by_ids.list_specimens_by_ids(conn, pub_ids=[inserted.pub_id])
            assert [r.pub_id for r in id_rows] == [inserted.pub_id]
            assert await by_ids.list_specimens_by_ids(conn, pub_ids=[uuid.uuid4()]) == []

            # Enum array param via ANY + enum array column decoded element-wise.
            mood_rows = await by_moods.list_specimens_by_moods(conn, moods=[Mood.HAPPY])
            assert [r.id for r in mood_rows] == [specimen_id]
            assert mood_rows[0].moods == [Mood.HAPPY, None, Mood.SAD]
            assert mood_rows[0].moods is not None
            assert mood_rows[0].moods[0] is Mood.HAPPY
            assert await by_moods.list_specimens_by_moods(conn, moods=[Mood.SAD]) == []

            # Keyword-named param: class_ binds as %(class)s, so it must match by title.
            class_rows = await by_class.list_specimens_by_class(conn, class_="alpha")
            assert [r.id for r in class_rows] == [specimen_id]
            assert await by_class.list_specimens_by_class(conn, class_="nope") == []

            # Keyword-named result column: title AS "class" decodes to .class_.
            kw_rows = await by_kw_col.list_specimens_keyword_column(conn)
            assert [r.id for r in kw_rows] == [specimen_id]
            assert kw_rows[0].class_ == "alpha"

            # jsonb containment param + the literal-`%` ILIKE branch (title_like=None).
            search_all = await search.search_specimens(conn, title_like=None, meta_filter={}, label=None)
            assert [r.id for r in search_all] == [specimen_id]
            search_hit = await search.search_specimens(conn, title_like="alp%", meta_filter={}, label="specimen")
            assert [r.id for r in search_hit] == [specimen_id]
            assert isinstance(search_hit[0].meta, dict)

            # RowsAffected helper returns the count.
            affected = await bump.bump_specimen_revision(conn, id=specimen_id)
            assert affected == 1
            bumped = await get.get_specimen(conn, id=specimen_id)
            assert bumped is not None
            assert bumped.rev == 2
        finally:
            await conn.close()

    asyncio.run(scenario())


def test_require_array_rejects_unregistered_enum_array(full_package: Path) -> None:
    """require_array turns the unregistered enum-array form into a clear error.

    Without register_types psycopg returns an enum array as the raw array text, not
    a list; the generated enum-array decode wraps the value in require_array so it
    fails loudly instead of iterating a string into bogus members.
    """
    import_module = _import_client(full_package)
    runtime = import_module("specimen_client._generated._runtime")

    assert runtime.require_array(["happy", "sad"]) == ["happy", "sad"]
    with pytest.raises(RuntimeError, match="register_types"):
        _ = runtime.require_array("{happy,sad}")


def test_roundtrip_sync_and_cross_surface_identity(full_package: Path, roundtrip_db: str) -> None:
    """The sync surface decodes through the same shared Row types as async.

    Drives the generated sync functions (psycopg.Connection, no await) end to end,
    and asserts the Row dataclasses are shared across surfaces: both facades and
    both statement modules expose the same class object (defined once in
    _generated._rows), so a value typed against one surface is the other's too.
    """
    _apply_migrations(roundtrip_db)
    import_module = _import_client(full_package)

    register = import_module("specimen_client._generated.sync._register")
    mood_mod = import_module("specimen_client._generated.types.mood")
    point_mod = import_module("specimen_client._generated.types.point_2_d")
    insert = import_module("specimen_client._generated.sync.statements.insert_specimen")
    get = import_module("specimen_client._generated.sync.statements.get_specimen")
    by_moods = import_module("specimen_client._generated.sync.statements.list_specimens_by_moods")
    bump = import_module("specimen_client._generated.sync.statements.bump_specimen_revision")

    Mood = mood_mod.Mood
    Point2D = point_mod.Point2D

    # Cross-surface identity: the async facade, the sync facade, the sync
    # statement module, and the shared _rows module all expose the same object.
    async_facade = import_module("specimen_client")
    sync_facade = import_module("specimen_client.sync")
    rows_mod = import_module("specimen_client._generated._rows")
    assert async_facade.InsertSpecimenRow is sync_facade.InsertSpecimenRow
    assert insert.InsertSpecimenRow is rows_mod.InsertSpecimenRow
    assert async_facade.InsertSpecimenRow is rows_mod.InsertSpecimenRow

    conn = psycopg.connect(roundtrip_db, autocommit=True)
    try:
        register.register_types(conn)

        inserted = insert.insert_specimen(
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
        assert isinstance(inserted.feeling, Mood)
        assert inserted.feeling is Mood.HAPPY
        assert isinstance(inserted.origin, Point2D)
        assert inserted.doc_jsonb == {"k": "v", "n": 1}
        assert inserted.moods == [Mood.HAPPY, None, Mood.SAD]
        assert inserted.moods is not None
        assert inserted.moods[0] is Mood.HAPPY

        specimen_id = inserted.id
        hit = get.get_specimen(conn, id=specimen_id)
        assert hit is not None
        assert hit.id == specimen_id
        assert get.get_specimen(conn, id=specimen_id + 10_000) is None

        mood_rows = by_moods.list_specimens_by_moods(conn, moods=[Mood.HAPPY])
        assert [r.id for r in mood_rows] == [specimen_id]
        assert by_moods.list_specimens_by_moods(conn, moods=[Mood.SAD]) == []

        affected = bump.bump_specimen_revision(conn, id=specimen_id)
        assert affected == 1
        bumped = get.get_specimen(conn, id=specimen_id)
        assert bumped is not None
        assert bumped.rev == 2
    finally:
        conn.close()


def test_roundtrip_single_field_composite(full_package: Path, roundtrip_db: str) -> None:
    """Regression test for compositeBind on a one-field composite.

    concatMapSep joins a single-element field list with no separator, so an
    unguarded tuple expression would render "(x.f)": a parenthesized value, not
    a tuple, which psycopg would try to adapt as the bare field type instead of
    the composite. Exercises the param bind (insert) and the result-column
    decode (RETURNING and a plain SELECT).
    """
    _apply_migrations(roundtrip_db)
    import_module = _import_client(full_package)

    register = import_module("specimen_client._generated._register")
    tag_mod = import_module("specimen_client._generated.types.tag_value")
    insert = import_module("specimen_client._generated.statements.insert_tagged_item")
    get = import_module("specimen_client._generated.statements.get_tagged_item")

    TagValue = tag_mod.TagValue

    async def scenario() -> None:
        conn = await psycopg.AsyncConnection.connect(roundtrip_db, autocommit=True)
        try:
            await register.register_types(conn)

            inserted = await insert.insert_tagged_item(conn, name="widget", tag=TagValue(value="blue"))
            assert isinstance(inserted.tag, TagValue)
            assert inserted.tag == TagValue(value="blue")

            hit = await get.get_tagged_item(conn, id=inserted.id)
            assert hit is not None
            assert isinstance(hit.tag, TagValue)
            assert hit.tag == TagValue(value="blue")
            assert await get.get_tagged_item(conn, id=inserted.id + 10_000) is None
        finally:
            await conn.close()

    asyncio.run(scenario())


def test_roundtrip_single_field_composite_sync(full_package: Path, roundtrip_db: str) -> None:
    """Sync-surface counterpart of test_roundtrip_single_field_composite."""
    _apply_migrations(roundtrip_db)
    import_module = _import_client(full_package)

    register = import_module("specimen_client._generated.sync._register")
    tag_mod = import_module("specimen_client._generated.types.tag_value")
    insert = import_module("specimen_client._generated.sync.statements.insert_tagged_item")
    get = import_module("specimen_client._generated.sync.statements.get_tagged_item")

    TagValue = tag_mod.TagValue

    conn = psycopg.connect(roundtrip_db, autocommit=True)
    try:
        register.register_types(conn)

        inserted = insert.insert_tagged_item(conn, name="widget", tag=TagValue(value="blue"))
        assert isinstance(inserted.tag, TagValue)
        assert inserted.tag == TagValue(value="blue")

        hit = get.get_tagged_item(conn, id=inserted.id)
        assert hit is not None
        assert hit.tag == TagValue(value="blue")
    finally:
        conn.close()
