from __future__ import annotations

import asyncio
import json
import subprocess
from pathlib import Path
from typing import LiteralString

import psycopg
import pytest
from psycopg.rows import args_row

from tests.typing.psycopg_adapter_runtime import (
    EnumArrayRow,
    EnumGridRow,
    EnumRow,
    Leaf,
    LeafArrayRow,
    LeafRow,
    Mood,
    SanitizedRow,
    Wrapper,
    WrapperRow,
    fetch_one_async,
    fetch_one_sync,
    register_adapter_types_async,
    register_adapter_types_sync,
)


REPO_ROOT = Path(__file__).resolve().parents[1]
STRICT_FIXTURE = REPO_ROOT / "tests" / "typing" / "psycopg_adapter_runtime.py"
SCHEMA_SQL: LiteralString = """
CREATE TYPE public.m_adapter_mood AS ENUM ('happy', 'sad');
CREATE TYPE public.z_adapter_leaf AS (
    "class" int8,
    pg_decode text,
    pg_encode text
);
CREATE TYPE public.a_adapter_wrapper AS (
    leaf public.z_adapter_leaf,
    mood public.m_adapter_mood,
    note text
);
"""


@pytest.fixture(scope="module")
def _strict_adapter_contract(tmp_path_factory: pytest.TempPathFactory) -> None:
    root = tmp_path_factory.mktemp("adapter-typing")
    config = root / "pyrightconfig.json"
    _ = config.write_text(
        json.dumps(
            {
                "pythonVersion": "3.12",
                "typeCheckingMode": "strict",
                "include": [str(STRICT_FIXTURE)],
                "venvPath": str(REPO_ROOT),
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
    if not result.stdout.strip():
        pytest.fail(f"basedpyright produced no JSON (exit {result.returncode}):\n{result.stderr}")

    summary = json.loads(result.stdout)["summary"]
    assert summary["filesAnalyzed"] > 0, f"basedpyright analyzed no files:\n{result.stdout}"
    assert summary["errorCount"] == 0 and summary["warningCount"] == 0, (
        f"basedpyright strict reported issues: {summary}\n{result.stdout}"
    )


def test_async_psycopg_adapter_contract(
    _strict_adapter_contract: None,
    roundtrip_db: str,
) -> None:
    async def scenario() -> None:
        conn = await psycopg.AsyncConnection.connect(roundtrip_db, autocommit=True)
        try:
            _ = await conn.execute(SCHEMA_SQL)
            await register_adapter_types_async(conn)

            enum_row = await fetch_one_async(
                conn,
                "SELECT 'happy'::public.m_adapter_mood",
                {},
                args_row(EnumRow),
            )
            assert type(enum_row) is EnumRow
            assert type(enum_row.mood) is Mood
            assert enum_row.mood is Mood.HAPPY

            enum_array_row = await fetch_one_async(
                conn,
                "SELECT ARRAY['happy'::public.m_adapter_mood, NULL, 'sad'::public.m_adapter_mood]",
                {},
                args_row(EnumArrayRow),
            )
            assert type(enum_array_row) is EnumArrayRow
            assert type(enum_array_row.moods) is list
            assert len(enum_array_row.moods) == 3
            assert enum_array_row.moods[0] is Mood.HAPPY
            assert enum_array_row.moods[1] is None
            assert enum_array_row.moods[2] is Mood.SAD

            enum_grid_row = await fetch_one_async(
                conn,
                "SELECT '{{happy,sad},{sad,happy}}'::public.m_adapter_mood[][]",
                {},
                args_row(EnumGridRow),
            )
            assert type(enum_grid_row) is EnumGridRow
            assert type(enum_grid_row.moods) is list
            assert len(enum_grid_row.moods) == 2
            assert all(type(row) is list for row in enum_grid_row.moods)
            assert enum_grid_row.moods[0][0] is Mood.HAPPY
            assert enum_grid_row.moods[0][1] is Mood.SAD
            assert enum_grid_row.moods[1][0] is Mood.SAD
            assert enum_grid_row.moods[1][1] is Mood.HAPPY

            leaf_row = await fetch_one_async(
                conn,
                "SELECT ROW(11, 'decode', NULL)::public.z_adapter_leaf",
                {},
                args_row(LeafRow),
            )
            assert type(leaf_row) is LeafRow
            assert type(leaf_row.value) is Leaf
            assert leaf_row.value.class_ == 11
            assert leaf_row.value.pg_decode == "decode"
            assert leaf_row.value.pg_encode is None

            leaf_value = Leaf(class_=12, pg_decode="parameter", pg_encode=None)
            leaf_parameter_row = await fetch_one_async(
                conn,
                "SELECT %(value)s::public.z_adapter_leaf",
                {"value": leaf_value},
                args_row(LeafRow),
            )
            assert type(leaf_parameter_row) is LeafRow
            assert type(leaf_parameter_row.value) is Leaf
            assert leaf_parameter_row.value == leaf_value
            assert leaf_parameter_row.value.pg_encode is None

            leaf_values = [
                Leaf(class_=13, pg_decode="first", pg_encode="encoded"),
                Leaf(class_=14, pg_decode="second", pg_encode=None),
            ]
            leaf_array_row = await fetch_one_async(
                conn,
                "SELECT %(values)s::public.z_adapter_leaf[]",
                {"values": leaf_values},
                args_row(LeafArrayRow),
            )
            assert type(leaf_array_row) is LeafArrayRow
            assert type(leaf_array_row.values) is list
            assert all(type(value) is Leaf for value in leaf_array_row.values)
            assert leaf_array_row.values == leaf_values
            assert leaf_array_row.values[1].pg_encode is None

            wrapper_value = Wrapper(
                leaf=Leaf(class_=15, pg_decode="nested", pg_encode=None),
                mood=Mood.SAD,
                note=None,
            )
            wrapper_row = await fetch_one_async(
                conn,
                "SELECT %(value)s::public.a_adapter_wrapper",
                {"value": wrapper_value},
                args_row(WrapperRow),
            )
            assert type(wrapper_row) is WrapperRow
            assert type(wrapper_row.value) is Wrapper
            assert type(wrapper_row.value.leaf) is Leaf
            assert wrapper_row.value == wrapper_value
            assert wrapper_row.value.mood is Mood.SAD
            assert wrapper_row.value.note is None

            sanitized_row = await fetch_one_async(
                conn,
                "SELECT 'keyword' AS \"class\", ROW(16, 'codec', NULL)::public.z_adapter_leaf AS value",
                {},
                args_row(SanitizedRow),
            )
            assert type(sanitized_row) is SanitizedRow
            assert sanitized_row.class_ == "keyword"
            assert type(sanitized_row.value) is Leaf
            assert sanitized_row.value.class_ == 16
            assert sanitized_row.value.pg_decode == "codec"
            assert sanitized_row.value.pg_encode is None
        finally:
            await conn.close()

    asyncio.run(scenario())


def test_sync_psycopg_adapter_contract(
    _strict_adapter_contract: None,
    roundtrip_db: str,
) -> None:
    conn = psycopg.connect(roundtrip_db, autocommit=True)
    try:
        _ = conn.execute(SCHEMA_SQL)
        register_adapter_types_sync(conn)

        enum_row = fetch_one_sync(
            conn,
            "SELECT 'happy'::public.m_adapter_mood",
            {},
            args_row(EnumRow),
        )
        assert type(enum_row) is EnumRow
        assert type(enum_row.mood) is Mood
        assert enum_row.mood is Mood.HAPPY

        enum_array_row = fetch_one_sync(
            conn,
            "SELECT ARRAY['happy'::public.m_adapter_mood, NULL, 'sad'::public.m_adapter_mood]",
            {},
            args_row(EnumArrayRow),
        )
        assert type(enum_array_row) is EnumArrayRow
        assert type(enum_array_row.moods) is list
        assert len(enum_array_row.moods) == 3
        assert enum_array_row.moods[0] is Mood.HAPPY
        assert enum_array_row.moods[1] is None
        assert enum_array_row.moods[2] is Mood.SAD

        enum_grid_row = fetch_one_sync(
            conn,
            "SELECT '{{happy,sad},{sad,happy}}'::public.m_adapter_mood[][]",
            {},
            args_row(EnumGridRow),
        )
        assert type(enum_grid_row) is EnumGridRow
        assert type(enum_grid_row.moods) is list
        assert len(enum_grid_row.moods) == 2
        assert all(type(row) is list for row in enum_grid_row.moods)
        assert enum_grid_row.moods[0][0] is Mood.HAPPY
        assert enum_grid_row.moods[0][1] is Mood.SAD
        assert enum_grid_row.moods[1][0] is Mood.SAD
        assert enum_grid_row.moods[1][1] is Mood.HAPPY

        leaf_row = fetch_one_sync(
            conn,
            "SELECT ROW(11, 'decode', NULL)::public.z_adapter_leaf",
            {},
            args_row(LeafRow),
        )
        assert type(leaf_row) is LeafRow
        assert type(leaf_row.value) is Leaf
        assert leaf_row.value.class_ == 11
        assert leaf_row.value.pg_decode == "decode"
        assert leaf_row.value.pg_encode is None

        leaf_value = Leaf(class_=12, pg_decode="parameter", pg_encode=None)
        leaf_parameter_row = fetch_one_sync(
            conn,
            "SELECT %(value)s::public.z_adapter_leaf",
            {"value": leaf_value},
            args_row(LeafRow),
        )
        assert type(leaf_parameter_row) is LeafRow
        assert type(leaf_parameter_row.value) is Leaf
        assert leaf_parameter_row.value == leaf_value
        assert leaf_parameter_row.value.pg_encode is None

        leaf_values = [
            Leaf(class_=13, pg_decode="first", pg_encode="encoded"),
            Leaf(class_=14, pg_decode="second", pg_encode=None),
        ]
        leaf_array_row = fetch_one_sync(
            conn,
            "SELECT %(values)s::public.z_adapter_leaf[]",
            {"values": leaf_values},
            args_row(LeafArrayRow),
        )
        assert type(leaf_array_row) is LeafArrayRow
        assert type(leaf_array_row.values) is list
        assert all(type(value) is Leaf for value in leaf_array_row.values)
        assert leaf_array_row.values == leaf_values
        assert leaf_array_row.values[1].pg_encode is None

        wrapper_value = Wrapper(
            leaf=Leaf(class_=15, pg_decode="nested", pg_encode=None),
            mood=Mood.SAD,
            note=None,
        )
        wrapper_row = fetch_one_sync(
            conn,
            "SELECT %(value)s::public.a_adapter_wrapper",
            {"value": wrapper_value},
            args_row(WrapperRow),
        )
        assert type(wrapper_row) is WrapperRow
        assert type(wrapper_row.value) is Wrapper
        assert type(wrapper_row.value.leaf) is Leaf
        assert wrapper_row.value == wrapper_value
        assert wrapper_row.value.mood is Mood.SAD
        assert wrapper_row.value.note is None

        sanitized_row = fetch_one_sync(
            conn,
            "SELECT 'keyword' AS \"class\", ROW(16, 'codec', NULL)::public.z_adapter_leaf AS value",
            {},
            args_row(SanitizedRow),
        )
        assert type(sanitized_row) is SanitizedRow
        assert sanitized_row.class_ == "keyword"
        assert type(sanitized_row.value) is Leaf
        assert sanitized_row.value.class_ == 16
        assert sanitized_row.value.pg_decode == "codec"
        assert sanitized_row.value.pg_encode is None
    finally:
        conn.close()
